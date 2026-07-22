import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os.log

public enum SessionRecorderError: LocalizedError, Equatable {
    case cannotAddInput
    case cannotStartWriting
    case finalizeFailed

    public var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "Unable to add a track to the screen recording writer."
        case .cannotStartWriting:
            return "Unable to start the screen recording writer."
        case .finalizeFailed:
            return "Screen recording did not finalize."
        }
    }
}

/// Writes one continuous MP4 for a manual "Screen Recording" session by tapping
/// the already-encoded video stream (muxed with no re-encode) and the raw PCM
/// audio streams (AAC-encoded by the writer). Modeled on `LongBufferRecorder`,
/// but a single file with no segment rotation, pruning, or staging. The writer is
/// built lazily on the first video frame (it needs the encoded format
/// description) and only while the session is `.recording`, so a late-draining
/// frame after `stop()` can never spawn a second file.
public actor SessionRecorder {
    typealias WriterBuilder = @Sendable (
        _ outputURL: URL,
        _ firstVideo: LongBufferSample,
        _ startPTS: Double,
        _ includeSystemAudio: Bool,
        _ includeMicrophone: Bool
    ) throws -> LongBufferWriterComponents
    typealias WriterFinisher = @Sendable (LongBufferWriterBox) async throws -> Void

    private enum State: Equatable {
        case idle
        case recording
        case finalizing
        case finished
    }

    private var state: State = .idle
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    private var outputDirectory: URL?
    private var baseName: String?
    private var includeSystemAudio = false
    private var includeMicrophone = false
    private var sessionStartPTS: Double?
    private var outputURL: URL?
    private var writerDidFail = false

    private var droppedVideoSamples = 0
    private var droppedSystemAudioSamples = 0
    private var droppedMicSamples = 0

    private let writerBuilder: WriterBuilder
    private let writerFinisher: WriterFinisher
    private let logger = Logger(subsystem: "com.replaycap", category: "SessionRecorder")

    public init() {
        writerBuilder = Self.makeWriter
        writerFinisher = Self.finishWriter
    }

    init(writerBuilder: @escaping WriterBuilder, writerFinisher: @escaping WriterFinisher) {
        self.writerBuilder = writerBuilder
        self.writerFinisher = writerFinisher
    }

    public var isRecording: Bool { state == .recording }

    /// Arms a new recording. The writer is created on the first video frame.
    public func start(
        outputDirectory: URL,
        recordSystemAudio: Bool,
        recordMicrophone: Bool,
        baseName: String?
    ) {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        micInput = nil
        sessionStartPTS = nil
        outputURL = nil
        writerDidFail = false
        droppedVideoSamples = 0
        droppedSystemAudioSamples = 0
        droppedMicSamples = 0

        self.outputDirectory = outputDirectory
        self.baseName = baseName
        includeSystemAudio = recordSystemAudio
        includeMicrophone = recordMicrophone
        state = .recording
    }

    public func appendVideo(_ sample: LongBufferSample) {
        guard state == .recording else { return }
        let buffer = sample.buffer
        guard buffer.isValid else { return }

        do {
            if writer == nil {
                guard !writerDidFail else { return }
                // Open the file on a keyframe (IDR) so it starts on a decodable
                // frame. Starting mid-GOP on a P-frame renders black until the
                // next keyframe. The encoder is asked to emit a keyframe right
                // when recording starts, so this drops at most a frame or two.
                guard Self.isKeyframe(buffer) else { return }
                // PTS is only needed to anchor the first frame's session start.
                try startWriter(firstVideo: buffer, at: presentationTimeStamp(buffer))
            }
            if !append(buffer, to: videoInput) {
                droppedVideoSamples += 1
                logDropIfNeeded(label: "video", count: droppedVideoSamples)
                noteTerminalFailureIfNeeded()
            }
        } catch {
            writerDidFail = true
            logger.error(
                "Session recorder video append failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    public func appendSystemAudio(_ sample: LongBufferSample) {
        guard state == .recording, includeSystemAudio else { return }
        if !appendAudio(sample.buffer, to: systemAudioInput) {
            droppedSystemAudioSamples += 1
            logDropIfNeeded(label: "system audio", count: droppedSystemAudioSamples)
        }
    }

    public func appendMicrophone(_ sample: LongBufferSample) {
        guard state == .recording, includeMicrophone else { return }
        if !appendAudio(sample.buffer, to: micInput) {
            droppedMicSamples += 1
            logDropIfNeeded(label: "microphone", count: droppedMicSamples)
        }
    }

    /// Finalizes the current recording. Returns the saved file URL, or `nil` if
    /// no frame was ever written or finalization failed.
    @discardableResult
    public func stop() async -> URL? {
        guard state == .recording else { return nil }
        state = .finalizing

        guard let writer, let outputURL else {
            clearWriter()
            state = .finished
            return nil
        }

        // Detach the writer/inputs before awaiting. Actor methods are re-entrant
        // at suspension points, so a late-draining append must not see inputs that
        // have already been marked finished.
        let videoInput = self.videoInput
        let systemAudioInput = self.systemAudioInput
        let micInput = self.micInput
        clearWriter()

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()

        do {
            try await writerFinisher(LongBufferWriterBox(writer))
            state = .finished
            NotificationCenter.default.post(name: .replayCapClipSaved, object: outputURL)
            logger.info(
                "Session recording finalized file=\(outputURL.lastPathComponent, privacy: .public)"
            )
            return outputURL
        } catch {
            state = .finished
            try? FileManager.default.removeItem(at: outputURL)
            logger.error(
                "Session recording finalize failed error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Writer lifecycle

    private func startWriter(firstVideo: CMSampleBuffer, at pts: Double) throws {
        guard let outputDirectory else { throw SessionRecorderError.cannotStartWriting }
        let url = try ClipMetadata.generateUniqueFileURL(
            in: outputDirectory,
            baseName: baseName,
            suffix: "Recording"
        )
        var installed = false
        defer {
            if !installed {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let components = try writerBuilder(
            url,
            LongBufferSample(firstVideo),
            pts,
            includeSystemAudio,
            includeMicrophone
        )
        writer = components.writer
        videoInput = components.videoInput
        systemAudioInput = components.systemAudioInput
        micInput = components.micInput
        outputURL = url
        sessionStartPTS = pts
        installed = true
        logger.info(
            "Session recording writer started file=\(url.lastPathComponent, privacy: .public) sysAudio=\(self.includeSystemAudio, privacy: .public) mic=\(self.includeMicrophone, privacy: .public)"
        )
    }

    private func clearWriter() {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        micInput = nil
    }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard sample.isValid else { return true }
        // No writer yet (audio arrived before the first video frame), or audio
        // whose PTS precedes the session start: drop it so the timeline anchors to
        // the first video frame and never predates startSession. Not a real drop.
        guard writer != nil, let sessionStartPTS else { return true }
        let pts = presentationTimeStamp(sample)
        guard pts >= sessionStartPTS else { return true }
        return append(sample, to: input)
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard let writer, writer.status == .writing, let input, input.isReadyForMoreMediaData else {
            return false
        }
        if !input.append(sample) {
            logger.error(
                "Session recorder sample append failed status=\(Self.describe(writer.status), privacy: .public) error=\(writer.error?.localizedDescription ?? "none", privacy: .public)"
            )
            return false
        }
        return true
    }

    private func noteTerminalFailureIfNeeded() {
        if let writer, writer.status == .failed || writer.status == .cancelled {
            writerDidFail = true
        }
    }

    private func logDropIfNeeded(label: String, count: Int) {
        if count == 1 || count % 300 == 0 {
            logger.notice(
                "Session recorder dropped samples media=\(label, privacy: .public) count=\(count, privacy: .public)"
            )
        }
    }

    // MARK: - Static writer helpers

    private static func makeWriter(
        outputURL: URL,
        firstVideo: LongBufferSample,
        startPTS: Double,
        includeSystemAudio: Bool,
        includeMicrophone: Bool
    ) throws -> LongBufferWriterComponents {
        let sample = firstVideo.buffer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.metadata = ClipMetadata.makeMetadataItems()
        // Flush a moov fragment every second so a recording interrupted by a crash
        // or hard power-off stays playable up to the last fragment.
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = true

        guard let formatDescription = sample.formatDescription else {
            throw SessionRecorderError.cannotAddInput
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw SessionRecorderError.cannotAddInput
        }
        writer.add(videoInput)

        var systemAudioInput: AVAssetWriterInput?
        if includeSystemAudio {
            let input = Self.makeAudioInput()
            if writer.canAdd(input) {
                writer.add(input)
                systemAudioInput = input
            }
        }

        var micInput: AVAssetWriterInput?
        if includeMicrophone {
            let input = Self.makeAudioInput()
            if writer.canAdd(input) {
                writer.add(input)
                micInput = input
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? SessionRecorderError.cannotStartWriting
        }
        writer.startSession(atSourceTime: CMTime(seconds: startPTS, preferredTimescale: 600))

        return LongBufferWriterComponents(
            writer: writer,
            videoInput: videoInput,
            systemAudioInput: systemAudioInput,
            micInput: micInput
        )
    }

    private static func finishWriter(_ writerBox: LongBufferWriterBox) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerBox.writer.finishWriting {
                if writerBox.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: writerBox.writer.error ?? SessionRecorderError.finalizeFailed
                    )
                }
            }
        }
    }

    private static func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func presentationTimeStamp(_ sample: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        return pts.isValid ? pts.seconds : 0
    }

    /// A sample is a keyframe unless it's explicitly marked not-a-sync-sample.
    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachment = attachments.first else {
            return true
        }
        if let notSync = attachment[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            return !notSync
        }
        return true
    }

    private static func describe(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .writing: "writing"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        @unknown default: "unrecognized"
        }
    }
}
