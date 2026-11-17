import Foundation
import OrganizerAPI
import Synchronization

/// A fake API server for tests: canned responses per method and path, and a record of every
/// request (so a test can check the `Authorization` header and bodies). No network, no real
/// server.
///
///     let server = StubServer()
///     server.respond(.get, "/api/reminders", json: #"[]"#)
///     server.respond(.post, "/api/reminders/3/complete", status: 409, json: #"{"detail": "no"}"#)
///     let client = server.client()                       // an OrganizerClient pointed at it
///     ...
///     #expect(server.requests.last?.header("Authorization") == "Bearer test-token")
///
/// Each server has its own host, so tests using different servers can run in parallel.
public final class StubServer: Sendable {
    public struct Recorded: Sendable {
        public let method: String
        public let path: String
        public let query: String?
        public let headers: [String: String]
        public let body: Data?

        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The body as JSON, for asserting what was sent.
        public var json: JSONValue? {
            body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }
    }

    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    private struct State {
        var routes: [String: Response] = [:]
        var requests: [Recorded] = []
    }

    public let host: String
    private let state = Mutex(State())

    /// Registers the server for the test process's lifetime (servers are small; never reused).
    public init() {
        host = "stub-\(UUID().uuidString.lowercased()).test"
        StubRegistry.servers.withLock { $0[host] = self }
    }

    public var baseURL: URL { URL(string: "http://\(host)")! }

    /// A URLSession that sends every request to stub servers.
    public func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The token `client()` sends unless told otherwise.
    public static let token = "test-token"

    /// An `OrganizerClient` pointed at this server, with an optional cache.
    public func client(cache: ResponseCache? = nil, token: String? = StubServer.token) -> OrganizerClient {
        OrganizerClient(baseURL: baseURL, token: token, cache: cache, session: session())
    }

    /// Answers `method path` with `json` and `status`. `path` may carry a query
    /// ("/api/reminders?include_completed=false", in the order the client sends it) to answer only that
    /// query; without one it answers any query. A later call for the same route replaces it.
    public func respond(_ method: HTTPMethod, _ path: String, status: Int = 200, json: String) {
        route(method, path, Response(status: status, body: Data(json.utf8)))
    }

    /// Answers with an encoded value (the API's JSON coding).
    public func respond(_ method: HTTPMethod, _ path: String, status: Int = 200, value: some Encodable) {
        route(method, path, Response(status: status, body: (try? APIJSON.encoder().encode(value)) ?? Data()))
    }

    /// Answers with a fixture file's contents.
    public func respond(_ method: HTTPMethod, _ path: String, status: Int = 200, file: URL) {
        route(method, path, Response(status: status, body: (try? Data(contentsOf: file)) ?? Data()))
    }

    private func route(_ method: HTTPMethod, _ path: String, _ response: Response) {
        state.withLock { $0.routes["\(method.rawValue) \(path)"] = response }
    }

    /// Every request received, oldest first.
    public var requests: [Recorded] { state.withLock { $0.requests } }

    /// The requests for one method and path.
    public func requests(_ method: HTTPMethod, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method.rawValue && $0.path == path }
    }

    func handle(_ request: URLRequest) -> Response {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? url.path
        let method = request.httpMethod ?? "GET"
        let recorded = Recorded(
            method: method, path: path, query: components?.percentEncodedQuery,
            headers: request.allHTTPHeaderFields ?? [:], body: StubURLProtocol.body(of: request))
        return state.withLock { state in
            state.requests.append(recorded)
            let query = recorded.query.map { "?\($0)" } ?? ""
            return state.routes["\(method) \(path)\(query)"] ?? state.routes["\(method) \(path)"]
                ?? Response(status: 404, body: Data(#"{"detail": "no stub for \#(method) \#(path)"}"#.utf8))
        }
    }
}

enum StubRegistry {
    static let servers = Mutex<[String: StubServer]>([:])
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return StubRegistry.servers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host(),
              let server = StubRegistry.servers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = server.handle(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves a request's body into a stream before a protocol sees it.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fresh, empty cache folder for one test.
public func temporaryCache() -> ResponseCache {
    ResponseCache(directory: FileManager.default.temporaryDirectory
        .appending(path: "organizer-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
}
