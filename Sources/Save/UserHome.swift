import Foundation

/// The real user home directory, even under the App Sandbox.
///
/// Sandboxed processes get the app container from `NSHomeDirectory()` and
/// `FileManager`'s search-path APIs (`~/Library/Containers/…/Data`), so paths
/// built from them mention the container even when writes land in the real
/// folder through the container's symlinks. App Review flags any visible
/// container path as "saving user data to the app's container", so user-facing
/// locations must be built from the passwd entry, which always carries the
/// real home.
public enum UserHome {
    public static var directory: URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(filePath: String(cString: home), directoryHint: .isDirectory)
        }
        return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }

    public static var moviesDirectory: URL {
        directory.appending(path: "Movies", directoryHint: .isDirectory)
    }

    /// Replaces the real home prefix with `~` for display.
    public static func abbreviateForDisplay(_ path: String) -> String {
        var home = directory.path(percentEncoded: false)
        if !home.hasSuffix("/") {
            home += "/"
        }

        var result = path
        if result == home || result + "/" == home {
            result = "~"
        } else if result.hasPrefix(home) {
            result = "~/" + result.dropFirst(home.count)
        }
        if result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
