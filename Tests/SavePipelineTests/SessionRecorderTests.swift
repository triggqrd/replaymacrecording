import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import Save

final class SessionRecorderTests: XCTestCase {
    private enum TestError: Error {
        case simulatedFinishFailure
        case couldNotCreatePixelBuffer(OSStatus)
        case couldNotCreateSampleBuffer(OSStatus)
    }

    /// Thread-safe capture of what the injected (synchronous) writer builder saw.
    private final class BuildObserver: @unchecked Sendable {
        private let lock = NSLock()
        private var _buildCount = 0
        private var _includeSystemAudio: [Bool] = []
        private var _includeMicrophone: [Bool] = []
        private var _urls: [URL] = []

        func record(url: URL, includeSystemAudio: Bool, includeMicrophone: Bool) {
            lock.lock(); defer { lock.unlock() }
            _buildCount += 1
            _includeSystemAudio.append(includeSystemAudio)
            _includeMicrophone.append(includeMicrophone)
            _urls.append(url)
        }

        var buildCount: Int { lock.lock(); defer { lock.unlock() }; return _buildCount }
        var includeSystemAudio: [Bool] { lock.lock(); defer { lock.unlock() }; return _includeSystemAudio }
        var includeMicrophone: [Bool] { lock.lock(); defer { lock.unlock() }; return _includeMicrophone }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    }

    // MARK: - Tests

    func testStopBeforeFirstFrameReturnsNilAndBuildsNoWriter() async throws {
        let outputDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let observer = BuildObserver()
        let recorder = makeRecorder(observer: observer)

        await recorder.start(
            outputDirectory: outputDirectory,
            recordSystemAudio: true,
            recordMicrophone: false,
            baseName: nil
        )
        let url = await recorder.stop()

        XCTAssertNil(url)
        XCTAssertEqual(observer.buildCount, 0, "No video frame arrived, so no writer should be built")
    }

    func testWriterBuiltOnceAcrossManyFrames() async throws {
        let outputDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let observer = BuildObserver()
        let recorder = makeRecorder(observer: observer)

        await recorder.start(
            outputDirectory: outputDirectory,
            recordSystemAudio: false,
            recordMicrophone: false,
            baseName: nil
        )
        for index in 0..<5 {
            await recorder.appendVideo(try makeVideoSample(pts: Double(index) / 30.0))
        }
        _ = await recorder.stop()

        XCTAssertEqual(observer.buildCount, 1, "The single-file writer must be built exactly once")
    }

    func testStartPassesAudioSelectionToBuilder() async throws {
        let outputDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let observer = BuildObserver()
        let recorder = makeRecorder(observer: observer)

        await recorder.start(
            outputDirectory: outputDirectory,
            recordSystemAudio: true,
            recordMicrophone: true,
            baseName: nil
        )
        await recorder.appendVideo(try makeVideoSample())
        _ = await recorder.stop()

        XCTAssertEqual(observer.includeSystemAudio, [true])
        XCTAssertEqual(observer.includeMicrophone, [true])
    }

    func testAppendAfterStopDoesNotBuildSecondWriter() async throws {
        let outputDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let observer = BuildObserver()
        let recorder = makeRecorder(observer: observer)

        await recorder.start(
            outputDirectory: outputDirectory,
            recordSystemAudio: false,
            recordMicrophone: false,
            baseName: nil
        )
        await recorder.appendVideo(try makeVideoSample(pts: 0))
        _ = await recorder.stop()
        // A late-draining frame after stop must not spawn a second file.
        await recorder.appendVideo(try makeVideoSample(pts: 1))

        XCTAssertEqual(observer.buildCount, 1)
        let recording = await recorder.isRecording
        XCTAssertFalse(recording)
    }

    func testStopReturnsURLAndPostsNotificationOnSuccess() async throws {
        let outputDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let recorder = SessionRecorder(
            writerBuilder: { url, _, _, _, _ in
                try Data("recording".utf8).write(to: url)
                return try Self.stubComponents(url: url)
            },
            writerFinisher: { _ in }
        )

        let notified = expectation(forNotification: .replayCapClipSaved, object: nil, handler: nil)

        await recorder.start(
            outputDirectory: outputDirectory,
            recordSystemAudio: false,
            recordMicrophone: false,
            baseName: nil
        )
        await recorder.appendVideo(try makeVideoSample())
        let url = await recorder.stop()

        await fulfillment(of: [notified], timeout: 2.0)
        let unwrapped = try XCTUnwrap(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrapped.path))
        XCTAssertEqual(unwrapped.pathExtension, "mp4")
        XCTAssertTrue(unwrapped.lastPathComponent.contains("Recording"))
    }

    func testFinishFailureRemovesPartialFileAndReturnsNil() async throws {
        let outputDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let urlBox = URLBox()
        let recorder = SessionRecorder(
            writerBuilder: { url, _, _, _, _ in
                try Data("partial".utf8).write(to: url)
                urlBox.set(url)
                return try Self.stubComponents(url: url)
            },
            writerFinisher: { _ in throw TestError.simulatedFinishFailure }
        )

        await recorder.start(
            outputDirectory: outputDirectory,
            recordSystemAudio: false,
            recordMicrophone: false,
            baseName: nil
        )
        await recorder.appendVideo(try makeVideoSample())
        let url = await recorder.stop()

        XCTAssertNil(url)
        let partial = try XCTUnwrap(urlBox.value)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: partial.path),
            "A failed finalize must remove the partial file"
        )
    }

    // MARK: - Helpers

    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: URL?
        func set(_ url: URL) { lock.lock(); _value = url; lock.unlock() }
        var value: URL? { lock.lock(); defer { lock.unlock() }; return _value }
    }

    private func makeRecorder(observer: BuildObserver) -> SessionRecorder {
        SessionRecorder(
            writerBuilder: { url, _, _, sys, mic in
                observer.record(url: url, includeSystemAudio: sys, includeMicrophone: mic)
                return try Self.stubComponents(url: url)
            },
            writerFinisher: { _ in }
        )
    }

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func stubComponents(url: URL) throws -> LongBufferWriterComponents {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        return LongBufferWriterComponents(
            writer: writer,
            videoInput: nil,
            systemAudioInput: nil,
            micInput: nil
        )
    }

    private func makeVideoSample(pts: Double = 1.0 / 30.0) throws -> LongBufferSample {
        var pixelBuffer: CVPixelBuffer?
        let pixelStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
            throw TestError.couldNotCreatePixelBuffer(pixelStatus)
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw TestError.couldNotCreateSampleBuffer(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw TestError.couldNotCreateSampleBuffer(sampleStatus)
        }
        return LongBufferSample(sampleBuffer)
    }
}
