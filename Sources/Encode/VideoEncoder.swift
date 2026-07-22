import Foundation
import VideoToolbox
@preconcurrency import CoreMedia
import CoreVideo

public enum VideoCodec: Sendable {
    case hevc
    case h264
}

public struct VideoEncoderConfiguration: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let codec: VideoCodec
    public let bitrate: Int
}

public enum VideoEncoderError: Error {
    case failedToCreateSession(OSStatus)
    case failedToSetProperties(OSStatus)
    case failedToPrepare(OSStatus)
}

private func compressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
}

public final class VideoEncoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void

    private var compressionSession: VTCompressionSession?
    private let stateLock = NSLock()
    private var _outputHandler: OutputHandler?
    private var _currentConfiguration: VideoEncoderConfiguration?
    private var expectedPTSQueue: [CMTime] = []
    private var encodeCount: Int64 = 0
    private var _forceKeyframeNextFrame = false

    public var outputHandler: OutputHandler? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _outputHandler
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _outputHandler = newValue
        }
    }

    public init() {}

    public var currentConfiguration: VideoEncoderConfiguration? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentConfiguration
    }

    deinit {
        if compressionSession != nil {
            assertionFailure("VideoEncoder deallocated without calling stop()")
        }
    }

    public func start(
        width: Int,
        height: Int,
        fps: Int,
        codec: VideoCodec = .hevc,
        bitrate: Int = 20_000_000
    ) throws {
        stop()

        let codecType: CMVideoCodecType
        switch codec {
        case .hevc:
            codecType = kCMVideoCodecType_HEVC
        case .h264:
            codecType = kCMVideoCodecType_H264
        }

        print("[ENCODE] Starting \(codec) encoder: \(width)x\(height) @ \(fps) fps, bitrate=\(bitrate) bps")

        var encoderSpecification: CFDictionary?
        if codec == .h264 {
            let spec: [NSString: AnyObject] = [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
            ]
            encoderSpecification = spec as CFDictionary
        }

        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard createStatus == noErr, let session else {
            throw VideoEncoderError.failedToCreateSession(createStatus)
        }

        let bytesPerSecond = Double(bitrate) / 8.0
        let properties: [NSString: AnyObject] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: NSNumber(value: fps * 2),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: NSNumber(value: 2.0),
            kVTCompressionPropertyKey_AverageBitRate: NSNumber(value: bitrate),
            kVTCompressionPropertyKey_DataRateLimits: [
                NSNumber(value: bytesPerSecond * 1.5),
                NSNumber(value: 1.0)
            ] as NSArray,
            // Tag the encoded stream BT.709 (sRGB primaries) so the MP4 carries an
            // explicit `colr` atom. Without this the color info is left ambiguous
            // and players apply a mismatched matrix/range, which shows up as
            // washed-out/desaturated clips. The capture side is pinned to sRGB
            // (CaptureManager.screenColorSpaceName) so the pixel data matches these
            // tags. Applies to both HEVC and H.264, and to every consumer of the
            // encoded stream (replay buffer clips and the screen recorder alike).
            kVTCompressionPropertyKey_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        ]

        let propsStatus = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        guard propsStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw VideoEncoderError.failedToSetProperties(propsStatus)
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            throw VideoEncoderError.failedToPrepare(prepareStatus)
        }

        stateLock.lock()
        compressionSession = session
        _currentConfiguration = VideoEncoderConfiguration(
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            bitrate: bitrate
        )
        stateLock.unlock()
    }

    /// Requests that the next encoded frame be a keyframe (IDR). Used when a
    /// screen recording starts so its file can open on a decodable frame instead
    /// of a mid-GOP P-frame (which renders black until the next keyframe).
    public func forceNextKeyframe() {
        stateLock.lock()
        _forceKeyframeNextFrame = true
        stateLock.unlock()
    }

    public func encode(sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let session = compressionSession
        let forceKeyframe = _forceKeyframeNextFrame
        stateLock.unlock()

        guard let session else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        stateLock.lock()
        expectedPTSQueue.append(pts)
        encodeCount += 1
        stateLock.unlock()

        let frameProperties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            stateLock.lock()
            _ = expectedPTSQueue.popLast()
            stateLock.unlock()
            print("Encoder: VTCompressionSessionEncodeFrame failed with status \(status)")
        } else if forceKeyframe {
            // Consume the one-shot keyframe request only once the frame was
            // actually submitted, so a dropped/failed frame doesn't lose it.
            stateLock.lock()
            _forceKeyframeNextFrame = false
            stateLock.unlock()
        }
    }

    public func stop() {
        stateLock.lock()
        let session = compressionSession
        compressionSession = nil
        _currentConfiguration = nil
        expectedPTSQueue.removeAll()
        encodeCount = 0
        stateLock.unlock()

        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    fileprivate func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else {
            if status != noErr {
                print("Encoder: Output callback error \(status)")
            }
            return
        }

        stateLock.lock()
        let handler = _outputHandler
        let expectedPTS = expectedPTSQueue.isEmpty ? nil : expectedPTSQueue.removeFirst()
        stateLock.unlock()

        let outputPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let expectedPTS, expectedPTS.isValid, expectedPTS.seconds > 0 {
            let ptsMatches = outputPTS.isValid && outputPTS.seconds > 0
                && abs(outputPTS.seconds - expectedPTS.seconds) < 0.00001

            if !ptsMatches {
                if encodeCount <= 5 || encodeCount % 300 == 0 {
                    print("Encoder: PTS mismatch — input=\(expectedPTS.seconds) output=\(outputPTS.seconds) (valid=\(outputPTS.isValid)) — retiming")
                }
                if let retimed = Self.retimeSampleBuffer(sampleBuffer, newPTS: expectedPTS) {
                    handler?(retimed)
                    return
                }
            }
        } else if !outputPTS.isValid || outputPTS.seconds == 0 {
            if encodeCount <= 5 || encodeCount % 300 == 0 {
                print("Encoder: output PTS invalid/zero (\(outputPTS.seconds)) and no expected PTS to fix with")
            }
        }

        handler?(sampleBuffer)
    }

    private static func retimeSampleBuffer(_ sampleBuffer: CMSampleBuffer, newPTS: CMTime) -> CMSampleBuffer? {
        let originalDuration = CMSampleBufferGetDuration(sampleBuffer)
        let timing = CMSampleTimingInfo(
            duration: originalDuration.isValid ? originalDuration : CMTime(value: 1, timescale: 60),
            presentationTimeStamp: newPTS,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        var mutableTiming = timing
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &mutableTiming,
            sampleBufferOut: &retimed
        )
        if status != noErr {
            print("Encoder: CMSampleBufferCreateCopyWithNewTiming failed with status \(status)")
            return nil
        }
        return retimed
    }
}
