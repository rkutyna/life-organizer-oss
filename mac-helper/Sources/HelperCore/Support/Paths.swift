import Foundation

/// Where the helper keeps its files. Nothing here is personal: every path is under the
/// current user's home directory.
public enum Paths {
    /// The default bundle id: the embedded Info.plist's, the default LaunchAgent label and the
    /// default Keychain service. All three can be changed (see `HelperConfig`).
    public static let defaultBundleId = "com.lifeorganizerformac.helper"

    public static var home: String { NSHomeDirectory() }

    /// Expand a leading `~` (only `~` or `~/...`; `~user` is not supported).
    public static func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// `~/.config/life-organizer-for-mac/helper.json`; `--config PATH` overrides it.
    public static var configFile: String { home + "/.config/life-organizer-for-mac/helper.json" }
    public static var logDir: String { home + "/Library/Logs/LifeOrganizerHelper" }
    public static var logFile: String { logDir + "/helper.log" }
    /// launchd's capture of the agent's stdout and stderr (normally empty: the helper logs to `logFile`).
    public static var launchdLogFile: String { logDir + "/launchd.log" }
    /// `LIFE_ORGANIZER_HELPER_STATE_DIR` overrides it (tests and trial runs).
    public static var stateDir: String {
        if let dir = ProcessInfo.processInfo.environment["LIFE_ORGANIZER_HELPER_STATE_DIR"], !dir.isEmpty { return expand(dir) }
        return home + "/Library/Application Support/LifeOrganizerHelper"
    }
    public static var launchAgentsDir: String { home + "/Library/LaunchAgents" }

    public static func launchAgentPlist(label: String) -> String { launchAgentsDir + "/\(label).plist" }
}

/// The helper's state files, in one directory (default `Paths.stateDir`).
public struct HelperStateFiles: Sendable, Equatable {
    public var directory: String

    public init(directory: String = Paths.stateDir) { self.directory = directory }

    public static var standard: HelperStateFiles { HelperStateFiles() }

    /// What the daemon last did (`status`, `doctor`).
    public var status: String { directory + "/status.json" }
    /// Create ops already applied, so a lost ack never creates a reminder twice.
    public var reminders: String { directory + "/reminders.json" }
    /// Held by the running daemon (`HelperLock`).
    public var lock: String { directory + "/helper.lock" }
}
