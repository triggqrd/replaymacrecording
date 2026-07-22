import Foundation

public struct LongBufferAppendStats: Sendable {
    public let pendingSamples: Int
    public let droppedSamples: Int
}

public final class LongBufferAppendPump: @unchecked Sendable {
    private enum PendingSample {
        case video(LongBufferSample)
        case systemAudio(LongBufferSample)
        case microphone(LongBufferSample)
    }

    private let recorder: LongBufferRecorder
    private let queue = DispatchQueue(label: "com.replaycap.long-buffer.append-pump", qos: .userInitiated)
    private let maxPendingSamples: Int
    private var pendingSamples: [PendingSample] = []
    private var isDraining = false
    private var drainGeneration = 0
    private var droppedSamples = 0

    // Extended-replay is off by default. Gate here so an idle long buffer doesn't
    // spin a GCD block + Task + actor hop per frame only for the recorder to
    // discard it. Read on the capture thread, set on the main actor.
    private let flagsLock = NSLock()
    private var _isEnabled = false

    public init(recorder: LongBufferRecorder, maxPendingSamples: Int = 240) {
        self.recorder = recorder
        self.maxPendingSamples = max(1, maxPendingSamples)
    }

    public var isEnabled: Bool {
        flagsLock.lock()
        defer { flagsLock.unlock() }
        return _isEnabled
    }

    public func setEnabled(_ enabled: Bool) {
        flagsLock.lock()
        _isEnabled = enabled
        flagsLock.unlock()
    }

    public func enqueueVideo(_ sample: LongBufferSample) {
        guard isEnabled else { return }
        enqueue(.video(sample))
    }

    public func enqueueSystemAudio(_ sample: LongBufferSample) {
        guard isEnabled else { return }
        enqueue(.systemAudio(sample))
    }

    public func enqueueMicrophone(_ sample: LongBufferSample) {
        guard isEnabled else { return }
        enqueue(.microphone(sample))
    }

    public func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSamples.removeAll(keepingCapacity: true)
            self.isDraining = false
            self.drainGeneration += 1
            self.droppedSamples = 0
        }
    }

    public func snapshot() -> LongBufferAppendStats {
        queue.sync {
            LongBufferAppendStats(
                pendingSamples: pendingSamples.count,
                droppedSamples: droppedSamples
            )
        }
    }

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
}
