import Foundation
import OrganizerAPI

/// Settings' Test Connection: is the server there, is the token good, and which scopes does
/// it have.
///
/// 1. `GET /api/health` without a token: the server answers at all.
/// 2. `GET /api/status` with the token: 401 is a wrong or revoked token, 403 a token without
///    the `api` scope.
/// 3. `GET /api/mail/accounts` with the token: 403 is a token without the `mail` scope (the
///    rest of the app works; Mail does not).
public struct ConnectionCheck: Sendable {
    public let client: OrganizerClient

    public init(client: OrganizerClient) {
        self.client = client
    }

    public enum Outcome: Equatable, Sendable {
        /// Everything works. `mailScope` is false when the token lacks `mail`.
        case connected(StatusOut, mailScope: Bool)
        /// The server could not be reached, or did not answer like the organizer.
        case unreachable(String)
        /// No token was given.
        case noToken
        /// 401: the token is wrong or revoked.
        case badToken(String)
        /// 403 on the organizer API: the token lacks the `api` scope.
        case missingAPIScope(String)
        /// Any other refusal, with the server's message.
        case failed(String)

        /// A sentence for Settings.
        public var message: String {
            switch self {
            case .connected(_, let mail):
                mail ? "Connected. The token has the api and mail scopes."
                    : "Connected, but the token has no mail scope, so Mail will not load. Make a token with the api and mail scopes."
            case .unreachable(let why): "Can't reach the organizer: \(why)"
            case .noToken: "Enter an API token. Make one in the web app: Settings → API tokens, author \"You\", scopes API and Mail."
            case .badToken(let why): "The server refused the token (401: \(why)). It is mistyped or was revoked; make a new one in the web app."
            case .missingAPIScope(let why): "The token lacks the api scope (403: \(why)). Make one with the api and mail scopes."
            case .failed(let why): why
            }
        }

        public var isSuccess: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public func run() async -> Outcome {
        do {
            _ = try await client.send(API.Status.health())
        } catch {
            let error = APIError(error)
            return .unreachable(error.message)
        }
        guard client.hasToken else { return .noToken }
        let status: StatusOut
        do {
            status = try await client.send(API.Status.status())
        } catch {
            let error = APIError(error)
            switch error.status {
            case 401: return .badToken(error.message)
            case 403: return .missingAPIScope(error.message)
            default: return .failed(error.message)
            }
        }
        do {
            _ = try await client.send(API.Mail.listAccounts())
            return .connected(status, mailScope: true)
        } catch {
            let error = APIError(error)
            if error.status == 403 { return .connected(status, mailScope: false) }
            return .failed("Connected, but Mail answered: \(error.message)")
        }
    }
}
