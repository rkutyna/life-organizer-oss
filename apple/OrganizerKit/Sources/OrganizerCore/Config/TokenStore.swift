import Foundation
import Security

/// Where the app keeps its API token: the Keychain in the app, memory in tests and previews.
public protocol TokenStore: Sendable {
    /// The saved token, or nil when there is none.
    func read() throws -> String?
    /// Saves the token, replacing any saved one.
    func save(_ token: String) throws
    /// Forgets the token. No error when there is none.
    func delete() throws
}

public struct TokenStoreError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(message)"
    }
}

/// A generic password in the login Keychain.
///
/// The service is the app's own (`KeychainTokenStore.appService`, from the bundle id), never
/// shared with another app; the account names what the token is for. The item is the classic
/// file-based kind, which works without a team or an entitlement, so a build signed "to run
/// locally" can use it. macOS ties access to the app's signature: after an ad-hoc rebuild it may
/// ask once to allow access. The token is never logged.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    public let label: String

    public init(service: String = KeychainTokenStore.appService, account: String, label: String) {
        self.service = service
        self.account = account
        self.label = label
    }

    /// The app's API token (`api` and `mail` scopes).
    public static var api: KeychainTokenStore {
        KeychainTokenStore(account: "api-token", label: "Life Organizer API token")
    }

    /// The in-app Mac helper's token (`ingest` scope only).
    public static var helper: KeychainTokenStore {
        KeychainTokenStore(account: "helper-ingest-token", label: "Life Organizer in-app helper token")
    }

    /// The Cloudflare Access service token's secret (its client id is in the app's defaults).
    public static var accessSecret: KeychainTokenStore {
        KeychainTokenStore(account: "cf-access-client-secret", label: "Life Organizer Cloudflare Access secret")
    }

    /// The Keychain service: the app's bundle id.
    public static var appService: String {
        Bundle.main.bundleIdentifier ?? "com.lifeorganizerformac.app"
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStoreError(status: status, operation: "read") }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw TokenStoreError(status: update, operation: "update") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrDescription as String] = "API token"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw TokenStoreError(status: status, operation: "add") }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError(status: status, operation: "delete")
        }
    }
}

/// A token kept in memory: tests, previews and development runs.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(_ token: String? = nil) {
        self.token = token
    }

    public func read() throws -> String? { lock.withLock { token } }

    public func save(_ token: String) throws { lock.withLock { self.token = token } }

    public func delete() throws { lock.withLock { token = nil } }
}
