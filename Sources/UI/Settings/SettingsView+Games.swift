import SwiftUI
import AppKit
import Defaults

extension SettingsView {
    var gamesSection: some View {
        Section {
            Toggle("Automatically record while playing games", isOn: $autoRecordGamesEnabled)

            if autoRecordGamesEnabled {
                gameAutoRecordDisclaimer

                Toggle("Stop recording when the game closes", isOn: $autoRecordStopWhenGameCloses)

                ForEach(autoRecordGameBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        Image(systemName: "gamecontroller.fill")
                            .foregroundStyle(AppTheme.accent)
                        Text(gameDisplayName(for: bundleID))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            removeManualGame(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from the games list")
                    }
                }

                Menu {
                    let candidates = addableRunningApps()
                    if candidates.isEmpty {
                        Text("No other apps are running")
                    } else {
                        ForEach(candidates) { app in
                            Button(app.name) { addManualGame(app.bundleID) }
                        }
                    }
                } label: {
                    Label("Add a game manually…", systemImage: "plus")
                }
            }
        } header: {
            sectionHeader(icon: "gamecontroller", title: "Games")
        } footer: {
            Text("Most games are detected automatically. If a game isn't picked up, add it manually while it's running — many Steam games need this.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    /// Explains the idle-until-game behaviour so users don't assume the feature
    /// records in the background the whole time it's switched on.
    private var gameAutoRecordDisclaimer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.accent)
                .font(.system(size: 15))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("How this works")
                    .font(.callout.weight(.semibold))
                Text(gameAutoRecordDisclaimerBody)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
                .fill(AppTheme.accent.opacity(0.12))
        )
    }

    private var gameAutoRecordDisclaimerBody: String {
        let base = "The app does not record or buffer in the background while this is on. "
            + "It stays idle until you open a game, then starts recording from scratch."
        if autoRecordStopWhenGameCloses {
            return base + " When the game closes, recording stops."
        }
        return base + " Recording keeps going after the game closes until you stop it."
    }

    /// Currently running foreground apps that aren't already on the list (and
    /// aren't this app), for the "Add a game manually" picker.
    func addableRunningApps() -> [AudioApplicationOption] {
        let existing = Set(autoRecordGameBundleIDs)
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AudioApplicationOption? in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != ownID,
                      !existing.contains(bundleID),
                      seen.insert(bundleID).inserted else {
                    return nil
                }
                return AudioApplicationOption(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolves a stored bundle id to a readable name, falling back to the id
    /// when the app isn't currently running.
    func gameDisplayName(for bundleID: String) -> String {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .localizedName ?? bundleID
    }

    func addManualGame(_ bundleID: String) {
        guard !autoRecordGameBundleIDs.contains(bundleID) else { return }
        autoRecordGameBundleIDs.append(bundleID)
    }

    func removeManualGame(_ bundleID: String) {
        autoRecordGameBundleIDs.removeAll { $0 == bundleID }
    }
}
