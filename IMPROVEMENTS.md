# ReplayMac — Improvement Findings

Review date: 2026-05-23

ReplayMac is a solid, focused macOS instant-replay clipper. The hard parts — ScreenCaptureKit capture, VideoToolbox encoding, GOP-aware ring buffers, A/V sync at save time, and SCK `-3821` recovery — are already done well. The biggest opportunities are **settings/UI trustworthiness**, **background-app operational polish**, and a **test/CI safety net**.

---

## 1. Architecture: `AppDelegate` is doing too much

`Sources/App/AppDelegate.swift` is ~950 lines and owns capture, encoding, ring buffers, hotkeys, memory budgeting, settings reconciliation, window management, and save orchestration. The SPM modules (`Capture`, `Encode`, `RingBuffer`, etc.) are clean, but all wiring lives in one place.

**Recommendation:** Extract a `RecordingCoordinator` or `CapturePipelineController` that owns:

- start/stop/reconcile lifecycle
- dual vs single mode
- interruption handling
- memory enforcement

This would make the runtime settings reconciler easier to reason about and test without launching the full app.

**Duplicate Clip Library entry point:** `ReplayMacApp` declares a SwiftUI `Window("Clip Library")`, while `AppDelegate.openClipLibraryWindow()` builds its own `NSWindowController`. The menu bar uses the AppDelegate path. Pick one (prefer the SwiftUI scene + `openWindow(id:)`) to avoid drift and duplicate windows.

---

## 2. Settings that don't fully match the UI

| Setting | Issue |
|---|---|
| **Mic device picker** | Shown in Settings but disabled. `MicCapture` always uses `engine.inputNode` (system default). `microphoneID` is stored but never read. |
| **Watermark toggle** | `WatermarkCompositor.applyIfEnabled` is explicitly a no-op to preserve save latency. The toggle is misleading unless labeled "coming soon" or removed. |
| **Memory cap** | UI slider (256 MB–4 GB) drives `enforceMemoryBudgets()` in the monitoring loop, but ring buffers are created with hardcoded per-buffer caps (`VideoRingBuffer` defaults to 1.5 GB each; five buffers exist in dual mode). The setting does not propagate into `RingBuffer.memoryCap`. |

`restart-fix.md` documents the runtime settings work well. Much of it is already implemented (runtime reconciler, SCK config updates, encoder restarts). Remaining gaps: mic device selection and honest memory-cap semantics.

---

## 3. UX polish

### "Saved" flashes before save completes

`saveConfiguredClip` calls `menuBarState.flashSavedState()` before the async write finishes. A slow disk or empty buffer means the badge says "Saved" while the save is still running or about to fail.

### Silent failures when recording stops

`handleCaptureInterruption` stops capture on GPU pressure, permission revocation, or display disconnect — but only logs to console. For a menu bar app, a notification ("Recording stopped — display disconnected") would be high value.

### Capture start failures are invisible

Failed permission or missing display paths hit `print("Failed to start capture: ...")` with no in-app alert. First-run onboarding for Screen Recording + Microphone would help, especially given the README's Gatekeeper note.

### Menu bar badge is minimal

Buffer duration and memory show in the dropdown menu, not on the badge itself. A thin progress ring or `MM:SS / cap` on the icon would make "am I actually buffering?" obvious — especially after a settings change clears the video buffer.

### Hardcoded quick-save durations

Hotkeys for 15s and 60s are fixed. Configurable "quick save" durations (or one hotkey bound to buffer duration) would feel more natural than adding more preset hotkeys.

---

## 4. Product features to consider

- **Window / app capture** — full display only via `SCContentFilter(display:)`. Window/app capture reduces file size and avoids leaking other monitors.
- **Clip library depth** — missing: rename, multi-select delete, export/share, search/filter, watch folders outside `~/Movies/ReplayMac`, open library from save notification.
- **Configurable save format** — MP4 only today.
- **Notarization** — README warns users to right-click → Open. Notarization + Developer ID signing removes the biggest adoption friction for a free utility.

---

## 5. Testing and CI

**Current coverage (good):**

