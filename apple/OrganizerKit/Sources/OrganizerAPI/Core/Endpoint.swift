import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// One API request, built by a generated `API.<Module>.<operation>(...)` function and run by
/// `OrganizerClient.send`. `Response` is what the call decodes to.
///
///     let endpoint = API.Reminders.reminderLists()   // Endpoint<[ReminderListOut]>
///     let lists = try await client.send(endpoint)
public struct Endpoint<Response: Decodable & Sendable>: Sendable {
    public let method: HTTPMethod
    /// The path with parameters filled in, e.g. `/api/reminders/3`.
    public let path: String
    public let query: [URLQueryItem]
    public let headers: [String: String]
    public let body: (any Encodable & Sendable)?

    public init(
        method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Reads are cached as "the last good copy"; writes never are.
    public var isRead: Bool { method == .get }

    /// Whether a successful response is saved in the on-disk cache: reads, except mail. Mail is
    /// fetched live and never stored on the Mac, as the server never stores message bodies.
    public var isCacheable: Bool { isRead && !path.hasPrefix("/api/mail/") }

    /// Identifies this request in the response cache: method, path and sorted query.
    public var cacheKey: String {
        let items = query
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        return items.isEmpty ? "\(method.rawValue) \(path)" : "\(method.rawValue) \(path)?\(items)"
    }
}

/// The response of a call that returns nothing (204).
public struct NoContent: Codable, Hashable, Sendable {
    public init() {}
}

/// A value that can be sent as a query or path parameter.
public protocol QueryValue: Sendable {
    var queryValue: String { get }
}

extension String: QueryValue { public var queryValue: String { self } }
extension Int: QueryValue { public var queryValue: String { String(self) } }
extension Double: QueryValue { public var queryValue: String { String(self) } }
extension Bool: QueryValue { public var queryValue: String { self ? "true" : "false" } }
extension LocalDate: QueryValue { public var queryValue: String { string } }
extension LocalTime: QueryValue { public var queryValue: String { string } }
extension Date: QueryValue { public var queryValue: String { APIJSON.formatDateTime(self) } }

/// Zero or more query values: a single value, an Optional (nil sends nothing) or an array
/// (repeated, `?tag=a&tag=b`).
public protocol QueryParameter: Sendable {
    var queryValues: [String] { get }
}

extension Optional: QueryParameter where Wrapped: QueryParameter {
    public var queryValues: [String] { self?.queryValues ?? [] }
}

extension Array: QueryParameter where Element: QueryValue {
    public var queryValues: [String] { map(\.queryValue) }
}

extension String: QueryParameter { public var queryValues: [String] { [self] } }
extension Int: QueryParameter { public var queryValues: [String] { [queryValue] } }
extension Double: QueryParameter { public var queryValues: [String] { [queryValue] } }
extension Bool: QueryParameter { public var queryValues: [String] { [queryValue] } }
extension LocalDate: QueryParameter { public var queryValues: [String] { [queryValue] } }
extension LocalTime: QueryParameter { public var queryValues: [String] { [queryValue] } }
extension Date: QueryParameter { public var queryValues: [String] { [queryValue] } }

extension OpenEnum {
    public var queryValues: [String] { [rawValue] }
}

/// Helpers the generated operations use to build an `Endpoint`.
public enum Wire {
    /// A path parameter, percent-encoded so a value with "/" or spaces stays one segment.
    public static func segment(_ value: some QueryValue) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.queryValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? value.queryValue
    }

    /// Query items in the order given, skipping nil values and repeating arrays.
    public static func query(_ parameters: [(String, any QueryParameter)]) -> [URLQueryItem] {
        parameters.flatMap { name, value in
            value.queryValues.map { URLQueryItem(name: name, value: $0) }
        }
    }

    /// Headers, skipping nil values.
    public static func headers(_ values: [(String, String?)]) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in values {
            if let value { headers[name] = value }
        }
        return headers
    }
}

