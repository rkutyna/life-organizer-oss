import Foundation
import OrganizerAPI
import OrganizerCore
import OrganizerTestSupport
import Testing

@testable import OrganizerUI

/// One write per module through the app's own stores, against a LOCAL demo server, then read
/// back from the server: completes a reminder and changes an application's status. They write,
/// so they run only when asked:
///
///     ORGANIZER_LIVE_WRITES=1 ORGANIZER_TEST_SERVER=http://localhost:8601 ORGANIZER_TEST_TOKEN=... \
///       swift test --filter LiveWrite
///
/// Use a throwaway demo database (`python -m app.demo_seed`), never your own.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORGANIZER_LIVE_WRITES"] == "1"
    && ProcessInfo.processInfo.environment["ORGANIZER_TEST_SERVER"] != nil), .serialized)
@MainActor
struct LiveWriteTests {
    static func app() throws -> AppEnvironment {
        let env = ProcessInfo.processInfo.environment
        let server = try #require(env["ORGANIZER_TEST_SERVER"].flatMap(URL.init(string:)))
        try #require(ServerConfig.isLoopback(server.host() ?? ""), "live writes only go to a local server")
        return AppEnvironment(
            resolveServer: { .init(url: server, source: .environment) },
            tokenStore: MemoryTokenStore(env["ORGANIZER_TEST_TOKEN"]),
            accessSecretStore: MemoryTokenStore(),
            accessIDDefaults: UserDefaults(suiteName: "organizer-live-\(UUID().uuidString)") ?? .standard,
            environment: [:],
            cache: temporaryCache()
        )
    }

    @Test func completeAReminder() async throws {
        let app = try Self.app()
        let store = RemindersStore(client: app.client)
        await store.refresh()
        let open = try #require(store.reminders.value?.first { !$0.completed && !store.isLocked($0) })
        await store.toggle(open)
        #expect(store.notice == nil, "\(String(describing: store.notice))")
        let fresh = try await app.client.send(API.Reminders.getReminder(reminderId: open.id))
        #expect(fresh.completed)
        #expect(fresh.sync.state != .synced || fresh.source == .google, "an Apple change waits in the queue for the helper")
    }

    @Test func changeAnApplicationsStatus() async throws {
        let app = try Self.app()
        let store = JobsStore(client: app.client)
        await store.prepare()
        await store.load(.applications)
        let application = try #require(store.applications.value?.first { $0.status == "applied" })
        try await store.changeStatus(application.id, to: "screen", note: "live write test")
        let fresh = try await app.client.send(API.Jobs.getApplication(applicationId: application.id))
        #expect(fresh.status == "screen")
        let history = try await app.client.send(API.Jobs.listStatusEvents(applicationId: application.id))
        #expect(history.contains { $0.status == "screen" })
    }
}
