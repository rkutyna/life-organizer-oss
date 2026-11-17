import Foundation

/// Where the app keeps its own files. Everything is under the app's bundle id, so it never
/// shares a folder with another app.
public enum AppPaths {
    /// The last good copy of each read (`ResponseCache`): `~/Library/Caches/<bundle id>/responses`.
    /// Safe to delete at any time.
    public static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lifeorganizerformac.app", isDirectory: true)
            .appendingPathComponent("responses", isDirectory: true)
    }
}
