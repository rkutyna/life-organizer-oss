import Foundation

public enum PushError: Error, CustomStringConvertible {
    case noServer
    case noToken
    case http(Int, String)
    case transport(String)

    public var description: String {
        switch self {
        case .noServer: return "server.url is not configured, not an http(s) URL, or plain http to another host (run organizer-helper doctor)"
        case .noToken: return "no ingest token: set server.token in the config, or run `organizer-helper set-token`"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .transport(let s): return s
        }
    }

    var retryable: Bool {
        switch self {
        case .noServer, .noToken: return false
        case .http(let code, _): return code == 408 || code == 429 || code >= 500
        case .transport: return true
        }
    }
}

/// Sends one HTTP request. `URLSessionTransport` is the real one; tests inject a fake, so no
/// test ever opens a socket.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 4
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "organizer-helper/\(HelperVersion.string)"]
        session = URLSession(configuration: cfg)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PushError.transport("not an HTTP response") }
        return (data, http)
    }
}

/// HTTP client for the organizer's ingest API. Every request carries
/// `Authorization: Bearer <ingest token>`; the token is never logged.
public final class ServerClient: RemindersServer, @unchecked Sendable {
    public let baseURL: URL?
    private let tokens: TokenProvider
    private let transport: HTTPTransport
    private let delays: [TimeInterval]

    public static let standardRetryDelays: [TimeInterval] = [2, 8, 30]

    public init(baseURL: URL?, tokens: TokenProvider, transport: HTTPTransport,
                retryDelays: [TimeInterval] = ServerClient.standardRetryDelays) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.transport = transport
        delays = retryDelays
    }

    /// POSTs one snapshot to its stream's endpoint.
    public func deliver(_ payload: EncodedPayload) async throws {
        _ = try await request(method: "POST", path: payload.stream.path, body: payload.json, label: payload.key)
    }

    // MARK: RemindersServer

    public func fetchReminderOps() async throws -> [ReminderOp]? {
        let (code, data) = try await request(method: "GET", path: "/api/ingest/reminders/ops", body: nil,
                                             label: "GET reminder ops", throwOnHTTPError: false, retry: false)
        if code == 404 { return nil }
        guard (200..<300).contains(code) else { throw PushError.http(code, String(decoding: data, as: UTF8.self)) }
        return try JSONCoding.decoder().decode(ReminderOpsResponse.self, from: data).instancedOps
    }

    public func ackReminderOp(_ id: Int, _ ack: OpAck) async throws -> Bool {
        let body = try JSONCoding.encoder().encode(ack)
        let (code, data) = try await request(method: "POST", path: "/api/ingest/reminders/ops/\(id)/ack", body: body,
                                             label: "ack op \(id)", throwOnHTTPError: false)
        // 404: withdrawn. 409: the op came from another server instance (the database was
        // recreated). Either way there is nothing to record; the next snapshot shows the result.
        if code == 404 || code == 409 { return false }
        guard (200..<300).contains(code) else { throw PushError.http(code, String(decoding: data, as: UTF8.self)) }
        return true
    }

    // MARK: requests

    /// Sends a request and returns (status, body). With `throwOnHTTPError` false, a non-2xx answer
    /// is returned rather than thrown (after any retries), so callers can treat 404 as an answer.
    /// A 401/403 drops the cached token, so the next request reads it again.
    @discardableResult
    public func request(method: String, path: String, body: Data?, label: String,
                        throwOnHTTPError: Bool = true, retry: Bool = true) async throws -> (Int, Data) {
        guard let baseURL else { throw PushError.noServer }
        guard let token = tokens.token(), !token.isEmpty else { throw PushError.noToken }
        let url = baseURL.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport.send(req)
                let code = response.statusCode
                if (200..<300).contains(code) {
                    log.debug("\(label): HTTP \(code) (\(body?.count ?? 0) bytes sent)")
                    return (code, data)
                }
                if code == 401 || code == 403 { tokens.invalidate() }
                let err = PushError.http(code, String(decoding: data, as: UTF8.self))
                if !retry || !err.retryable || attempt >= delays.count {
                    if !throwOnHTTPError { return (code, data) }
                    throw err
                }
                let wait = retryAfter(response) ?? delays[attempt]
                log.warn("\(label): \(err); retry \(attempt + 1)/\(delays.count) in \(Int(wait))s")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch let e as PushError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A cancelled task (the helper stopping) surfaces as URLError.cancelled: never retry it.
                if Task.isCancelled { throw CancellationError() }
                let err = PushError.transport(error.localizedDescription)
                if !retry || attempt >= delays.count { throw err }
                let wait = delays[attempt]
                log.warn("\(label): \(err); retry \(attempt + 1)/\(delays.count) in \(Int(wait))s")
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            attempt += 1
        }
    }

    private func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let h = response.value(forHTTPHeaderField: "Retry-After"), let s = Double(h) else { return nil }
        return min(max(s, 1), 300)
    }
}

/// Change detection: push when the body hash differs from the last *successful* push, or when
/// the heartbeat interval has passed. A failed push leaves the old hash in place, so the next
/// poll retries even if nothing changed.
public final class StreamGate: @unchecked Sendable {
    private var lastHash: [String: String] = [:]
    private var lastPush: [String: Date] = [:]
    private let lock = NSLock()
    public let heartbeat: TimeInterval

    public init(heartbeat: TimeInterval) { self.heartbeat = heartbeat }

    public func shouldPush(_ stream: IngestStream, hash: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let prev = lastHash[stream.rawValue], let at = lastPush[stream.rawValue] else { return true }
        if prev != hash { return true }
        return heartbeat > 0 && now.timeIntervalSince(at) >= heartbeat
    }

    public func markPushed(_ stream: IngestStream, hash: String, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastHash[stream.rawValue] = hash
        lastPush[stream.rawValue] = at
    }
}
