import AppKit
import Foundation
import Defaults

public extension Defaults.Keys {
    static let outputDirectoryBookmark = Key<Data?>("outputDirectoryBookmark", default: nil)
}

/// Keeps sandbox access to a user-chosen output directory across launches.
///
/// The default `~/Movies/ReplayMac` location is covered by the
/// `com.apple.security.assets.movies.read-write` entitlement and needs no
/// bookmark; only custom folders picked in Settings go through here. The
/// scoped access is held open for the app's lifetime because clips can be
/// saved at any moment while recording.
@MainActor
public enum OutputDirectoryAccess {
    private static var scopedURL: URL?

    /// Persist access to a folder the user just picked in the open panel.
    /// The panel's implicit grant covers the rest of this session, so no
    /// scoped access needs to start here; the bookmark takes over on the
    /// next launch.
    public static func adopt(_ url: URL) {
        endScopedAccess()
        do {
            Defaults[.outputDirectoryBookmark] = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            Defaults[.outputDirectoryBookmark] = nil
            NSLog("OutputDirectoryAccess: failed to create bookmark for \(url.path): \(error)")
        }
    }

    /// Presents the standard folder picker and, on selection, persists both
    /// the path and the security-scoped access to it. Returns the new path,
    /// or `nil` if the user cancelled. Shared by Settings and onboarding.
    public static func promptUserToChoose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose Clip Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let suggestedURL = URL(
            filePath: Defaults[.outputDirectoryPath],
            directoryHint: .isDirectory
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        panel.directoryURL = if FileManager.default.fileExists(
            atPath: suggestedURL.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            suggestedURL
        } else {
            suggestedURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        let path = selectedURL.standardizedFileURL.path(percentEncoded: false)
        Defaults[.outputDirectoryPath] = path
        UserDefaults.standard.set(path, forKey: "outputDirectoryPath")
        UserDefaults.standard.synchronize()
        adopt(selectedURL)
        return path
    }

    /// Re-establish access to a previously chosen folder. Call once at launch,
    /// before anything touches the output directory.
    public static func restore() {
        migrateLegacyContainerDefault()

        guard let data = Defaults[.outputDirectoryBookmark] else { return }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // Folder is gone (deleted, or on an unmounted volume). Fall back to
            // the default output directory rather than failing every save.
            NSLog("OutputDirectoryAccess: dropping unresolvable bookmark: \(error)")
            Defaults[.outputDirectoryBookmark] = nil
            Defaults.reset(.outputDirectoryPath)
            return
        }

        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }

        if isStale, let fresh = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            Defaults[.outputDirectoryBookmark] = fresh
        }

        // Follow the folder if it was moved or renamed since last launch.
        let resolvedPath = url.standardizedFileURL.path(percentEncoded: false)
        if Defaults[.outputDirectoryPath] != resolvedPath {
            Defaults[.outputDirectoryPath] = resolvedPath
        }
    }

    /// Builds before 1.6.8 registered the sandbox-container Movies path
    /// (`~/Library/Containers/…/Data/Movies/ReplayMac`) as the default. Files
    /// still reached the real `~/Movies` through the container's symlink, but
    /// the stored path read as the hidden container. Drop it so the corrected
    /// default applies; folders the user picked themselves carry a bookmark
    /// and are left alone.
    private static func migrateLegacyContainerDefault() {
        guard Defaults[.outputDirectoryBookmark] == nil,
              Defaults[.outputDirectoryPath].contains("/Library/Containers/") else {
            return
        }
        Defaults.reset(.outputDirectoryPath)
        UserDefaults.standard.removeObject(forKey: "outputDirectoryPath")
    }

    private static func endScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
