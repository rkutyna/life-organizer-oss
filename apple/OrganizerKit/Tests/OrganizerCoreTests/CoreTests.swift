import Foundation
import OrganizerAPI
import OrganizerCore
import OrganizerTestSupport
import Testing

@Suite("Base URL rule")
struct ServerConfigTests {
    let fallback = URL(string: "http://localhost:8600")!

    @Test func environmentWins() {
        let resolved = ServerConfig.resolve(
            environment: ["ORGANIZER_BASE_URL": "http://localhost:8620/"],
            settings: "https://example.test", defaultURL: fallback)
        #expect(resolved == .init(url: URL(string: "http://localhost:8620")!, source: .environment))
    }

    @Test func settingsBeforeDefault() {
        let resolved = ServerConfig.resolve(environment: [:], settings: " https://example.test:10000 ", defaultURL: fallback)
        #expect(resolved == .init(url: URL(string: "https://example.test:10000")!, source: .settings))
    }

    @Test func defaultWhenNothingUsable() {
        let resolved = ServerConfig.resolve(environment: ["ORGANIZER_BASE_URL": "not a url"], settings: "ftp://x",
                                            defaultURL: fallback)
        #expect(resolved == .init(url: fallback, source: .defaultValue))
    }

    @Test func normalize() {
        #expect(ServerConfig.normalize("localhost:8600") == nil)  // needs a scheme
        #expect(ServerConfig.normalize("http://") == nil)
        #expect(ServerConfig.normalize("http://127.0.0.1:8620//")?.absoluteString == "http://127.0.0.1:8620")
    }

    @Test func savedSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "organizer-tests-\(UUID().uuidString)"))
        ServerConfig.saveSettingsURL("https://example.test/", defaults: defaults)
        #expect(defaults.string(forKey: ServerConfig.settingsKey) == "https://example.test")
        ServerConfig.saveSettingsURL("  ", defaults: defaults)
        #expect(defaults.string(forKey: ServerConfig.settingsKey) == nil)
    }

    @Test func defaultIsThisMac() {
        #expect(ServerConfig.defaultURL.absoluteString == "http://localhost:8600")
    }

    @Test func webLinksGoToTheServerInUse() {
        let base = URL(string: "https://organizer.example.com")!
        #expect(ServerConfig.webURL(path: "/jobs/applications/3", base: base).absoluteString
                == "https://organizer.example.com/jobs/applications/3")
        #expect(ServerConfig.webURL(path: "jobs", base: base).absoluteString == "https://organizer.example.com/jobs")
    }

    @Test func plainHTTPIsFlaggedOnlyForAnotherHost() {
        #expect(!ServerConfig.isInsecureRemote(URL(string: "http://localhost:8600")!))
        #expect(!ServerConfig.isInsecureRemote(URL(string: "http://127.0.0.1:8600")!))
        #expect(!ServerConfig.isInsecureRemote(URL(string: "http://[::1]:8600")!))
        #expect(ServerConfig.isInsecureRemote(URL(string: "http://192.168.1.20:8600")!))
        #expect(!ServerConfig.isInsecureRemote(URL(string: "https://organizer.example.com")!))
    }
}

@Suite("Token rule")
struct TokenRuleTests {
    @Test func environmentWinsAndSkipsTheStore() {
        let store = ThrowingStore()
        let resolved = ServerConfig.resolveToken(environment: ["ORGANIZER_TOKEN": " abc "], store: store)
        #expect(resolved == .init(token: "abc", source: .environment))
        #expect(store.reads == 0)
    }

    @Test func storeWhenNoEnvironment() {
        let resolved = ServerConfig.resolveToken(environment: [:], store: MemoryTokenStore("saved"))
        #expect(resolved == .init(token: "saved", source: .keychain))
    }

    @Test func noneWhenNothingIsSet() {
        #expect(ServerConfig.resolveToken(environment: ["ORGANIZER_TOKEN": "  "], store: MemoryTokenStore()).source == .none)
        #expect(ServerConfig.resolveToken(environment: [:], store: ThrowingStore()).source == .none)
    }

    @Test func memoryStoreSavesAndForgets() throws {
        let store = MemoryTokenStore()
        try store.save("t")
        #expect(try store.read() == "t")
        try store.delete()
        #expect(try store.read() == nil)
    }

    /// Counts reads and always fails, like a Keychain that refuses.
    final class ThrowingStore: TokenStore, @unchecked Sendable {
        var reads = 0
        func read() throws -> String? {
            reads += 1
            throw TokenStoreError(status: -1, operation: "read")
        }
        func save(_ token: String) throws {}
        func delete() throws {}
    }
}

@Suite("Connection check")
struct ConnectionCheckTests {
    static let status = #"{"ok": true, "version": "0.1.0", "timezone": "UTC", "modules": []}"#

