import Foundation
@testable import HelperCore

// Fakes for everything outside the helper: EventKit (reminders, calendars, permissions), the
// Keychain and the organizer server. No test touches the real Calendar, Reminders, Keychain or
// network. Every list, title, id and host is invented; servers are example.com hosts that are
// never contacted.

let t0 = Date(timeIntervalSince1970: 1_792_000_000)  // an arbitrary fixed instant

func rv(_ title: String, notes: String = "", date: String? = nil, time: String? = nil, priority: Int? = nil,
        completed: Bool = false) -> ReminderValues {
    ReminderValues(title: title, notes: notes, due_date: date, due_time: time, priority: priority, completed: completed)
}

// MARK: - reminders

final class FakeReminderStore: ReminderStore, @unchecked Sendable {
    var listRecords: [ReminderListRecord]
    var defaultId: String?
    var items: [String: ReminderRecord] = [:]
    /// Stamped on every write as lastModifiedDate.
    var clock: Date
    var writes: [String] = []
    var failWrites = false
    private var nextId = 1

    init(lists: [ReminderListRecord], defaultId: String?, clock: Date) {
        listRecords = lists; self.defaultId = defaultId; self.clock = clock
    }

    func put(_ r: ReminderRecord) { items[r.localId] = r }

    func lists() -> [ReminderListRecord] { listRecords }
    func defaultListId() -> String? { defaultId }

    func fetchReminders(listIds: [String], completedSince: Date?) async throws -> [ReminderRecord] {
        items.values.filter { r in
            listIds.contains(r.listId)
                && (!r.values.completed || completedSince == nil || (r.completionDate ?? .distantPast) >= completedSince!)
        }.sorted { $0.localId < $1.localId }
    }

    func reminder(localId: String) -> ReminderRecord? { items[localId] }
    func reminders(externalId: String) -> [ReminderRecord] { items.values.filter { $0.externalId == externalId } }

    func create(listId: String, change: ReminderChange) throws -> ReminderRecord {
        guard let list = listRecords.first(where: { $0.id == listId }) else { throw ReminderStoreError.listNotFound(listId) }
        guard list.writable else { throw ReminderStoreError.listReadOnly(list.title) }
        if failWrites { throw ReminderStoreError.fetchFailed }
        let id = "new-\(nextId)"
        nextId += 1
        var r = ReminderRecord(localId: id, externalId: "ext-\(id)", listId: listId, values: ReminderValues(title: ""), createdAt: clock)
        apply(change, to: &r)
        items[id] = r
        writes.append("create \(listId) \(r.values.title)")
        return r
    }

    func update(localId: String, change: ReminderChange) throws -> ReminderRecord {
        guard var r = items[localId] else { throw ReminderStoreError.notFound(localId) }
        if failWrites { throw ReminderStoreError.fetchFailed }
        apply(change, to: &r)
        items[localId] = r
        writes.append("update \(localId) \(change.fields.sorted().map(\.rawValue).joined(separator: ","))")
        return r
    }

    private func apply(_ change: ReminderChange, to r: inout ReminderRecord) {
        for field in change.fields {
            r.values = r.values.with(field, from: change.values)
            if field == .list, let id = change.listId { r.listId = id }
            if field == .completed { r.completionDate = change.values.completed ? (change.completionDate ?? clock) : nil }
        }
        r.modifiedAt = clock
    }
}

func makeStore() -> FakeReminderStore {
    let store = FakeReminderStore(lists: [
        ReminderListRecord(id: "L-groceries", title: "Groceries", color: "#34C759", account: "iCloud", accountType: "caldav"),
        ReminderListRecord(id: "L-errands", title: "Errands", account: "iCloud", accountType: "caldav"),
        ReminderListRecord(id: "L-shared", title: "Shared", account: "iCloud", accountType: "caldav", writable: false),
    ], defaultId: "L-groceries", clock: t0)
    store.put(ReminderRecord(localId: "r1", externalId: "ext-r1", listId: "L-groceries", values: rv("Buy milk"), modifiedAt: t0))
    return store
}

// MARK: - calendar

final class FakeCalendarSource: CalendarSource, @unchecked Sendable {
    var calendarList: [CalendarInfo]
    var eventList: [CalendarEvent]
    var queries: [(Date, Date)] = []

    init(calendars: [CalendarInfo] = [], events: [CalendarEvent] = []) {
        calendarList = calendars; eventList = events
    }

    func calendars() -> [CalendarInfo] { calendarList }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        queries.append((start, end))
        return eventList.filter { $0.start < end && $0.end > start }
    }
}

// MARK: - permissions, keychain

final class FakePermissions: PermissionsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cal: HelperAuthorization
    private var rem: HelperAuthorization
    private(set) var requests: [String] = []
    /// What a request turns `notDetermined` into.
    var grant = true

    init(calendars: HelperAuthorization = .fullAccess, reminders: HelperAuthorization = .fullAccess) {
        cal = calendars; rem = reminders
    }

    func calendars() -> HelperAuthorization { lock.withLock { cal } }
    func reminders() -> HelperAuthorization { lock.withLock { rem } }

    func requestCalendars() async -> Bool {
        lock.withLock {
            requests.append("calendars")
            if cal.canRequest { cal = grant ? .fullAccess : .denied }
            return cal == .fullAccess
        }
    }

    func requestReminders() async -> Bool {
        lock.withLock {
            requests.append("reminders")
            if rem.canRequest { rem = grant ? .fullAccess : .denied }
            return rem == .fullAccess
        }
    }
}

