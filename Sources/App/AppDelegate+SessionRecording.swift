import Foundation
import Encode
import Feedback
import Save
import UI

/// Why a screen recording stopped — drives whether (and how) the user is told.
enum SessionRecordingStopReason {
    /// The user pressed the hotkey / menu item (or the app is quitting).
    case userToggled
    /// A capture/encoding setting changed, forcing an encoder restart.
    case captureSettingsChanged
    /// Free disk space dropped below the safety margin.
    case lowDisk
    /// The underlying capture pipeline stopped (manual replay toggle, sleep/wake,
    /// interruption).
    case pipelineStopped
}

@MainActor
extension AppDelegate {
    // MARK: - Capture union

    /// System audio must be captured when either the replay buffer or an active
    /// recording wants it. Read while (re)starting the pipeline.
    var desiredSystemAudioForSCK: Bool {
        AppSettings.captureSystemAudio || (isSessionRecordingActive && sessionWantsSystemAudio)
    }

    /// Microphone must be captured when either the replay buffer or an active
    /// recording wants it.
    var desiredMicEnabled: Bool {
        AppSettings.captureMicrophone || (isSessionRecordingActive && sessionWantsMicrophone)
    }

    // MARK: - Serialized start/stop

    /// User-initiated start/stop run one-at-a-time so they can never interleave
    /// across their `await`s — which otherwise orphans the capture pipeline on a
    /// rapid start→stop, or double-finalizes on a repeated low-disk stop.
    private func enqueueSessionOp(_ op: @escaping @MainActor () async -> Void) {
        let previous = sessionRecordingOpTask
        sessionRecordingOpTask = Task { @MainActor in
            _ = await previous?.value
            await op()
        }
    }

    func toggleScreenRecording() {
        enqueueSessionOp { [weak self] in
            guard let self else { return }
            if self.isSessionRecordingActive {
                await self.performStopScreenRecording(reason: .userToggled)
            } else {
                await self.performStartScreenRecording()
            }
        }
    }

    func stopScreenRecording(reason: SessionRecordingStopReason) {
        enqueueSessionOp { [weak self] in
            guard let self, self.isSessionRecordingActive else { return }
            await self.performStopScreenRecording(reason: reason)
        }
    }

    // MARK: - Start

    private func performStartScreenRecording() async {
        guard !isSessionRecordingActive else { return }

        // The recording taps the primary composite encoder; dual "separate files"
        // has no single composite stream (like the long buffer), so block it.
        if isSeparateDualSaveMode {
            NotificationManager.shared.showOperationalNotification(
                title: "Screen Recording Unavailable",
                body: "Turn off saving dual displays as separate files to record a single screen recording."
            )
            return
        }

        if let available = availableDiskCapacityBytes(), available < 1_000 * 1024 * 1024 {
            NotificationManager.shared.showOperationalNotification(
                title: "Not Enough Disk Space",
                body: "Free up at least 1 GB before starting a screen recording."
            )
            return
        }

        let wantsSystemAudio = AppSettings.sessionRecordingSystemAudio
        let wantsMicrophone = AppSettings.sessionRecordingMicrophone

        // Adding system audio the replay buffer isn't already capturing requires a
        // one-time capture restart, which resets the replay buffer. Tell the user.
        if isCaptureRunning, wantsSystemAudio, !AppSettings.captureSystemAudio {
            NotificationManager.shared.showOperationalNotification(
                title: "Replay Buffer Reset",
                body: "Recording system audio restarted capture to add it, which cleared the current replay buffer."
            )
        }

        sessionWantsSystemAudio = wantsSystemAudio
        sessionWantsMicrophone = wantsMicrophone
        isSessionRecordingActive = true
        sessionRecordingStartedAt = Date()
        sessionAppendPump.configure(recordSystemAudio: wantsSystemAudio, recordMicrophone: wantsMicrophone)

        await sessionRecorder.start(
            outputDirectory: AppSettings.outputDirectoryURL,
            recordSystemAudio: wantsSystemAudio,
            recordMicrophone: wantsMicrophone,
            baseName: resolvedClipBaseName()
        )
        await activateScreenRecordingCapture(wantsSystemAudio: wantsSystemAudio, wantsMicrophone: wantsMicrophone)
    }

    private func activateScreenRecordingCapture(wantsSystemAudio: Bool, wantsMicrophone: Bool) async {
        if !isCaptureRunning {
            captureAutoStartedBySessionRecording = true
            await startCapturePipelineAsync(userInitiated: false)
            guard isCaptureRunning else {
                NotificationManager.shared.showOperationalNotification(
                    title: "Screen Recording Failed",
                    body: "Screen capture could not start, so recording did not begin."
                )
                await rollBackScreenRecordingStart()
                return
            }
        } else if wantsSystemAudio && !AppSettings.captureSystemAudio {
            // System audio comes from the SCK stream and is fixed at stream
            // creation, so a one-time restart is needed to add it. The append pump
            // is still inactive, so this restart does not trip the
            // stop-on-reconfigure finalize.
            await restartFullPipeline()
            guard isCaptureRunning else {
                await rollBackScreenRecordingStart()
                return
            }
        } else if wantsMicrophone {
            // Mic is an independent device path — added live, no restart.
            await applyMicSettingIfNeeded()
        }

        sessionAppendPump.setActive(true)
        // Ask the encoder for an immediate keyframe so the recording opens on a
        // decodable frame (no black lead-in) without waiting for the next natural
        // keyframe up to ~2s away.
        videoEncoder.forceNextKeyframe()
        menuBarState.setSessionRecording(true)
        statusItemController.refreshPresentation()
    }

