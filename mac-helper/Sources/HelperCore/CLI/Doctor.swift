import Foundation

/// `codesign -dv` of this executable (read-only).
public struct SignatureSummary: Sendable, Equatable {
    public var identifier: String?
    public var plistBound: Bool
    public var detail: String

    public init(identifier: String?, plistBound: Bool, detail: String) {
        self.identifier = identifier; self.plistBound = plistBound; self.detail = detail
    }

    public static func current() -> SignatureSummary? {
        guard let exe = Bundle.main.executablePath,
              let r = try? Shell.run("/usr/bin/codesign", ["-dv", exe], timeout: 10) else { return nil }
        let lines = (r.err + r.out).split(separator: "\n").map(String.init)
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let identifier = value("Identifier")
        // Bound: "Info.plist entries=12"; unbound: "Info.plist=not bound".
        let bound = lines.contains { $0.hasPrefix("Info.plist entries=") }
        var flags = "?"
        if let cd = lines.first(where: { $0.hasPrefix("CodeDirectory") }), let range = cd.range(of: "flags=") {
            flags = String(cd[range.upperBound...].prefix { $0 != " " })
        }
        let team = value("TeamIdentifier").map { $0 == "not set" ? "none (ad-hoc)" : "set" } ?? "?"
        var detail = "identifier \(identifier ?? "?"), Info.plist \(bound ? "bound" : "not bound"), flags \(flags), team id \(team)"
        if !bound || identifier != Bundle.main.bundleIdentifier {
            detail += " (re-sign with scripts/install.sh so macOS sees the bundle id)"
        }
        return SignatureSummary(identifier: identifier, plistBound: bound, detail: detail)
    }
}

