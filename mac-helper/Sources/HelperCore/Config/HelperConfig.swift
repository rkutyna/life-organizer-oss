import Foundation
import SystemConfiguration

/// The helper's config file (default `~/.config/life-organizer-for-mac/helper.json`, see
/// `helper.example.json`). Every key is optional and missing keys take the defaults below, so a
/// config holding only `server.url` is valid (the token can live in the Keychain).
public struct HelperConfig: Codable, Sendable {
    public struct Server: Codable, Sendable {
        /// The organizer's base URL, e.g. `https://organizer.example.com`. No default.
        public var url: String
        /// The `ingest`-scoped API token. null or absent: read it from the Keychain instead.
        @NullCodable public var token: String?
        public var timeout_seconds: Double
        /// Allow a plain `http://` url to a host other than this Mac. The token then travels
        /// unencrypted; only for a network you trust. Default false: such a url is refused.
        public var allow_insecure_http: Bool
        /// A Cloudflare Access service token's client id, for an organizer behind Cloudflare
        /// Access (a "Service Auth" policy). null or absent: no Access headers are sent.
        @NullCodable public var cf_access_client_id: String?
        /// Its client secret. null or absent while `cf_access_client_id` is set: read it from the
        /// Keychain (the config's Keychain service, account `cf-access-client-secret`).
        @NullCodable public var cf_access_client_secret: String?

        public init(url: String = "", token: String? = nil, timeout_seconds: Double = 30, allow_insecure_http: Bool = false,
                    cf_access_client_id: String? = nil, cf_access_client_secret: String? = nil) {
            self.url = url; self.token = token; self.timeout_seconds = timeout_seconds
            self.allow_insecure_http = allow_insecure_http
            self.cf_access_client_id = cf_access_client_id
            self.cf_access_client_secret = cf_access_client_secret
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Server()
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
            token = try c.decodeIfPresent(String.self, forKey: .token)
            timeout_seconds = try c.decodeIfPresent(Double.self, forKey: .timeout_seconds) ?? d.timeout_seconds
            allow_insecure_http = try c.decodeIfPresent(Bool.self, forKey: .allow_insecure_http) ?? d.allow_insecure_http
            cf_access_client_id = try c.decodeIfPresent(String.self, forKey: .cf_access_client_id)
            cf_access_client_secret = try c.decodeIfPresent(String.self, forKey: .cf_access_client_secret)
        }
    }

    /// Where `set-token` stores the token and where the helper looks for it when `server.token`
    /// is null: a generic password with this service and account.
    public struct Keychain: Codable, Sendable {
        /// null: the config's `bundle_id`.
        @NullCodable public var service: String?
        public var account: String

        public init(service: String? = nil, account: String = "ingest-token") {
            self.service = service; self.account = account
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            service = try c.decodeIfPresent(String.self, forKey: .service)
            account = try c.decodeIfPresent(String.self, forKey: .account) ?? "ingest-token"
        }
    }

