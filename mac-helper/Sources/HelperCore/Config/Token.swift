import Foundation
import Security

/// A generic-password store, behind a protocol so tests never touch the real Keychain.
public protocol KeychainStore: Sendable {
    /// The stored value, or nil when there is no such item.
    func read(service: String, account: String) throws -> String?
    /// Adds the item, or replaces its value when it exists.
    func write(_ value: String, service: String, account: String) throws
}

public struct KeychainError: Error, CustomStringConvertible, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) { self.status = status; self.operation = operation }

    public var description: String {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(message)"
    }
}

/// The login Keychain, through the Security framework. The item is created by `set-token`
/// (run by this binary), so the daemon (the same binary) can read it without a prompt. A binary
/// with a different signature, such as an ad-hoc rebuild, gets a one-time "allow" prompt.
public struct SystemKeychain: KeychainStore {
    public init() {}

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "read") }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update, operation: "update") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Life Organizer Helper ingest token"
        add[kSecAttrDescription as String] = "API token"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "add") }
    }
}

/// Where the ingest token came from. `doctor` prints this, never the token.
public enum TokenSource: Equatable, Sendable, CustomStringConvertible {
    case config
    case keychain(service: String, account: String)
    case missing(service: String, account: String)
    case keychainError(String)

    public var description: String {
        switch self {
        case .config: return "config file (server.token)"
        case .keychain(let s, let a): return "Keychain (service \(s), account \(a))"
        case .missing(let s, let a): return "not set: server.token is null and the Keychain has no item (service \(s), account \(a)); run organizer-helper set-token"
        case .keychainError(let why): return "not readable: \(why)"
        }
    }
}

public struct ResolvedToken: Sendable {
    public var token: String?
    public var source: TokenSource
}

/// The token from the config's `server.token`, else from the Keychain.
public enum TokenResolver {
    public static func resolve(config: HelperConfig, keychain: KeychainStore) -> ResolvedToken {
        if let t = config.server.token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return ResolvedToken(token: t, source: .config)
        }
        let service = config.keychainService, account = config.keychainAccount
        do {
            if let t = try keychain.read(service: service, account: account)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return ResolvedToken(token: t, source: .keychain(service: service, account: account))
            }
            return ResolvedToken(token: nil, source: .missing(service: service, account: account))
        } catch {
            return ResolvedToken(token: nil, source: .keychainError("\(error)"))
        }
    }
}

/// The token for requests: resolved on first use and cached; dropped when the server rejects it
/// (401/403), so a token stored with `set-token` while the daemon runs is picked up.
public final class TokenProvider: @unchecked Sendable {
    private let resolveNow: @Sendable () -> ResolvedToken
    private let lock = NSLock()
    private var cached: String?

    public init(resolve: @escaping @Sendable () -> ResolvedToken) { resolveNow = resolve }

    public convenience init(config: HelperConfig, keychain: KeychainStore) {
        self.init { TokenResolver.resolve(config: config, keychain: keychain) }
    }

    /// A fixed token (tests).
    public convenience init(fixed: String?) {
        self.init { ResolvedToken(token: fixed, source: .config) }
    }

    public func token() -> String? {
        if let t = lock.withLock({ cached }) { return t }
        let t = resolveNow().token
        lock.withLock { cached = t }
        return t
    }

    public func invalidate() { lock.withLock { cached = nil } }
}
