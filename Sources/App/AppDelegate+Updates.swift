import UI

@MainActor
extension AppDelegate {
    func checkForAvailableUpdate() {
        // App Store builds ship updates through the store; the menu's
        // "Update Available" item never appears because nothing sets
        // menuBarState.availableUpdate.
        #if !APPSTORE
        guard let currentVersion = UpdateChecker.currentAppVersion else {
            print("Skipping update check: app version is unavailable.")
            return
        }

        Task {
            do {
                let update = try await UpdateChecker.checkForUpdate(currentVersion: currentVersion)
                menuBarState.setAvailableUpdate(update)
                statusItemController.refreshPresentation()
            } catch {
                print("Update check failed: \(error.localizedDescription)")
            }
        }
        #endif
    }
}