    /// Apple Calendar -> `POST /api/ingest/calendar`. Read-only.
    public struct Calendar: Codable, Sendable {
        public var enabled = true
        /// Re-read this often; also re-read a few seconds after any Calendar change.
        public var interval_seconds: Double = 300
        public var past_days = 365
        public var future_days = 365
        /// How long to wait after a Calendar or Reminders change before re-reading.
        public var debounce_seconds: Double = 5

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Calendar()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            interval_seconds = try c.decodeIfPresent(Double.self, forKey: .interval_seconds) ?? d.interval_seconds
            past_days = try c.decodeIfPresent(Int.self, forKey: .past_days) ?? d.past_days
            future_days = try c.decodeIfPresent(Int.self, forKey: .future_days) ?? d.future_days
            debounce_seconds = try c.decodeIfPresent(Double.self, forKey: .debounce_seconds) ?? d.debounce_seconds
        }
    }

    /// Apple Reminders: the snapshot push and the organizer's queued changes ("ops").
    public struct Reminders: Codable, Sendable {
        /// Push the Reminders snapshot (and, with `apply_ops`, apply ops). false turns Reminders off.
        public var enabled = true
        /// Apply the organizer's queued changes (add, edit, complete) with EventKit.
        public var apply_ops = true
        /// Push the snapshot at least this often (also after a change in Reminders or after ops).
        public var snapshot_seconds: Double = 180
        /// How often to ask the organizer for ops (it shows "waiting for the Mac" after 2 minutes).
        public var ops_poll_seconds: Double = 30
        /// Completed reminders are sent for this many days after completion.
        public var completed_days = 30
        /// A due time set from the organizer gets an alarm at that time when the reminder has none.
        public var alarm_at_due_time = true

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Reminders()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            apply_ops = try c.decodeIfPresent(Bool.self, forKey: .apply_ops) ?? d.apply_ops
            snapshot_seconds = try c.decodeIfPresent(Double.self, forKey: .snapshot_seconds) ?? d.snapshot_seconds
            ops_poll_seconds = try c.decodeIfPresent(Double.self, forKey: .ops_poll_seconds) ?? d.ops_poll_seconds
            completed_days = try c.decodeIfPresent(Int.self, forKey: .completed_days) ?? d.completed_days
            alarm_at_due_time = try c.decodeIfPresent(Bool.self, forKey: .alarm_at_due_time) ?? d.alarm_at_due_time
        }
    }

    public var server = Server()
    /// The default Keychain service and LaunchAgent label. The bundle id macOS shows in prompts
    /// is the one embedded in the binary's Info.plist (see `scripts/release.sh`).
    public var bundle_id = Paths.defaultBundleId
    /// null: `bundle_id`.
    public var launch_agent_label: String?
    public var keychain = Keychain()
    /// Overrides the reported `host` (default: the Mac's local host name).
    public var host: String?
    /// Re-push an unchanged snapshot this often so the organizer's freshness strip stays green.
    public var heartbeat_seconds: Double = 900
    public var calendar = Calendar()
    public var reminders = Reminders()
    /// null: `~/Library/Logs/LifeOrganizerHelper/helper.log`.
    public var log_path: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HelperConfig()
        server = try c.decodeIfPresent(Server.self, forKey: .server) ?? d.server
        bundle_id = try c.decodeIfPresent(String.self, forKey: .bundle_id).flatMap { $0.isEmpty ? nil : $0 } ?? d.bundle_id
        launch_agent_label = try c.decodeIfPresent(String.self, forKey: .launch_agent_label).flatMap { $0.isEmpty ? nil : $0 }
        // Both name files (the LaunchAgent plist) and launchd services: reverse-DNS only.
        for (key, value) in [(CodingKeys.bundle_id, Optional(bundle_id)), (.launch_agent_label, launch_agent_label)] {
            if let value, !Self.isReverseDNS(value) {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription:
                    "\(key.stringValue) must be a reverse-DNS name such as org.example.helper (letters, digits, '-', dot-separated)")
            }
        }
        keychain = try c.decodeIfPresent(Keychain.self, forKey: .keychain) ?? d.keychain
        host = try c.decodeIfPresent(String.self, forKey: .host)
        heartbeat_seconds = try c.decodeIfPresent(Double.self, forKey: .heartbeat_seconds) ?? d.heartbeat_seconds
        calendar = try c.decodeIfPresent(Calendar.self, forKey: .calendar) ?? d.calendar
        reminders = try c.decodeIfPresent(Reminders.self, forKey: .reminders) ?? d.reminders
        log_path = try c.decodeIfPresent(String.self, forKey: .log_path)
    }

    // MARK: derived

    /// Server base URL without a trailing slash; nil when unset, not an http(s) URL, or plain
    /// http to another host without `server.allow_insecure_http` (`serverURLProblem` says which).
    public var serverURL: URL? {
        guard let (u, insecure) = parsedServerURL, !insecure || server.allow_insecure_http else { return nil }
        return u
    }

    /// Why `serverURL` is nil, or nil when it is usable.
    public var serverURLProblem: String? {
        guard let (_, insecure) = parsedServerURL else { return "server.url is unset or not an http(s) URL" }
        if insecure && !server.allow_insecure_http {
            return "server.url uses plain http to another host, so the token would travel unencrypted; "
                + "use https, or set server.allow_insecure_http to true for a network you trust"
        }
        return nil
    }

    /// True when the url in use is plain http to a host other than this Mac (allowed explicitly).
    public var usesInsecureHTTP: Bool { parsedServerURL?.insecure == true && server.allow_insecure_http }

    private var parsedServerURL: (url: URL, insecure: Bool)? {
        var s = server.url.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = u.host, !host.isEmpty else { return nil }
        return (u, scheme == "http" && !Self.isLoopback(host))
    }

    /// localhost, *.localhost, 127.0.0.0/8 and ::1.
    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// A reverse-DNS name: at least two dot-separated labels of letters, digits and '-'.
    public static func isReverseDNS(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, name.utf8.count <= 255 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.allSatisfy { c in
                (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D
            }
        }
    }

    public var launchAgentLabel: String { launch_agent_label ?? bundle_id }
    /// Whether the config file itself holds the token.
    public var holdsToken: Bool { !(server.token ?? "").isEmpty || !(server.cf_access_client_secret ?? "").isEmpty }
    /// The Keychain account of the Cloudflare Access client secret.
    public static let accessSecretAccount = "cf-access-client-secret"
    public var keychainService: String { keychain.service.flatMap { $0.isEmpty ? nil : $0 } ?? bundle_id }
    public var keychainAccount: String { keychain.account.isEmpty ? "ingest-token" : keychain.account }

    public var hostName: String { host ?? Self.localHostName() }
    public var logPath: String { log_path.map(Paths.expand) ?? Paths.logFile }

    /// Whether the daemon has any work (and so needs at least one EventKit permission).
    public var anyEnabled: Bool { calendar.enabled || reminders.enabled }

    public static func localHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty { return name.lowercased() }
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count)
        let raw = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (raw.hasSuffix(".local") ? String(raw.dropLast(6)) : raw).lowercased()
    }

    // MARK: loading

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(String, Error)
        case invalid(String, Error)

        public var description: String {
            switch self {
            case .unreadable(let p, let e): return "cannot read \(p): \(e.localizedDescription)"
            case .invalid(let p, let e): return "invalid JSON in \(p): \(e)"
            }
        }
    }

    /// What is wrong with the config file's permissions, or nil. `refuse`: anyone else may write
    /// it, so they could point the token (from the config or the Keychain) at another server.
    /// Otherwise a warning: it holds the token and others may read it.
    public static func permissionProblem(path: String, holdsToken: Bool) -> (message: String, refuse: Bool)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue else { return nil }
        let mode = String(perms & 0o777, radix: 8)
        if perms & 0o022 != 0 {
            return ("\(path) is writable by other users (mode \(mode)); run: chmod 600 \"\(path)\"", true)
        }
        if holdsToken && perms & 0o044 != 0 {
            return ("\(path) holds the token and is readable by other users (mode \(mode)); run: chmod 600 \"\(path)\"", false)
        }
        return nil
    }

    /// Loads the config; a missing file yields defaults (`exists == false`).
    public static func load(path: String = Paths.configFile) throws -> (config: HelperConfig, exists: Bool) {
        guard FileManager.default.fileExists(atPath: path) else { return (HelperConfig(), false) }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch { throw LoadError.unreadable(path, error) }
        do { return (try JSONDecoder().decode(HelperConfig.self, from: data), true) } catch { throw LoadError.invalid(path, error) }
    }
}
