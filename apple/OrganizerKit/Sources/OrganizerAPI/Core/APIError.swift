import Foundation

/// Why a request failed, with a message fit to show the user.
///
/// The server explains its refusals: a 409 says why (a change was already applied in Apple
/// Reminders, a status that disagrees with the history) and a 422 names the field. A 401 means
/// the token is wrong or revoked, a 403 that it lacks a scope. `message` carries
/// that text, so screens show it as it is (`.errorAlert`, `ErrorStateView`).
public enum APIError: Error, Hashable, Sendable, LocalizedError {
    /// The server answered with an error status. `message` is FastAPI's `detail`.
    case server(status: Int, message: String)
    /// No usable answer: offline, timed out, TLS, DNS, the server is down.
    case transport(message: String)
    /// The answer did not match the generated types (the server and app disagree).
    case decoding(message: String)
    /// The base URL or path could not form a URL.
    case invalidURL(String)

    public var status: Int? {
        if case .server(let status, _) = self { return status }
        return nil
    }

    /// 409: the server refused because of the record's state (mirrored field, already applied).
    public var isConflict: Bool { status == 409 }

    /// 401: the token is missing, mistyped or revoked.
    public var isUnauthorized: Bool { status == 401 }

    /// 403: the token is valid but lacks the scope (`api`, or `mail` for mail).
    public var isForbidden: Bool { status == 403 }

    /// 404: the record is gone (deleted elsewhere).
    public var isNotFound: Bool { status == 404 }

    /// True when the server could not be reached at all (show cached data and an "as of" badge).
    public var isOffline: Bool {
        if case .transport = self { return true }
        return false
    }

    /// The text to show the user.
    public var message: String {
        switch self {
        case .server(_, let message): message
        case .transport(let message): message
        case .decoding(let message): "The server sent something this app does not understand. \(message)"
        case .invalidURL(let url): "Not a valid server address: \(url)"
        }
    }

    public var errorDescription: String? { message }

    /// Any error as an APIError (a thrown non-API error becomes `.transport`).
    public init(_ error: any Error) {
        if let error = error as? APIError {
            self = error
        } else if let error = error as? URLError {
            self = .transport(message: Self.describe(error))
        } else if error is DecodingError {
            self = .decoding(message: String(describing: error))
        } else {
            self = .transport(message: error.localizedDescription)
        }
    }

    /// FastAPI errors are `{"detail": "text"}` or `{"detail": [{"loc": [...], "msg": "..."}]}`.
    public static func fromResponse(status: Int, body: Data) -> APIError {
        let fallback = "\(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body), let detail = json["detail"]
        else { return .server(status: status, message: fallback) }
        if let text = detail.stringValue {
            return .server(status: status, message: text)
        }
        if let items = detail.arrayValue {
            let parts = items.map { item -> String in
                let message = item["msg"]?.stringValue ?? "invalid"
                let field = (item["loc"]?.arrayValue ?? [])
                    .compactMap { $0.stringValue ?? $0.intValue.map(String.init) }
                    .filter { $0 != "body" }
                    .joined(separator: ".")
                return field.isEmpty ? message : "\(field): \(message)"
            }
            return .server(status: status, message: parts.joined(separator: "; "))
        }
        return .server(status: status, message: fallback)
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            "You're offline."
        case .timedOut:
            "The server took too long to answer."
        case .cannotFindHost, .dnsLookupFailed:
            "Can't find the server. Check the address (and your VPN, if you use one)."
        case .cannotConnectToHost:
            "Can't reach the server. Is it running, and is the address right?"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "The server's certificate was refused."
        case .appTransportSecurityRequiresSecureConnection:
            "This address needs https (only localhost may use http)."
        default:
            error.localizedDescription
        }
    }
}
