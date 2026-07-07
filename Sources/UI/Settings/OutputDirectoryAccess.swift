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

    /// Re-establish access to a previously chosen folder. Call once at launch,
    /// before anything touches the output directory.
    public static func restore() {
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

    private static func endScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