/// `organizer-helper doctor`: read-only checks. Never requests Calendars or Reminders access
/// (status queries only), never writes anything, and never prints the token.
public enum Doctor {
    public static func run(config: HelperConfig, configPath: String, configExists: Bool, context: CLIContext) async -> Int32 {
        var problems = 0
        func line(_ ok: Bool?, _ label: String, _ detail: String) {
            let mark = ok == nil ? "[ -- ]" : (ok! ? "[ ok ]" : "[FAIL]")
            if ok == false { problems += 1 }
            context.out("\(mark) \(label): \(detail)")
        }
        let env = context.makeEnvironment(config)
        context.out("organizer-helper \(HelperVersion.string) doctor")

        // Config
        line(configExists, "config", configExists ? configPath : "\(configPath) missing (copy helper.example.json there)")
        if configExists, let problem = HelperConfig.permissionProblem(path: configPath, holdsToken: config.holdsToken) {
            line(false, "config permissions", problem.message + (problem.refuse ? " (run refuses to start)" : ""))
        }
        line(config.serverURL != nil, "server url", config.serverURL?.absoluteString ?? config.serverURLProblem ?? "unusable")
        if config.usesInsecureHTTP {
            line(false, "server url", "WARNING: plain http to another host (server.allow_insecure_http); the token travels unencrypted")
        }
        let resolved = TokenResolver.resolve(config: config, keychain: env.keychain)
        line(resolved.token != nil, "ingest token", resolved.source.description)
        line(nil, "streams", "calendar \(config.calendar.enabled ? "on" : "off"), reminders \(config.reminders.enabled ? "on" : "off")"
             + (config.reminders.enabled ? " (apply ops \(config.reminders.apply_ops ? "on" : "off"), polls every \(Int(config.reminders.ops_poll_seconds))s)" : ""))
        line(nil, "host", config.hostName)

        // The binary: its embedded Info.plist and signature, which macOS keys the grants on.
        let bundleId = Bundle.main.bundleIdentifier
        let calUsage = Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String
        let remUsage = Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") as? String
        line(bundleId != nil && calUsage != nil && remUsage != nil, "embedded Info.plist",
             bundleId.map { "\($0); calendars usage string \(calUsage == nil ? "MISSING" : "present"), reminders usage string \(remUsage == nil ? "MISSING" : "present")" }
                ?? "missing (the binary was not linked with -sectcreate __TEXT __info_plist)")
        if let bundleId, bundleId != config.bundle_id {
            line(nil, "bundle id", "config bundle_id is \(config.bundle_id), the binary's is \(bundleId); the Keychain service and LaunchAgent label follow the config")
        }
        if let sig = context.signature() {
            line(sig.identifier == bundleId && sig.plistBound, "code signature", sig.detail)
        }

        // Permissions: status only, never a request.
        let fromShell = getppid() != 1
        let shellNote = fromShell ? "; run from a shell this is the terminal app's grant, not the LaunchAgent's" : ""
        line(nil, "calendars (this process)", env.permissions.calendars().rawValue + shellNote)
        line(nil, "reminders (this process)", env.permissions.reminders().rawValue + shellNote)
        if let st = DaemonStatus.load(path: context.stateFiles.status) {
            if config.calendar.enabled {
                let a = st.calendar_authorization
                line(a.map { $0 == HelperAuthorization.fullAccess.rawValue }, "calendars (daemon)", "\(a ?? "unknown") as of \(ISODate.string(st.updated_at))")
            }
            if config.reminders.enabled {
                let a = st.reminders_authorization
                line(a.map { $0 == HelperAuthorization.fullAccess.rawValue }, "reminders (daemon)", "\(a ?? "unknown") as of \(ISODate.string(st.updated_at))")
            }
        } else {
            line(nil, "daemon", "no status yet (\(context.stateFiles.status)); it appears after the LaunchAgent's first run")
        }

        // Server: POST {} to the calendar endpoint. The server checks the token first, then
        // rejects the empty body (422), so nothing is written either way.
        if config.serverURL != nil, resolved.token != nil {
            let client = ServerClient(baseURL: config.serverURL, tokens: TokenProvider(fixed: resolved.token),
                                      transport: env.transport, retryDelays: [])
            do {
                let (code, _) = try await client.request(method: "POST", path: IngestStream.calendar.path, body: Data("{}".utf8),
                                                         label: "doctor", throwOnHTTPError: false, retry: false)
                let (ok, detail): (Bool, String)
                switch code {
                case 422, 200..<300: (ok, detail) = (true, "reachable, token accepted (HTTP \(code))")
                case 401, 403: (ok, detail) = (false, "reachable, token REJECTED (HTTP \(code)); make an ingest-scoped token in Settings")
                case 404: (ok, detail) = (false, "reachable, but /api/ingest/calendar is not there (HTTP 404); check server.url")
                default: (ok, detail) = (false, "reachable, HTTP \(code)")
                }
                line(ok, "server", detail)
            } catch {
                line(false, "server", "unreachable: \(error)")
            }
        } else {
            line(nil, "server", "skipped (url or token missing)")
        }

        let label = config.launchAgentLabel
        let plistPath = Paths.launchAgentPlist(label: label)
        let installed = FileManager.default.fileExists(atPath: plistPath)
        line(nil, "launch agent", installed ? "\(plistPath); \(context.launchAgentState(label) ?? "not loaded")" : "not installed (run organizer-helper install)")
        line(nil, "helper lock", HelperLock.currentHolder(path: context.stateFiles.lock).map { "held by \($0)" } ?? "free (no helper running)")
        line(nil, "log", config.logPath)

        context.out(problems == 0 ? "no problems found" : "\(problems) problem(s)")
        return problems == 0 ? 0 : 1
    }
}

/// `organizer-helper status`: what the daemon last did, read from its status file. Touches
/// neither EventKit nor the network.
public enum StatusCommand {
    public static func run(config: HelperConfig, context: CLIContext) -> Int32 {
        let label = config.launchAgentLabel
        if FileManager.default.fileExists(atPath: Paths.launchAgentPlist(label: label)) {
            context.out("launch agent: \(label), \(context.launchAgentState(label) ?? "not loaded")")
        } else {
            context.out("launch agent: not installed")
        }
        if let holder = HelperLock.currentHolder(path: context.stateFiles.lock) {
            context.out("running: \(holder)")
        } else {
            context.out("running: no helper holds the lock")
        }
        guard let st = DaemonStatus.load(path: context.stateFiles.status) else {
            context.out("no status yet (\(context.stateFiles.status))")
            return 0
        }
        context.out("last started: \(ISODate.string(st.started_at)) (pid \(st.pid), version \(st.version)); updated \(ISODate.string(st.updated_at))")
        context.out("calendars access: \(st.calendar_authorization ?? "unknown"); reminders access: \(st.reminders_authorization ?? "unknown")")
        for name in st.streams.keys.sorted() {
            let s = st.streams[name]!
            let success = s.last_success.map { ISODate.string($0) } ?? "never"
            context.out("\(name): last success \(success); \(s.last_result ?? "")")
            if let e = s.last_error, let at = s.last_error_at, at >= (s.last_success ?? .distantPast) {
                context.out("  last error at \(ISODate.string(at)): \(e)")
            }
        }
        return 0
    }
}
