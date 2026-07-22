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

func replayCapSystemAudioProcessHandler(
    _ systemAudioCapture: SystemAudioCapture,
    sessionAppendPump: SessionAppendPump
) -> @Sendable (CMSampleBuffer) -> Void {
    { sampleBuffer in
        // Process system audio if either the replay buffer or an active screen
        // recording wants it. Per-consumer distribution is gated downstream.
        if AppSettings.captureSystemAudio || sessionAppendPump.systemAudioWanted {
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
    longBufferAppendPump: LongBufferAppendPump,
    sessionAppendPump: SessionAppendPump
) -> VideoEncoder.OutputHandler {
    { sampleBuffer in
        videoRingBuffer.append(encodedSample: sampleBuffer)
        // Wrap the encoded frame once, and only when a consumer actually wants it,
        // so an idle long buffer / inactive recording adds no per-frame work.
        let longWants = longBufferAppendPump.isEnabled
        let sessionWants = sessionAppendPump.isActive
        if longWants || sessionWants {
            let sample = LongBufferSample(sampleBuffer)
            if longWants { longBufferAppendPump.enqueueVideo(sample) }
            if sessionWants { sessionAppendPump.enqueueVideo(sample) }
        }
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
    longBufferAppendPump: LongBufferAppendPump,
    sessionAppendPump: SessionAppendPump
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        // Feed the replay buffer only when the replay buffer itself wants system
        // audio, so a recording that captures system audio (while replay doesn't)
        // never leaks into replay clips. The session pump gates on its own toggle.
        let replayWants = AppSettings.captureSystemAudio
        if replayWants {
            systemAudioRingBuffer.append(sampleBuffer)
        }
        let longWants = replayWants && longBufferAppendPump.isEnabled
        let sessionWants = sessionAppendPump.systemAudioWanted
        if longWants || sessionWants {
            let sample = LongBufferSample(sampleBuffer)
            if longWants { longBufferAppendPump.enqueueSystemAudio(sample) }
            if sessionWants { sessionAppendPump.enqueueSystemAudio(sample) }
        }
    }
}

func replayCapMicrophoneOutputHandler(
    micAudioRingBuffer: AudioRingBuffer,
    longBufferAppendPump: LongBufferAppendPump,
    sessionAppendPump: SessionAppendPump
) -> AudioEncoder.OutputHandler {
    { sampleBuffer in
        // Mic hardware may be running only because the recording wants it; keep it
        // out of replay clips unless the replay buffer's own mic toggle is on.
        let replayWants = AppSettings.captureMicrophone
        if replayWants {
            micAudioRingBuffer.append(sampleBuffer)
        }
        let longWants = replayWants && longBufferAppendPump.isEnabled
        let sessionWants = sessionAppendPump.microphoneWanted
        if longWants || sessionWants {
            let sample = LongBufferSample(sampleBuffer)
            if longWants { longBufferAppendPump.enqueueMicrophone(sample) }
            if sessionWants { sessionAppendPump.enqueueMicrophone(sample) }
        }
    }
}