final class FakeKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private(set) var reads = 0
    var failRead: OSStatus?

    init(_ items: [String: String] = [:]) { self.items = items }

    static func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func read(service: String, account: String) throws -> String? {
        try lock.withLock {
            reads += 1
            if let failRead { throw KeychainError(status: failRead, operation: "read") }
            return items[Self.key(service, account)]
        }
    }

    func write(_ value: String, service: String, account: String) throws {
        lock.withLock { items[Self.key(service, account)] = value }
    }

    func value(service: String, account: String) -> String? { lock.withLock { items[Self.key(service, account)] } }
}

// MARK: - the organizer server

/// An in-memory organizer behind `HTTPTransport`: it answers the helper's four endpoints the
/// way the contract says, checks the Bearer token, and records every request.
final class FakeOrganizer: HTTPTransport, @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var json: Any?
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _ops: [[String: Any]] = []
    private var _acks: [(Int, [String: Any])] = []
    private var _withdrawn: Set<Int> = []
    var acceptedToken: String
    /// Status to answer every request with (overrides the routes), e.g. 503.
    var forcedStatus: Int?

    init(token: String = "test-ingest-token") { acceptedToken = token }

    var requests: [Request] { lock.withLock { _requests } }
    var acks: [(Int, [String: Any])] { lock.withLock { _acks } }
    func pushes(_ stream: IngestStream) -> [[String: Any]] {
        requests.filter { $0.method == "POST" && $0.path == stream.path }.compactMap { $0.json as? [String: Any] }
    }

    func queue(_ op: [String: Any]) { lock.withLock { _ops.append(op) } }
    func withdraw(_ id: Int) { lock.withLock { _withdrawn.insert(id); _ops.removeAll { ($0["id"] as? Int) == id } } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let entry = Request(method: request.httpMethod ?? "GET", path: path, headers: request.allHTTPHeaderFields ?? [:], json: json)
        let (code, body) = lock.withLock { () -> (Int, Any) in
            _requests.append(entry)
            if let forcedStatus { return (forcedStatus, ["detail": "forced"]) }
            guard entry.headers["Authorization"] == "Bearer \(acceptedToken)" else { return (401, ["detail": "Not authenticated"]) }
            switch (entry.method, path) {
            case ("POST", "/api/ingest/calendar"):
                guard let obj = json as? [String: Any], obj["window"] != nil else { return (422, ["detail": "invalid body"]) }
                return (200, ["calendars": (obj["calendars"] as? [Any])?.count ?? 0, "events": (obj["events"] as? [Any])?.count ?? 0])
            case ("POST", "/api/ingest/reminders"):
                let obj = json as? [String: Any] ?? [:]
                return (200, ["lists": (obj["lists"] as? [Any])?.count ?? 0, "reminders": (obj["reminders"] as? [Any])?.count ?? 0, "removed": 0])
            case ("GET", "/api/ingest/reminders/ops"):
                return (200, ["ops": _ops, "server_time": "2026-10-19T12:00:00+00:00"])
            case ("POST", let p) where p.hasPrefix("/api/ingest/reminders/ops/") && p.hasSuffix("/ack"):
                let id = Int(p.dropFirst("/api/ingest/reminders/ops/".count).dropLast("/ack".count)) ?? -1
                if _withdrawn.contains(id) { return (404, ["detail": "op not found"]) }
                _acks.append((id, json as? [String: Any] ?? [:]))
                _ops.removeAll { ($0["id"] as? Int) == id }
                return (200, ["ok": true])
            default:
                return (404, ["detail": "Not Found"])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

// MARK: - environments

struct FakeWorld {
    let permissions: FakePermissions
    let calendars: FakeCalendarSource
    let reminders: FakeReminderStore
    let organizer: FakeOrganizer
    let keychain: FakeKeychain
    let changes = ChangeHub()

    init(permissions: FakePermissions = FakePermissions(), calendars: FakeCalendarSource = FakeCalendarSource(),
         reminders: FakeReminderStore = makeStore(), organizer: FakeOrganizer = FakeOrganizer(), keychain: FakeKeychain = FakeKeychain()) {
        self.permissions = permissions; self.calendars = calendars; self.reminders = reminders
        self.organizer = organizer; self.keychain = keychain
    }

    func environment(zone: TimeZone = TimeZone(identifier: "America/New_York")!) -> HelperEnvironment {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let calendars = self.calendars, reminders = self.reminders, changes = self.changes
        return HelperEnvironment(
            permissions: permissions,
            makeCalendarSource: { calendars },
            makeReminderStore: { _ in reminders },
            transport: organizer,
            keychain: keychain,
            observeChanges: { changes.add($0) },
            calendar: cal
        )
    }
}

/// Stands in for EKEventStoreChanged.
final class ChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var next = 0

    func add(_ handler: @escaping @Sendable () -> Void) -> () -> Void {
        let id = lock.withLock { () -> Int in
            next += 1
            handlers[next] = handler
            return next
        }
        return { [weak self] in self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) } }
    }

    var count: Int { lock.withLock { handlers.count } }

    func fire() { for h in lock.withLock({ Array(handlers.values) }) { h() } }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("helper-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A config pointed at the fake organizer (an example.com URL that is never contacted).
func testConfig(token: String? = "test-ingest-token") -> HelperConfig {
    var c = HelperConfig()
    c.server = HelperConfig.Server(url: "https://organizer.example.com", token: token, timeout_seconds: 5)
    c.host = "test-mac"
    return c
}

/// Polls `condition` until it holds or `timeout` passes.
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}
