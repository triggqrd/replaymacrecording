import Foundation

public struct SessionAppendStats: Sendable {
    public let pendingSamples: Int
    public let droppedSamples: Int
}

/// Decouples the real-time capture/encode callbacks from the `SessionRecorder`
/// actor. Mirrors `LongBufferAppendPump` (bounded queue, drop-oldest under
/// pressure, single generation-guarded drain loop) and adds the gating flags the
/// output handlers read to decide whether a sample belongs to the current screen
/// recording. Enqueue and the flag reads run on capture/VideoToolbox threads, so
/// nothing here hops to the main actor.
public final class SessionAppendPump: @unchecked Sendable {
    private enum PendingSample {
        case video(LongBufferSample)
        case systemAudio(LongBufferSample)
        case microphone(LongBufferSample)
    }

    private let recorder: SessionRecorder
    private let queue = DispatchQueue(label: "com.replaycap.session.append-pump", qos: .userInitiated)
    private let maxPendingSamples: Int
    private var pendingSamples: [PendingSample] = []
    private var isDraining = false
    private var drainGeneration = 0
    private var droppedSamples = 0
    private var flushContinuations: [CheckedContinuation<Void, Never>] = []

    // Gating flags, read on real-time capture threads. Guarded independently of
    // the drain queue so the reads never block behind queued work.
    private let flagsLock = NSLock()
    private var _isActive = false
    private var _wantsSystemAudio = false
    private var _wantsMicrophone = false

    public init(recorder: SessionRecorder, maxPendingSamples: Int = 240) {
        self.recorder = recorder
        self.maxPendingSamples = max(1, maxPendingSamples)
    }

    // MARK: - Gating

    /// Whether the current recording is capturing system audio. The SCK
    /// system-audio process gate ORs this with the replay buffer's own setting.
    public var systemAudioWanted: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return _isActive && _wantsSystemAudio
    }

    public var isActive: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return _isActive
    }

    public var microphoneWanted: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return _isActive && _wantsMicrophone
    }

    public func configure(recordSystemAudio: Bool, recordMicrophone: Bool) {
        flagsLock.lock()
        _wantsSystemAudio = recordSystemAudio
        _wantsMicrophone = recordMicrophone
        flagsLock.unlock()
    }

    public func setActive(_ active: Bool) {
        flagsLock.lock()
        _isActive = active
        flagsLock.unlock()
    }

    // MARK: - Enqueue

    public func enqueueVideo(_ sample: LongBufferSample) {
        guard isActive else { return }
        enqueue(.video(sample))
    }

    public func enqueueSystemAudio(_ sample: LongBufferSample) {
        flagsLock.lock()
        let wanted = _isActive && _wantsSystemAudio
        flagsLock.unlock()
        guard wanted else { return }
        enqueue(.systemAudio(sample))
    }

    public func enqueueMicrophone(_ sample: LongBufferSample) {
        flagsLock.lock()
        let wanted = _isActive && _wantsMicrophone
        flagsLock.unlock()
        guard wanted else { return }
        enqueue(.microphone(sample))
    }

    // MARK: - Lifecycle

    public func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSamples.removeAll(keepingCapacity: true)
            self.isDraining = false
            self.drainGeneration += 1
            self.droppedSamples = 0
            self.resumeFlushContinuations()
        }
    }

    /// Awaits until every already-enqueued sample has been handed to the
    /// recorder. Call after `setActive(false)` and before `recorder.stop()` so
    /// the finalized file contains all captured frames.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                if self.pendingSamples.isEmpty && !self.isDraining {
                    continuation.resume()
                } else {
                    self.flushContinuations.append(continuation)
                }
            }
        }
    }

    public func snapshot() -> SessionAppendStats {
        queue.sync {
            SessionAppendStats(pendingSamples: pendingSamples.count, droppedSamples: droppedSamples)
        }
    }

    // MARK: - Drain

    private func enqueue(_ sample: PendingSample) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.pendingSamples.count >= self.maxPendingSamples {
                self.pendingSamples.removeFirst()
                self.droppedSamples += 1
            }
            self.pendingSamples.append(sample)
            self.startDrainIfNeeded()
        }
    }

    private func startDrainIfNeeded() {
        guard !isDraining else { return }
        guard !pendingSamples.isEmpty else { return }
        isDraining = true
        drainNext(generation: drainGeneration)
    }

    private func drainNext(generation: Int) {
        guard generation == drainGeneration else { return }
        guard !pendingSamples.isEmpty else {
            isDraining = false
            resumeFlushContinuations()
            return
        }

        let sample = pendingSamples.removeFirst()
        Task { [weak self, recorder] in
            switch sample {
            case .video(let sample):
                await recorder.appendVideo(sample)
            case .systemAudio(let sample):
                await recorder.appendSystemAudio(sample)
            case .microphone(let sample):
                await recorder.appendMicrophone(sample)
            }

            self?.queue.async { [weak self] in
                self?.drainNext(generation: generation)
            }
        }
    }

    private func resumeFlushContinuations() {
        guard !flushContinuations.isEmpty else { return }
        let continuations = flushContinuations
        flushContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }
}