- Ring buffer unit tests (time/memory eviction, GOP alignment, dynamic time cap)
- Save metadata and timeline offset tests
- Encoder initialization tests
- CaptureDelegate frame-status tests

**Gaps:**

- No GitHub Actions or CI — `swift test` and `build-app.sh` are not automated on push/PR
- No end-to-end save test — `SavePipelineTests` never feeds real sample buffers through `ClipSaver.saveClip` and verifies a playable MP4
- No tests for runtime settings reconciliation (debounced reconciler in `AppDelegate`)
- Capture/encoder tests are shallow (init and frame-status only)

**Priority:** A single macOS CI job running `swift test`, plus one ClipSaver integration test that writes and validates an MP4.

---

## 6. Logging and observability

Inconsistent split between `os.Logger` (e.g. `CaptureManager`, `ClipSaver`) and dozens of `print()` calls — especially verbose `[SAVE]`, `[AUDIO]`, and `[ENCODE]` logging in production paths.

**Recommendation:**

- Gate debug logs behind `#if DEBUG` or an Advanced "Verbose logging" toggle
- Route everything through `Logger` with privacy annotations
- Optionally write logs to `~/Library/Logs/ReplayMac/` for support

The 5-second monitoring loop in `startMonitoring()` printing ring buffer stats is useful during development but noisy in production.

---

## 7. Concurrency and correctness

`StrictConcurrency` is enabled on the app target, but `@unchecked Sendable` is used across most hot-path types (`VideoRingBuffer`, `VideoEncoder`, `MicCapture`, `AppDelegate`, etc.).

**Spots to revisit:**

- `AppDelegate` marked `@unchecked Sendable` while also `@MainActor` — likely unnecessary
- `estimatedAvailableMemoryBytes()` uses `physicalMemory - resident_size`, which is not a reliable "available memory" signal on macOS. Consider `host_statistics64` / `vm_statistics64` or thermal state
- `MicCapture` does not reset `firstBufferHostTime` / `totalOutputFrames` on stop/restart — possible PTS discontinuities after toggling mic at runtime

---

## 8. Build and release hygiene

`build-app.sh` works but is fragile:

- Double `swift build` with `sed` patch on generated `resource_bundle_accessor.swift` is brittle across SwiftPM versions
- Ad-hoc signing fallback causes repeated permission prompts (script warns about this)
- `ClipMac.entitlements` vs `ReplayMac.dev.entitlements` naming inconsistency; sandbox entitlements exist but are not used in the build script

An Xcode project or standard `xcodebuild -scheme` packaging would reduce custom build logic over time.

---

## 9. Small polish items

- **Sparkle appcast URL** defaults to empty — updates silently disabled unless configured at release time
- **Save notification** reveals in Finder on click but does not offer "Play" or "Open in library"
- **Quality presets** trigger multiple reconciler passes when switched while recording — already debounced at 150ms; acceptable
- **README:** "not notarized" reads awkwardly (double negative)
- **Contributor docs** — module map, pipeline diagram, and "how to debug audio sync" would help. `restart-fix.md` is a great model; similar doc for the save pipeline would match it

---

## Recommended priority order

1. **Fix misleading UX** — save flash timing, watermark toggle, mic device picker, user-visible errors when capture stops/fails
2. **CI + one real ClipSaver integration test** — highest confidence per hour
3. **Extract pipeline coordinator from AppDelegate** — pays off as runtime behavior grows
4. **Wire memory cap properly into ring buffers** — makes Advanced settings trustworthy
5. **Notarization** — if targeting users outside your own machine
6. **Window capture + richer clip library** — product differentiation

---

## What's already strong

- Modular SPM layout with clear separation of concerns
- GOP-aware video ring buffer with keyframe-aligned clip extraction
- Concurrent AVAssetWriter track append (avoids deadlock)
- System audio deep-copy + gap silence injection
- SCK stream restart after GPU pressure (`-3821`)
- Runtime settings reconciler (partially complete per `restart-fix.md`)
- Thoughtful mic capture via AVAudioEngine (workaround for unreliable SCK mic on macOS 15)
- Quality presets and dual-display modes
