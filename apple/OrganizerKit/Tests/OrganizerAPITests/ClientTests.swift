import Foundation
import OrganizerAPI
import OrganizerTestSupport
import Testing

@Suite("OrganizerClient")
struct ClientTests {
    static let status = #"{"ok": true, "version": "0.1.0", "timezone": "UTC", "modules": []}"#

    @Test func everyRequestCarriesTheBearerToken() async throws {
        let server = StubServer()
        server.respond(.get, "/api/status", json: Self.status)
        server.respond(.post, "/api/reminders/sync", json: "[]")
        let client = server.client()

        _ = try await client.send(API.Status.status())
        _ = try? await client.send(API.Reminders.syncNow())

        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.header("Authorization") == "Bearer test-token" })
        #expect(server.requests.allSatisfy { $0.header("X-Author") == nil })
    }

    @Test func noTokenSendsNoCredential() async throws {
        let server = StubServer()
        server.respond(.get, "/api/health", json: #"{"ok": true}"#)
        let client = server.client(token: nil)
        #expect(!client.hasToken)
        _ = try? await client.send(API.Status.health())
        #expect(server.requests.last?.header("Authorization") == nil)
    }

    @Test func bodiesAreSnakeCaseJSON() async throws {
        let server = StubServer()
        server.respond(.patch, "/api/reminders/7", status: 409, json: #"{"detail": "x"}"#)
        _ = try? await server.client().send(API.Reminders.updateReminder(reminderId: 7, body: ReminderUpdate(dueDate: .null, listId: .value("a"))))
        let sent = try #require(server.requests.last?.json)
        #expect(sent == ["due_date": nil, "list_id": "a"])
        #expect(server.requests.last?.header("Content-Type") == "application/json")
    }

    @Test func refusalsKeepTheServersMessage() async throws {
        let server = StubServer()
        server.respond(.get, "/api/status", status: 401, json: #"{"detail": "invalid or revoked API token"}"#)
        server.respond(.get, "/api/mail/accounts", status: 403, json: #"{"detail": "this credential lacks the 'mail' scope"}"#)
        let client = server.client()
        do {
            _ = try await client.send(API.Status.status())
            Issue.record("expected a 401")
        } catch let error as APIError {
            #expect(error.isUnauthorized)
            #expect(error.message == "invalid or revoked API token")
        }
        do {
            _ = try await client.send(API.Mail.listAccounts())
            Issue.record("expected a 403")
        } catch let error as APIError {
            #expect(error.isForbidden)
            #expect(error.message.contains("'mail' scope"))
        }
    }

    @Test func getsAreCachedPerServerAndMailIsNot() async throws {
        let server = StubServer()
        let cache = temporaryCache()
        server.respond(.get, "/api/status", json: Self.status)
        server.respond(.get, "/api/mail/accounts", json: "[]")
        let client = server.client(cache: cache)

        #expect(client.cached(API.Status.status()) == nil)
        let fetched = try await client.fetch(API.Status.status())
        #expect(!fetched.isCached)
        let cached = try #require(client.cached(API.Status.status()))
        #expect(cached.isCached)
        #expect(cached.value.version == "0.1.0")

        _ = try await client.send(API.Mail.listAccounts())
        #expect(client.cached(API.Mail.listAccounts()) == nil)

        let other = StubServer().client(cache: cache)
        #expect(other.cached(API.Status.status()) == nil)
    }

    @Test func unreachableServerIsTransport() async throws {
        let client = OrganizerClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "x")
        do {
            _ = try await client.status.check()
            Issue.record("expected a transport error")
        } catch let error as APIError {
            #expect(error.isOffline)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
