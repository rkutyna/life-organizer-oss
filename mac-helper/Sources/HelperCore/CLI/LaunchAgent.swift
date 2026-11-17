import Foundation

/// `~/Library/LaunchAgents/<label>.plist`, loaded into the user's GUI (Aqua) domain so the helper
/// runs as its own permission-responsible process and macOS can show it the Calendars and
/// Reminders prompts.
public enum LaunchAgent {
    static var domain: String { "gui/\(getuid())" }

    /// The agent's plist. `configPath` is passed as `--config` when it is not the default path.
    public static func plist(binary: String, label: String, configPath: String?) throws -> Data {
        var args = [binary, "run"]
        if let configPath, configPath != Paths.configFile { args += ["--config", configPath] }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": Paths.launchdLogFile,
            "StandardErrorPath": Paths.launchdLogFile,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public static func install(binary: String, label: String, configPath: String) throws -> [String] {
        var notes: [String] = []
        let resolved = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "not an executable: \(resolved)"])
        }
        if resolved.contains("/.build/") {
            notes.append("warning: \(resolved) is inside .build; a rebuild replaces it and macOS may ask for access again. Prefer scripts/install.sh, which copies it to ~/.local/bin.")
        }
        let plistPath = Paths.launchAgentPlist(label: label)
        let data = try plist(binary: resolved, label: label, configPath: configPath)
        try FileManager.default.createDirectory(atPath: Paths.launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: Paths.logDir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        notes.append("wrote \(plistPath)")
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 20)
        // bootout returns before the old job is gone; bootstrapping into a job still tearing down
        // fails with error 5. Wait for it, and retry a refused bootstrap a few times.
        waitUntilUnloaded(label: label, timeout: 10)
        var r = try Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath], timeout: 20)
        for _ in 0..<3 where !r.ok {
            Thread.sleep(forTimeInterval: 1)
            waitUntilUnloaded(label: label, timeout: 5)
            r = try Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath], timeout: 20)
        }
        guard r.ok else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed (\(r.status)): \(r.err)"])
        }
        notes.append("loaded \(label) into \(domain); log: \(Paths.logFile)")
        notes.append("On first run macOS asks to allow \(HelperRuntime.appName) full access to Calendars and to Reminders; approve both.")
        return notes
    }

    /// Polls `launchctl print` until the job is no longer known to launchd.
    static func waitUntilUnloaded(label: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let r = try? Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 5), r.ok else { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    public static func uninstall(label: String) throws -> [String] {
        var notes: [String] = []
        let r = try Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 20)
        notes.append(r.ok ? "unloaded \(label)" : "not loaded (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
        let plistPath = Paths.launchAgentPlist(label: label)
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
            notes.append("removed \(plistPath)")
        }
        notes.append("the token stays in the Keychain and the config stays in place; remove them by hand if you are done")
        return notes
    }

    /// Read-only: `state = running, pid = 123` when the job is loaded, nil when it is not.
    public static func loadedState(label: String) -> String? {
        guard let r = try? Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 10), r.ok else { return nil }
        return parsePrint(r.out)
    }

    static func parsePrint(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + " = ") }.map { String($0.dropFirst(key.count + 3)) }
        }
        return ["state = \(value("state") ?? "?")", value("pid").map { "pid = \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}