    private func rollBackScreenRecordingStart() async {
        sessionAppendPump.setActive(false)
        _ = await sessionRecorder.stop()
        let ownedPipeline = captureAutoStartedBySessionRecording
        isSessionRecordingActive = false
        sessionRecordingStartedAt = nil
        captureAutoStartedBySessionRecording = false
        menuBarState.setSessionRecording(false)
        // Never leave a pipeline running that only this (failed) recording started.
        if ownedPipeline, isCaptureRunning {
            await stopCapturePipelineAsync()
        }
        statusItemController.refreshPresentation()
    }

    // MARK: - Stop

    private func performStopScreenRecording(reason: SessionRecordingStopReason) async {
        await finalizeSessionRecording(reason: reason, mayStopPipeline: true, revertAuxiliaryAudio: true)
    }

    /// Hook for the pipeline teardown/reshape paths. Finalizes an *attached*
    /// recording (samples flowing). `mayStopPipeline` is true only for the reshape
    /// path (`applyPipelineShapeChanges`), which otherwise leaves an owned pipeline
    /// running; the `stopCapturePipelineAsync` hook passes false because it is
    /// already stopping the pipeline itself.
    func finalizeSessionRecordingIfActive(
        reason: SessionRecordingStopReason,
        mayStopPipeline: Bool = false
    ) async {
        guard sessionAppendPump.isActive else { return }
        await finalizeSessionRecording(
            reason: reason,
            mayStopPipeline: mayStopPipeline,
            revertAuxiliaryAudio: false
        )
    }

    /// Finalizes and saves the recording. The in-flight guard makes this safe to
    /// call from overlapping paths (user stop, low-disk, pipeline teardown) — only
    /// the first runs; the rest no-op.
    private func finalizeSessionRecording(
        reason: SessionRecordingStopReason,
        mayStopPipeline: Bool,
        revertAuxiliaryAudio: Bool
    ) async {
        guard isSessionRecordingActive, !isSessionFinalizeInProgress else { return }
        isSessionFinalizeInProgress = true
        defer { isSessionFinalizeInProgress = false }

        // Stop sample flow, then show the same Saving… → Saved flash the replay
        // save uses while the file finalizes and drains its queue.
        sessionAppendPump.setActive(false)
        let didBeginSaving = menuBarState.beginSaving()
        statusItemController.refreshPresentation()

        await sessionAppendPump.flush()
        let savedURL = await sessionRecorder.stop()

        let startedAt = sessionRecordingStartedAt
        let ownedPipeline = captureAutoStartedBySessionRecording
        let elapsed = startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        isSessionRecordingActive = false
        sessionRecordingStartedAt = nil
        captureAutoStartedBySessionRecording = false

        menuBarState.setSessionRecording(false)
        if let savedURL {
            statusItemController.setLastClip(savedURL)
        }
        if didBeginSaving {
            menuBarState.finishSaving(success: savedURL != nil)
        }
        announceScreenRecordingStop(savedURL: savedURL, elapsed: elapsed, reason: reason)

        if mayStopPipeline, ownedPipeline, isCaptureRunning {
            // The recording started the pipeline and nothing else needs it.
            await stopCapturePipelineAsync()
        } else if revertAuxiliaryAudio, isCaptureRunning {
            // Replay keeps running: drop the mic the recording added if replay
            // doesn't want it. System audio stays until the next full restart —
            // dropping it now would briefly interrupt the replay buffer.
            await applyMicSettingIfNeeded()
        }

        statusItemController.refreshPresentation()
    }

    /// Finalizes an in-progress recording during app termination, then stops
    /// capture. Awaited from `applicationShouldTerminate` so the file is saved
    /// before the process exits.
    func finalizeSessionRecordingForTermination() async {
        if isSessionRecordingActive {
            await finalizeSessionRecording(reason: .userToggled, mayStopPipeline: false, revertAuxiliaryAudio: false)
        }
        await stopCapturePipelineAsync()
    }

    private func announceScreenRecordingStop(
        savedURL: URL?,
        elapsed: TimeInterval,
        reason: SessionRecordingStopReason
    ) {
        if let savedURL {
            if AppSettings.playAudioCueOnSave {
                AudioCue.playSaveSuccess()
            }
            if AppSettings.showNotificationOnSave {
                NotificationManager.shared.showClipSavedNotification(fileURL: savedURL, clipDuration: elapsed)
            }
            if let stopBody = Self.stopReasonBody(reason, saved: true) {
                NotificationManager.shared.showOperationalNotification(title: "Screen Recording Stopped", body: stopBody)
            }
            return
        }

        // No file. If the recording ran for a bit it means the writer failed;
        // a sub-second recording is just a too-quick start→stop.
        if elapsed >= 1 {
            NotificationManager.shared.showSaveFailedNotification(
                error: "The screen recording could not be finalized."
            )
        } else if let stopBody = Self.stopReasonBody(reason, saved: false) {
            NotificationManager.shared.showOperationalNotification(title: "Screen Recording Stopped", body: stopBody)
        }
    }

    private static func stopReasonBody(_ reason: SessionRecordingStopReason, saved: Bool) -> String? {
        let suffix = saved ? " The clip up to that point was saved." : ""
        switch reason {
        case .userToggled:
            return nil
        case .captureSettingsChanged:
            return "Changing capture or encoding settings ended the recording.\(suffix)"
        case .lowDisk:
            return "The disk is almost full, so recording stopped.\(suffix)"
        case .pipelineStopped:
            return "Screen capture stopped, so the recording ended.\(suffix)"
        }
    }
}
