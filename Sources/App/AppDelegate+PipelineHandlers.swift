@preconcurrency import CoreMedia

import Audio
import Capture
import Encode
import RingBuffer
import Save
import UI

func replayCapVideoEncodeHandler(_ encoder: VideoEncoder) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        encoder.encode(sampleBuffer: sampleBuffer)
    }
}

func replayCapPrimaryFrameCompositorHandler(_ frameCompositor: FrameCompositor) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        frameCompositor.pushPrimaryFrame(sampleBuffer)
    }
}

func replayCapSecondaryFrameCompositorHandler(_ frameCompositor: FrameCompositor) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        frameCompositor.pushSecondaryFrame(sampleBuffer)
    }
}

func replayCapSystemAudioProcessHandler(_ systemAudioCapture: SystemAudioCapture) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        if AppSettings.captureSystemAudio {
            systemAudioCapture.process(sampleBuffer: sampleBuffer)
        }
    }
}

func replayCapPerAppAudioHandler(_ systemAudioCapture: SystemAudioCapture) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        systemAudioCapture.process(sampleBuffer: sampleBuffer)
    }
}

func replayCapPrimaryVideoOutputHandler(
    videoRingBuffer: VideoRingBuffer,
    longBufferAppendPump: LongBufferAppendPump
) -> VideoEncoder.OutputHandler {
    { sampleBuffer in
        videoRingBuffer.append(encodedSample: sampleBuffer)
        longBufferAppendPump.enqueueVideo(LongBufferSample(sampleBuffer))
    }
}

func replayCapDualVideoOutputHandler(_ videoRingBuffer: VideoRingBuffer) -> VideoEncoder.OutputHandler {
    { sampleBuffer in
        videoRingBuffer.append(encodedSample: sampleBuffer)
    }
}

func replayCapFrameCompositorOutputHandler(_ videoEncoder: VideoEncoder) -> FrameCompositor.OutputHandler {
    replayCapVideoEncodeHandler(videoEncoder)
}

func replayCapAudioEncodeHandler(_ audioEncoder: AudioEncoder) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        audioEncoder.encode(sampleBuffer: sampleBuffer)
    }
}

func replayCapSystemAudioOutputHandler(
    systemAudioRingBuffer: AudioRingBuffer,
    longBufferAppendPump: LongBufferAppendPump
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        systemAudioRingBuffer.append(sampleBuffer)
        longBufferAppendPump.enqueueSystemAudio(LongBufferSample(sampleBuffer))
    }
}

func replayCapMicrophoneOutputHandler(
    micAudioRingBuffer: AudioRingBuffer,
    longBufferAppendPump: LongBufferAppendPump
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        micAudioRingBuffer.append(sampleBuffer)
        longBufferAppendPump.enqueueMicrophone(LongBufferSample(sampleBuffer))
    }
}
