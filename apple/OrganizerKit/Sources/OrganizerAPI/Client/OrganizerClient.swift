import Foundation
import os

/// A decoded response and when it was fetched. `isCached` is true when it came from the
/// on-disk cache rather than the network just now.
public struct Fetched<Value: Sendable>: Sendable {
    public let value: Value
    public let fetchedAt: Date
    public let isCached: Bool

    public init(value: Value, fetchedAt: Date, isCached: Bool) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.isCached = isCached
    }
}

/// How a request reaches the server: a `URLSession`, or a stub in tests.
public protocol OrganizerTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OrganizerTransport {
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// A Cloudflare Access service token: sent as `CF-Access-Client-Id` and
/// `CF-Access-Client-Secret` on every request, so a server behind Cloudflare Access with a
/// "Service Auth" policy lets the app through. Optional; the secret is never logged.
public struct AccessServiceToken: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String

    /// Nil unless both parts are non-blank.
    public init?(clientID: String?, clientSecret: String?) {
        let id = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        self.clientID = id
        self.clientSecret = secret
    }
}

/// The organizer's REST API.
///
///     let client = OrganizerClient(baseURL: url, token: token, cache: cache)
///     let lists = try await client.send(API.Reminders.reminderLists())
///     try await client.reminders.complete(id: 3)            // module facades, Modules/*.swift
///
/// - Every request carries `Authorization: Bearer <token>`. The server fixes a token's author
///   and scopes when it is made (Settings → API tokens in the web app), so writes from the app
///   are recorded under that author, and mail needs a token with the `mail` scope.
/// - With an `AccessServiceToken`, every request also carries the two Cloudflare Access headers.
/// - The token and the Access secret are never logged.
/// - A successful GET is saved in `cache` as the last good copy; `cached(_:)` reads it back.
///   Mail is never saved (`Endpoint.isCacheable`).
/// - An error status throws `APIError.server` with the server's own message (401, 403, 409, 422).
public final class OrganizerClient: Sendable {
    public let baseURL: URL
    public let cache: ResponseCache?
    private let token: String?
    private let access: AccessServiceToken?
    private let transport: any OrganizerTransport
    private static let log = Logger(subsystem: "com.lifeorganizerformac.app", category: "api")

    /// - Parameters:
    ///   - token: the API token, sent as `Authorization: Bearer`. Nil sends no credential (the
    ///     server answers 401).
    ///   - transport: how requests reach the server, when it is not `session` (tests).
    ///   - access: a Cloudflare Access service token, when the server is behind Access.
    public init(baseURL: URL, token: String? = nil, access: AccessServiceToken? = nil,
                cache: ResponseCache? = nil, session: URLSession? = nil,
                transport: (any OrganizerTransport)? = nil) {
        self.baseURL = baseURL
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.access = access
        self.cache = cache
        self.transport = transport ?? session ?? Self.makeSession()
    }

    /// True when a token is set.
    public var hasToken: Bool { token != nil }

    /// True when a Cloudflare Access service token is sent.
    public var usesAccessServiceToken: Bool { access != nil }

    /// Runs `endpoint` and returns its decoded response.
    public func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        try await fetch(endpoint).value
    }

    /// Runs `endpoint`; for a GET also saves the response as the last good copy.
    public func fetch<Response>(_ endpoint: Endpoint<Response>) async throws -> Fetched<Response> {
        let request = try makeRequest(endpoint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            Self.log.info("\(endpoint.method.rawValue) \(endpoint.path) failed: \(error.localizedDescription)")
            throw APIError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Self.log.debug("\(endpoint.method.rawValue) \(endpoint.path) -> \(status)")
        guard (200..<300).contains(status) else {
            throw APIError.fromResponse(status: status, body: data)
        }
        let value = try Self.decode(Response.self, from: data)
        let now = Date()
        if endpoint.isCacheable {
            cache?.write(key: cacheKey(endpoint), body: data, fetchedAt: now)
        }
        return Fetched(value: value, fetchedAt: now, isCached: false)
    }

    /// The last good copy of a GET, if one was saved (from any earlier launch).
    public func cached<Response>(_ endpoint: Endpoint<Response>) -> Fetched<Response>? {
        guard endpoint.isCacheable, let entry = cache?.read(key: cacheKey(endpoint)),
              let value = try? Self.decode(Response.self, from: entry.body)
        else { return nil }
        return Fetched(value: value, fetchedAt: entry.fetchedAt, isCached: true)
    }

    /// The cache key: the base URL is part of it, so switching servers never shows another
    /// server's data.
    public func cacheKey<Response>(_ endpoint: Endpoint<Response>) -> String {
        "\(baseURL.absoluteString) \(endpoint.cacheKey)"
    }

    public func makeRequest<Response>(_ endpoint: Endpoint<Response>) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(baseURL.absoluteString)
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + endpoint.path
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let url = components.url else {
            throw APIError.invalidURL(baseURL.absoluteString + endpoint.path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let access {
            request.setValue(access.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(access.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        for (name, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = endpoint.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try APIJSON.encoder().encode(body)
            } catch {
                throw APIError.decoding(message: "Could not encode the request: \(error)")
            }
        }
        return request
    }

    static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        if Response.self == NoContent.self, let empty = NoContent() as? Response {
            return empty
        }
        do {
            return try APIJSON.decoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(message: Self.describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "Missing \(path(context)).\(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
