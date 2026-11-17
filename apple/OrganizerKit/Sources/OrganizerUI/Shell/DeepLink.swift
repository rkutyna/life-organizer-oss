import Foundation

/// A link into the app: `lifeorganizer://<module>/<path…>?<query>`, the same shape as the web
/// app's paths (`/jobs/applications/12` on the web is `lifeorganizer://jobs/applications/12`).
///
/// The shell selects the module and puts the link in `AppEnvironment.deepLink`; the module's
/// screen reads the `path` and `query` it understands and calls `app.consume(link)`.
///
///     lifeorganizer://reminders?reminder=5        open reminder 5
///     lifeorganizer://jobs/applications/12        application 12
///     lifeorganizer://mail?message=7              message 7
///     lifeorganizer://settings
///
/// Try one with `open "lifeorganizer://jobs"`.
nonisolated public struct DeepLink: Equatable, Sendable {
    public static let scheme = "lifeorganizer"

    public let id = UUID()
    public let module: ModuleID
    /// The path after the module, one element per segment, decoded:
    /// `lifeorganizer://jobs/applications/12` has `["applications", "12"]`. Empty for
    /// `lifeorganizer://jobs`.
    public let path: [String]
    public let query: [String: String]

    public init(module: ModuleID, path: [String] = [], query: [String: String] = [:]) {
        self.module = module
        self.path = path
        self.query = query
    }

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host()?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let module = ModuleID(rawValue: host) else { return nil }
        self.init(module: module, path: path, query: query)
    }

    /// The link as a URL, the form `init?(_ url:)` reads back.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = module.rawValue
        if !path.isEmpty {
            var segment = CharacterSet.urlPathAllowed
            segment.remove("/")
            components.percentEncodedPath = "/" + path
                .map { $0.addingPercentEncoding(withAllowedCharacters: segment) ?? $0 }
                .joined(separator: "/")
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    public static func == (lhs: DeepLink, rhs: DeepLink) -> Bool { lhs.id == rhs.id }
}
