import Cocoa
import SwiftUI
import UI

@MainActor
extension AppDelegate {
    func setupWindowObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func setupPowerObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        // Remember whether we were actively recording so we only resume what
        // the user actually had running. Captured before the OS tears the
        // capture stream down as the displays sleep.
        wasRecordingBeforeSleep = isCaptureRunning
    }

    @objc private func systemDidWake(_ notification: Notification) {
        guard AppSettings.resumeRecordingAfterWake,
              wasRecordingBeforeSleep,
              !isCaptureRunning else {
            wasRecordingBeforeSleep = false
            return
        }
        wasRecordingBeforeSleep = false

        // Give the displays a moment to come back before recreating the
        // capture stream, otherwise ScreenCaptureKit may fail to start.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !self.isCaptureRunning else { return }
            self.startCapturePipeline(userInitiated: false)
        }
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(bringVisibleWindowToFront: true)
        }
    }

    func updateActivationPolicy(bringVisibleWindowToFront: Bool = false) {
        let visibleWindows = NSApp.windows.filter { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        let hasVisibleWindows = !visibleWindows.isEmpty

        if hasVisibleWindows {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }

            guard bringVisibleWindowToFront else {
                return
            }

            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }

            if let windowToFront = NSApp.keyWindow ?? visibleWindows.first {
                windowToFront.makeKeyAndOrderFront(nil)
                windowToFront.orderFrontRegardless()
            }
        } else {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func openClipLibraryWindow() {
        if clipLibraryWindowController == nil {
            let hostingController = NSHostingController(rootView: ClipLibraryView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Clip Library"
            window.setContentSize(NSSize(width: 980, height: 620))
            window.styleMask = NSWindow.StyleMask([.titled, .closable, .miniaturizable, .resizable])
            clipLibraryWindowController = NSWindowController(window: window)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        clipLibraryWindowController?.showWindow(nil)
        clipLibraryWindowController?.window?.makeKeyAndOrderFront(nil)
        clipLibraryWindowController?.window?.orderFrontRegardless()
        updateActivationPolicy(bringVisibleWindowToFront: true)
    }

    func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NotificationCenter.default.post(name: .replayMacSettingsShouldOpenGeneral, object: nil)

        bringSettingsWindowToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            NotificationCenter.default.post(name: .replayMacSettingsShouldOpenGeneral, object: nil)
            self?.bringSettingsWindowToFront()
        }
    }

    func bringSettingsWindowToFront() {
        guard let settingsWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled) && $0 != clipLibraryWindowController?.window
        }) else {
            return
        }
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
    }

}
