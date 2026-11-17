import Foundation
import Observation
import OrganizerAPI
import OrganizerCore

/// The app's shared state: which server, which token, the API client, and one store per module.
///
/// Injected at the root (`.environment(app)`); a screen reads it and asks for its store:
///
///     struct RemindersScreen: View {
///         @Environment(AppEnvironment.self) private var app
///         var body: some View { RemindersView(store: app.store { RemindersStore(client: $0) }) }
///     }
///
/// A store is created on first use and kept while the app runs, so switching modules keeps its
/// data. Changing the server address or the token (Settings) builds a new client and drops
/// every store.
@MainActor
@Observable
public final class AppEnvironment {
    public private(set) var server: ServerConfig.Resolved
    public private(set) var tokenSource: ServerConfig.TokenSource
    public private(set) var accessSource: ServerConfig.AccessSource
    public private(set) var client: OrganizerClient
    public let cache: ResponseCache
    /// Where Settings saves the token (the Keychain in the app).
    @ObservationIgnored public let tokenStore: any TokenStore
    /// Where Settings saves the Cloudflare Access secret (the Keychain in the app).
    @ObservationIgnored public let accessSecretStore: any TokenStore

    /// The link the app was last opened with, until the module it names handles it
    /// (`consume`). See `DeepLink`.
    public var deepLink: DeepLink?

    /// Bumped on every reload, so the root view rebuilds its screens.
    public private(set) var generation = 0

    @ObservationIgnored private let session: URLSession?
    @ObservationIgnored private let transport: (any OrganizerTransport)?
    @ObservationIgnored private let resolveServer: () -> ServerConfig.Resolved
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let accessIDDefaults: UserDefaults
    @ObservationIgnored private var stores: [ObjectIdentifier: AnyObject] = [:]

    /// - Parameters:
    ///   - resolveServer: the base-URL rule; the default reads the environment and Settings.
    ///   - tokenStore: where the token is saved; the default is the Keychain.
    ///   - accessSecretStore: where the Cloudflare Access secret is saved (Keychain by default).
    ///   - accessIDDefaults: where the Access client id is saved.
    ///   - environment: the launch environment (`ORGANIZER_TOKEN` and the
    ///     `ORGANIZER_CF_ACCESS_*` pair override what is saved).
    ///   - cache: where last good responses live.
    ///   - session / transport: for tests.
    public init(
        resolveServer: @escaping () -> ServerConfig.Resolved = { ServerConfig.resolve() },
        tokenStore: any TokenStore = KeychainTokenStore.api,
        accessSecretStore: any TokenStore = KeychainTokenStore.accessSecret,
        accessIDDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cache: ResponseCache = ResponseCache(directory: AppPaths.cacheDirectory),
        session: URLSession? = nil,
        transport: (any OrganizerTransport)? = nil
    ) {
        let server = resolveServer()
        let token = ServerConfig.resolveToken(environment: environment, store: tokenStore)
        let access = ServerConfig.resolveAccess(environment: environment,
                                                savedID: accessIDDefaults.string(forKey: ServerConfig.accessIDKey),
                                                secretStore: accessSecretStore)
        self.resolveServer = resolveServer
        self.tokenStore = tokenStore
        self.accessSecretStore = accessSecretStore
        self.accessIDDefaults = accessIDDefaults
        self.accessSource = access.source
        self.environment = environment
        self.server = server
        self.tokenSource = token.source
        self.cache = cache
        self.session = session
        self.transport = transport
        self.client = OrganizerClient(baseURL: server.url, token: token.token, access: access.token,
                                      cache: cache, session: session, transport: transport)
    }

    /// True when no token is set: the app shows the first-launch sheet.
    public var needsSetup: Bool { tokenSource == .none }

    /// The module's store, created with `make` the first time.
    public func store<Store: AnyObject>(_ make: (OrganizerClient) -> Store) -> Store {
        let key = ObjectIdentifier(Store.self)
        if let existing = stores[key] as? Store { return existing }
        let created = make(client)
        stores[key] = created
        return created
    }

    /// The pending link for `module`, if any. A screen reads it, acts, then calls `consume`.
    public func deepLink(for module: ModuleID) -> DeepLink? {
        deepLink?.module == module ? deepLink : nil
    }

    /// Marks a link handled.
    public func consume(_ link: DeepLink) {
        if deepLink == link { deepLink = nil }
    }

    /// Re-reads the address rule and the token (after Settings saved either). The client and
    /// every store are rebuilt; the root view's `.id(generation)` resets the screens.
    public func reloadServer() {
        let next = resolveServer()
        let token = ServerConfig.resolveToken(environment: environment, store: tokenStore)
        let access = currentAccess()
        server = next
        tokenSource = token.source
        accessSource = access.source
        client = OrganizerClient(baseURL: next.url, token: token.token, access: access.token,
                                 cache: cache, session: session, transport: transport)
        stores = [:]
        generation += 1
    }

    /// A client for an address and token typed in Settings but not saved yet (Test Connection).
    /// It keeps no cache.
    public func testClient(baseURL: URL, token: String?, access: AccessServiceToken? = nil) -> OrganizerClient {
        OrganizerClient(baseURL: baseURL, token: token, access: access ?? currentAccess().token,
                        cache: nil, session: session, transport: transport)
    }

    /// The Cloudflare Access service token in use, if any, and where it came from.
    public func currentAccess() -> (token: AccessServiceToken?, source: ServerConfig.AccessSource) {
        ServerConfig.resolveAccess(environment: environment,
                                   savedID: accessIDDefaults.string(forKey: ServerConfig.accessIDKey),
                                   secretStore: accessSecretStore)
    }

    /// The saved Access client id (not secret), for Settings.
    public var savedAccessClientID: String {
        accessIDDefaults.string(forKey: ServerConfig.accessIDKey) ?? ""
    }

    /// Saves (both non-blank) or clears (both blank) the Access service token, then reloads.
    public func saveAccess(clientID: String, clientSecret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            try accessSecretStore.delete()
            accessIDDefaults.removeObject(forKey: ServerConfig.accessIDKey)
        } else {
            if !secret.isEmpty { try accessSecretStore.save(secret) }
            accessIDDefaults.set(id, forKey: ServerConfig.accessIDKey)
        }
        reloadServer()
    }

    /// The token in use, for Test Connection when the token field is left blank.
    public func currentToken() -> String? {
        ServerConfig.resolveToken(environment: environment, store: tokenStore).token
    }

    /// A page of the web app on the server in use.
    public func webURL(_ path: String) -> URL {
        ServerConfig.webURL(path: path, base: server.url)
    }

    /// An environment for SwiftUI previews: a server that does not exist and an empty cache.
    public static func preview() -> AppEnvironment {
        AppEnvironment(
            resolveServer: { .init(url: URL(string: "http://preview.invalid")!, source: .defaultValue) },
            tokenStore: MemoryTokenStore("preview"),
            accessSecretStore: MemoryTokenStore(),
            accessIDDefaults: UserDefaults(suiteName: "organizer-preview") ?? .standard,
            environment: [:],
            cache: ResponseCache(directory: FileManager.default.temporaryDirectory.appending(path: "organizer-preview"))
        )
    }
}
