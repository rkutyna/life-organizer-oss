import Foundation
import OrganizerAPI

/// Which server the app talks to, and with which token.
///
/// The address:
/// 1. the launch environment's `ORGANIZER_BASE_URL` (scripts, the Xcode scheme);
/// 2. else the address saved in Settings;
/// 3. else the default, `http://localhost:8600` (the server on this Mac).
///
/// The token:
/// 1. the launch environment's `ORGANIZER_TOKEN` (development; the Keychain is then never read);
/// 2. else the token saved in the Keychain from Settings (`TokenStore`).
///
/// The Cloudflare Access service token (optional, for a server behind Cloudflare Access):
/// 1. `ORGANIZER_CF_ACCESS_CLIENT_ID` and `ORGANIZER_CF_ACCESS_CLIENT_SECRET` (both, development);
/// 2. else the client id saved in Settings and the secret saved in the Keychain.
///
/// The token is made in the web app, Settings → API tokens, with author "You" (`me`) and the scopes
/// `api` and `mail`.
public enum ServerConfig {
    /// The default address: the organizer on this Mac (`docker compose up`, docs/SETUP.md).
    public static let defaultURL = URL(string: "http://localhost:8600")!

    public static let environmentKey = "ORGANIZER_BASE_URL"
    public static let tokenEnvironmentKey = "ORGANIZER_TOKEN"
    /// The Settings value, in the app's own defaults.
    public static let settingsKey = "server.baseURL"
    public static let accessIDEnvironmentKey = "ORGANIZER_CF_ACCESS_CLIENT_ID"
    public static let accessSecretEnvironmentKey = "ORGANIZER_CF_ACCESS_CLIENT_SECRET"
    /// The Access client id (not a secret), in the app's own defaults. The secret is in the
    /// Keychain (`KeychainTokenStore.accessSecret`).
    public static let accessIDKey = "server.cfAccessClientId"

    public enum Source: String, Sendable {
        case environment
        case settings
        case defaultValue

        public var label: String {
            switch self {
            case .environment: "From the launch environment (\(ServerConfig.environmentKey))"
            case .settings: "Set in Settings"
            case .defaultValue: "Default"
            }
        }
    }

    public enum TokenSource: String, Sendable {
        case environment
        case keychain
        case none

        public var label: String {
            switch self {
            case .environment: "From the launch environment (\(ServerConfig.tokenEnvironmentKey))"
            case .keychain: "Saved in the Keychain"
            case .none: "Not set"
            }
        }
    }

    public struct Resolved: Equatable, Sendable {
        public let url: URL
        public let source: Source

        public init(url: URL, source: Source) {
            self.url = url
            self.source = source
        }
    }

    public struct ResolvedToken: Equatable, Sendable {
        public let token: String?
        public let source: TokenSource

        public init(token: String?, source: TokenSource) {
            self.token = token
            self.source = source
        }
    }

    /// Applies the address rule. Pure, so it is testable: pass what the process sees.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: String? = UserDefaults.standard.string(forKey: settingsKey),
        defaultURL: URL = ServerConfig.defaultURL
    ) -> Resolved {
        if let raw = environment[environmentKey], let url = normalize(raw) {
            return Resolved(url: url, source: .environment)
        }
        if let raw = settings, let url = normalize(raw) {
            return Resolved(url: url, source: .settings)
        }
        return Resolved(url: defaultURL, source: .defaultValue)
    }

    /// Applies the token rule. The store is read only when the environment sets no token, so a
    /// development run never touches the Keychain.
    public static func resolveToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: any TokenStore
    ) -> ResolvedToken {
        if let raw = environment[tokenEnvironmentKey] {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return ResolvedToken(token: token, source: .environment) }
        }
        if let token = (try? store.read())?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return ResolvedToken(token: token, source: .keychain)
        }
        return ResolvedToken(token: nil, source: .none)
    }

    public enum AccessSource: String, Sendable {
        case environment
        case saved
        case none

        public var label: String {
            switch self {
            case .environment: "From the launch environment"
            case .saved: "Saved (secret in the Keychain)"
            case .none: "Not used"
            }
        }
    }

    /// Applies the Access rule. Both environment variables must be set to win; the secret store
    /// is read only when a client id is saved.
    public static func resolveAccess(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        savedID: String? = UserDefaults.standard.string(forKey: accessIDKey),
        secretStore: any TokenStore
    ) -> (token: AccessServiceToken?, source: AccessSource) {
        if let token = AccessServiceToken(clientID: environment[accessIDEnvironmentKey],
                                          clientSecret: environment[accessSecretEnvironmentKey]) {
            return (token, .environment)
        }
        guard let savedID, !savedID.trimmingCharacters(in: .whitespaces).isEmpty,
              let token = AccessServiceToken(clientID: savedID, clientSecret: try? secretStore.read())
        else { return (nil, .none) }
        return (token, .saved)
    }

    /// Trims, drops a trailing slash and checks for http(s) with a host. Nil when unusable.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// True for plain `http://` to a host other than this Mac: the token would travel
    /// unencrypted. Settings warns about it.
    public static func isInsecureRemote(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return !isLoopback(url.host() ?? "")
    }

    public static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    /// Saves (or with nil/blank, clears) the Settings address.
    public static func saveSettingsURL(_ raw: String?, defaults: UserDefaults = .standard) {
        if let raw, let url = normalize(raw) {
            defaults.set(url.absoluteString, forKey: settingsKey)
        } else {
            defaults.removeObject(forKey: settingsKey)
        }
    }

    /// A page of the web app on the same server, for "Open in web".
    ///
    ///     ServerConfig.webURL(path: "/jobs/applications/3", base: server)
    public static func webURL(path: String, base: URL) -> URL {
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        let tail = path.hasPrefix("/") ? path : "/" + path
        return URL(string: root + tail) ?? base
    }
}