    @Test func connectedWithBothScopes() async {
        let server = StubServer()
        server.respond(.get, "/api/health", json: #"{"ok": true}"#)
        server.respond(.get, "/api/status", json: Self.status)
        server.respond(.get, "/api/mail/accounts", json: "[]")
        let outcome = await ConnectionCheck(client: server.client()).run()
        #expect(outcome.isSuccess)
        if case .connected(_, let mail) = outcome { #expect(mail) }
    }

    @Test func missingMailScopeStillConnects() async {
        let server = StubServer()
        server.respond(.get, "/api/health", json: #"{"ok": true}"#)
        server.respond(.get, "/api/status", json: Self.status)
        server.respond(.get, "/api/mail/accounts", status: 403, json: #"{"detail": "this credential lacks the 'mail' scope"}"#)
        let outcome = await ConnectionCheck(client: server.client()).run()
        guard case .connected(_, let mail) = outcome else { Issue.record("expected connected"); return }
        #expect(!mail)
        #expect(outcome.message.contains("no mail scope"))
    }

    @Test func badTokenAndMissingScope() async {
        let server = StubServer()
        server.respond(.get, "/api/health", json: #"{"ok": true}"#)
        server.respond(.get, "/api/status", status: 401, json: #"{"detail": "invalid or revoked API token"}"#)
        #expect(await ConnectionCheck(client: server.client()).run() == .badToken("invalid or revoked API token"))

        let other = StubServer()
        other.respond(.get, "/api/health", json: #"{"ok": true}"#)
        other.respond(.get, "/api/status", status: 403, json: #"{"detail": "this credential lacks the 'api' scope"}"#)
        #expect(await ConnectionCheck(client: other.client()).run() == .missingAPIScope("this credential lacks the 'api' scope"))
    }

    @Test func noTokenAndNoServer() async {
        let server = StubServer()
        server.respond(.get, "/api/health", json: #"{"ok": true}"#)
        #expect(await ConnectionCheck(client: server.client(token: nil)).run() == .noToken)
        let down = OrganizerClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "x")
        guard case .unreachable = await ConnectionCheck(client: down).run() else { Issue.record("expected unreachable"); return }
    }
}

@Suite("Freshness")
struct FreshnessTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func freshCopyHasNoBadge() {
        #expect(!Freshness.showsBadge(fetchedAt: now.addingTimeInterval(-60), refreshFailed: false, now: now, threshold: 300))
    }

    @Test func oldCopyHasABadge() {
        #expect(Freshness.showsBadge(fetchedAt: now.addingTimeInterval(-301), refreshFailed: false, now: now, threshold: 300))
    }

    @Test func failedRefreshAlwaysHasABadge() {
        #expect(Freshness.showsBadge(fetchedAt: now, refreshFailed: true, now: now, threshold: 300))
    }

    /// Off the main actor on purpose: the helper is nonisolated (Calendar's readings use it).
    @Test func ageReadsInWords() async {
        #expect(Freshness.age(of: now.addingTimeInterval(-10), now: now) == "just now")
        #expect(Freshness.age(of: now.addingTimeInterval(-44), now: now) == "just now")
        let minutes = Freshness.age(of: now.addingTimeInterval(-12 * 60), now: now)
        #expect(minutes != "just now")
        #expect(minutes.contains("12"))
        #expect(!Freshness.age(of: now.addingTimeInterval(-3 * 3600), now: now).contains("12"))
    }

    @Test func oldestPartDecides() {
        let a = now.addingTimeInterval(-10), b = now.addingTimeInterval(-500)
        #expect(Freshness.oldest([a, nil, b]) == b)
    }

    @Test func loadablePhases() {
        #expect({ if case .loading = Loadable<Int>().phase { true } else { false } }())
        #expect({ if case .failed = Loadable<Int>(error: .transport(message: "x")).phase { true } else { false } }())
        #expect({ if case .content = Loadable<Int>(value: 1, error: .transport(message: "x")).phase { true } else { false } }())
        #expect(Loadable<Int>(value: 1, fetchedAt: now, error: .transport(message: "x")).showsFreshness(now: now))
        #expect(!Loadable<Int>(value: 1, fetchedAt: now).showsFreshness(now: now))
    }
}

@Suite("Resource")
@MainActor
struct ResourceTests {
    @Test func startsFromCacheThenRefreshes() async throws {
        let server = StubServer()
        let cache = temporaryCache()
        server.respond(.get, "/api/reminders/lists", json: "[]")
        let client = server.client(cache: cache)
        _ = try await client.fetch(API.Reminders.reminderLists())

        let resource = Resource(API.Reminders.reminderLists(), client: client)
        #expect(resource.state.isCached)
        #expect(resource.value == [])

        await resource.refresh()
        #expect(!resource.state.isCached)
        #expect(resource.state.error == nil)
    }

    @Test func failedRefreshKeepsTheCopy() async throws {
        let server = StubServer()
        let cache = temporaryCache()
        server.respond(.get, "/api/status", json: #"{"ok": true, "version": "0.1.0", "timezone": "UTC", "modules": []}"#)
        let client = server.client(cache: cache)
        let resource = Resource(API.Status.status(), client: client)
        await resource.refresh()
        #expect(resource.value?.version == "0.1.0")

        server.respond(.get, "/api/status", status: 503, json: #"{"detail": "down for maintenance"}"#)
        await resource.refresh()
        #expect(resource.value?.version == "0.1.0")
        #expect(resource.state.error?.message == "down for maintenance")
        #expect(resource.state.showsFreshness())
    }

    @Test func modifyAndRestore() async {
        let server = StubServer()
        let resource = Resource<[Int]>(preview: [1, 2, 3], client: server.client())
        let before = resource.modify { $0.removeAll { $0 == 2 } }
        #expect(resource.value == [1, 3])
        resource.restore(before)
        #expect(resource.value == [1, 2, 3])
    }
}

@Suite("Day labels")
struct DayLabelTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    // Friday 2026-10-23, 10:30 in New York.
    var now: Date { LocalTime(hour: 10, minute: 30).date(on: LocalDate(year: 2026, month: 10, day: 23), calendar: calendar) }

    @Test func relativeDays() {
        #expect(DayLabels.day(LocalDate(year: 2026, month: 10, day: 23), now: now, calendar: calendar) == "Today")
        #expect(DayLabels.day(LocalDate(year: 2026, month: 10, day: 24), now: now, calendar: calendar) == "Tomorrow")
        #expect(DayLabels.day(LocalDate(year: 2026, month: 10, day: 22), now: now, calendar: calendar) == "Yesterday")
        #expect(DayLabels.day(LocalDate(year: 2026, month: 10, day: 27), now: now, calendar: calendar) == "Tuesday")
    }

    @Test func farDaysShowTheDate() {
        let label = DayLabels.day(LocalDate(year: 2026, month: 11, day: 30), now: now, calendar: calendar)
        #expect(label.contains("30") && label.contains("Nov"))
        let nextYear = DayLabels.day(LocalDate(year: 2027, month: 1, day: 5), now: now, calendar: calendar)
        #expect(nextYear.contains("2027"))
    }

    @Test func dueWithTime() {
        let label = DayLabels.due(LocalDate(year: 2026, month: 10, day: 24), LocalTime(hour: 15, minute: 0), now: now, calendar: calendar)
        #expect(label.hasPrefix("Tomorrow 3:00"))
    }
}

@Suite("Cloudflare Access service token")
struct AccessTokenTests {
    @Test func bothPartsOrNothing() {
        #expect(AccessServiceToken(clientID: "id", clientSecret: " ") == nil)
        #expect(AccessServiceToken(clientID: nil, clientSecret: "s") == nil)
        #expect(AccessServiceToken(clientID: " id ", clientSecret: "s")?.clientID == "id")
    }

    @Test func environmentPairWinsOverSaved() {
        let env = ["ORGANIZER_CF_ACCESS_CLIENT_ID": "env.access", "ORGANIZER_CF_ACCESS_CLIENT_SECRET": "env-secret"]
        let resolved = ServerConfig.resolveAccess(environment: env, savedID: "saved.access", secretStore: MemoryTokenStore("saved"))
        #expect(resolved.source == .environment)
        #expect(resolved.token?.clientID == "env.access")
    }

    @Test func savedNeedsBothIdAndSecret() {
        #expect(ServerConfig.resolveAccess(environment: [:], savedID: "saved.access", secretStore: MemoryTokenStore("s")).source == .saved)
        #expect(ServerConfig.resolveAccess(environment: [:], savedID: "saved.access", secretStore: MemoryTokenStore()).source == .none)
        #expect(ServerConfig.resolveAccess(environment: [:], savedID: nil, secretStore: MemoryTokenStore("s")).source == .none)
        // Only one environment variable: ignored.
        #expect(ServerConfig.resolveAccess(environment: ["ORGANIZER_CF_ACCESS_CLIENT_ID": "x"], savedID: nil,
                                           secretStore: MemoryTokenStore()).source == .none)
    }

    @Test func clientSendsBothHeadersWithTheBearer() async throws {
        let server = StubServer()
        server.respond(.get, "/api/health", json: #"{"ok": true}"#)
        let access = try #require(AccessServiceToken(clientID: "abc.access", clientSecret: "shh"))
        let client = OrganizerClient(baseURL: server.baseURL, token: "t", access: access, session: server.session())
        _ = try await client.send(API.Status.health())
        let request = try #require(server.requests.last)
        #expect(request.header("CF-Access-Client-Id") == "abc.access")
        #expect(request.header("CF-Access-Client-Secret") == "shh")
        #expect(request.header("Authorization") == "Bearer t")

        let plain = server.client()
        _ = try await plain.send(API.Status.health())
        #expect(server.requests.last?.header("CF-Access-Client-Id") == nil)
    }
}
