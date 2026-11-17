import XCTest
@testable import HelperCore

final class HelperLockTests: XCTestCase {
    var dir: URL!
    var path: String { dir.appendingPathComponent("state/helper.lock").path }

    override func setUp() { dir = tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testSecondAcquireFailsAndNamesTheHolder() throws {
        let first = try HelperLock.acquire(path: path)
        XCTAssertEqual(first.holder.pid, getpid())
        // Same process, a separate open file description: flock still refuses.
        XCTAssertThrowsError(try HelperLock.acquire(path: path)) { error in
            guard case HelperStartError.anotherHelperRunning(let holder, let lockPath) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(lockPath, path)
            XCTAssertEqual(holder?.pid, getpid())
            XCTAssertEqual(holder?.version, HelperVersion.string)
            XCTAssertTrue("\(error)".contains("another helper is running"), "\(error)")
        }
        first.release()
        let second = try HelperLock.acquire(path: path)
        XCTAssertEqual(HelperLock.currentHolder(path: path), second.holder)
        second.release()
        XCTAssertNil(HelperLock.currentHolder(path: path), "the file is emptied on release")
    }

    func testDeinitReleasesTheLock() throws {
        do { _ = try HelperLock.acquire(path: path) }
        let again = try HelperLock.acquire(path: path)
        again.release()
        again.release()  // idempotent
        XCTAssertFalse(again.isHeld)
    }

    func testAHolderThatDiedIsNotReported() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let stale = HelperLock.Holder(pid: 999_999, version: "0.0.1", started_at: Date(), executable: nil)
        try JSONCoding.encoder().encode(stale).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(HelperLock.currentHolder(path: path))
        try HelperLock.acquire(path: path).release()
    }
}

final class DaemonTests: XCTestCase {
    var dir: URL!
    var state: HelperStateFiles { HelperStateFiles(directory: dir.appendingPathComponent("state").path) }

    override func setUp() {
        dir = tempDir()
        log.configure(path: nil, stderr: false)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func options() -> Daemon.Options {
        Daemon.Options(stateFiles: state, requestAccessOnStart: true, stopGraceSeconds: 2, retryDelays: [], tickSeconds: 0.02)
    }

    func sampleWorld() -> FakeWorld {
        let calendars = FakeCalendarSource(
            calendars: [CalendarInfo(id: "c1", title: "Home", color: "#3366CC", account: "iCloud", account_type: "caldav")],
            events: [CalendarEvent(uid: "e1", calendar_id: "c1", title: "Call the dentist", start: Date().addingTimeInterval(3600),
                                   end: Date().addingTimeInterval(5400), all_day: false, location: nil, url: nil,
                                   occurrence_start: Date().addingTimeInterval(3600), status: "confirmed")])
        return FakeWorld(calendars: calendars)
    }

    func testTwoDaemonsNeverRunTogether() async throws {
        var config = testConfig()
        config.calendar.enabled = false
        config.reminders.enabled = false
        let world = FakeWorld()
        let a = Daemon(config: config, environment: world.environment(), options: options())
        let b = Daemon(config: config, environment: world.environment(), options: options())
        try a.start()
        XCTAssertThrowsError(try b.start()) { error in
            guard case HelperStartError.anotherHelperRunning = error else { return XCTFail("\(error)") }
        }
        await a.stop()
        try b.start()  // a refused start can be retried once the lock is free
        XCTAssertThrowsError(try b.start()) { XCTAssertEqual($0 as? HelperStartError, .alreadyStarted) }
        await b.stop()
        await b.stop()
        XCTAssertNil(HelperLock.currentHolder(path: state.lock))
    }

    func testFirstRunAsksForAccessThenPushesBothSnapshots() async throws {
        let world = sampleWorld()
        let permissions = FakePermissions(calendars: .notDetermined, reminders: .notDetermined)
        let w = FakeWorld(permissions: permissions, calendars: world.calendars, reminders: world.reminders, organizer: world.organizer)
        let d = Daemon(config: testConfig(), environment: w.environment(), options: options())
        try d.start()
        let pushed = await waitUntil { !w.organizer.pushes(.calendar).isEmpty && !w.organizer.pushes(.reminders).isEmpty }
        await d.stop()
        XCTAssertTrue(pushed)
        XCTAssertEqual(permissions.requests.sorted(), ["calendars", "reminders"])

        let cal = try XCTUnwrap(w.organizer.pushes(.calendar).first)
        XCTAssertEqual(cal["source"] as? String, "eventkit")
        XCTAssertEqual(cal["host"] as? String, "test-mac")
        XCTAssertEqual((cal["events"] as? [[String: Any]])?.first?["title"] as? String, "Call the dentist")
        let rem = try XCTUnwrap(w.organizer.pushes(.reminders).first)
        XCTAssertEqual((rem["reminders"] as? [[String: Any]])?.first?["title"] as? String, "Buy milk")
        XCTAssertEqual(rem["default_list_id"] as? String, "L-groceries")
        XCTAssertTrue(w.organizer.requests.allSatisfy { $0.headers["Authorization"] == "Bearer test-ingest-token" })

        let status = try XCTUnwrap(DaemonStatus.load(path: state.status))
        XCTAssertEqual(status.calendar_authorization, "fullAccess")
        XCTAssertEqual(status.reminders_authorization, "fullAccess")
        XCTAssertTrue(status.streams["calendar"]?.last_result?.hasPrefix("pushed: calendars=1 events=1") ?? false,
                      status.streams["calendar"]?.last_result ?? "")
        XCTAssertNotNil(status.streams["reminders.ops"]?.last_success)
    }

    func testDeniedAccessIsReportedAndNothingIsRead() async throws {
        let world = FakeWorld(permissions: FakePermissions(calendars: .denied, reminders: .denied))
        let d = Daemon(config: testConfig(), environment: world.environment(), options: options())
        try d.start()
        let reported = await waitUntil {
            let s = d.currentStatus
            return s.streams["calendar"]?.last_error != nil && s.streams["reminders"]?.last_error != nil
        }
        await d.stop()
        XCTAssertTrue(reported)
        XCTAssertTrue(world.permissions.requests.isEmpty, "denied cannot be asked again; System Settings only")
        XCTAssertTrue(world.calendars.queries.isEmpty)
        XCTAssertTrue(world.organizer.requests.isEmpty)
        XCTAssertEqual(d.currentStatus.streams["calendar"]?.last_error, "skipped: calendar access is denied")
    }

    func testOpsAreAppliedAckedAndAFreshSnapshotFollows() async throws {
        let world = sampleWorld()
        world.organizer.queue(["id": 11, "reminder_id": 1, "kind": "complete", "external_id": "ext-r1", "local_id": "r1",
                               "fields": [String: Any](), "base": ["completed": false], "queued_at": "2026-10-19T12:00:00+00:00"])
        world.organizer.queue(["id": 12, "reminder_id": 2, "kind": "create", "external_id": NSNull(), "local_id": NSNull(),
                               "fields": ["title": "Call the dentist", "notes": "", "due_date": "2026-10-23", "due_time": "09:30",
                                          "priority": 1, "list_id": "L-errands"],
                               "base": [String: Any](), "queued_at": "2026-10-19T12:00:00+00:00"])
        var config = testConfig()
        config.calendar.enabled = false
        let d = Daemon(config: config, environment: world.environment(), options: options())
        try d.start()
        let done = await waitUntil {
            world.organizer.acks.count == 2
                && world.organizer.pushes(.reminders).contains { push in
                    (push["reminders"] as? [[String: Any]])?.contains { $0["title"] as? String == "Call the dentist" } ?? false
                }
        }
        await d.stop()
        XCTAssertTrue(done)
        let acks = world.organizer.acks
        XCTAssertEqual(acks.map(\.0), [11, 12])
        XCTAssertEqual(acks[0].1["ok"] as? Bool, true)
        XCTAssertEqual(acks[1].1["ok"] as? Bool, true)
        XCTAssertNotNil(acks[1].1["local_id"] as? String, "a create sends the new reminder's ids")
        XCTAssertNotNil(acks[1].1["external_id"] as? String)
        XCTAssertEqual(world.reminders.items["r1"]?.values.completed, true)
        let made = world.reminders.items.values.first { $0.values.title == "Call the dentist" }
        XCTAssertEqual(made?.listId, "L-errands")
        XCTAssertEqual(made?.values.due_time, "09:30")
        // The snapshot after the ops shows them.
        let last = try XCTUnwrap(world.organizer.pushes(.reminders).last)
        let r1 = (last["reminders"] as? [[String: Any]])?.first { $0["local_id"] as? String == "r1" }
        XCTAssertEqual(r1?["completed"] as? Bool, true)
        XCTAssertTrue(world.reminders.writes.allSatisfy { !$0.hasPrefix("remove") })
    }

    func testAWithdrawnOpIsDroppedAndAFailedOpIsAcked() async throws {
        let world = FakeWorld()
        world.organizer.queue(["id": 21, "reminder_id": 7, "kind": "complete", "external_id": "gone", "local_id": "gone",
                               "queued_at": "2026-10-19T12:00:00+00:00"])
        var config = testConfig()
        config.calendar.enabled = false
        let d = Daemon(config: config, environment: world.environment(), options: options())
        try d.start()
        let acked = await waitUntil { world.organizer.acks.count == 1 }
        await d.stop()
        XCTAssertTrue(acked)
        XCTAssertEqual(world.organizer.acks[0].1["ok"] as? Bool, false)
        XCTAssertTrue((world.organizer.acks[0].1["error"] as? String)?.contains("not in Apple Reminders") ?? false)
    }

    func testUnchangedSnapshotsAreNotRepushedUntilTheHeartbeat() async throws {
        let world = sampleWorld()
        var config = testConfig()
        config.reminders.enabled = false
        config.heartbeat_seconds = 900
        let runtime = HelperRuntime(config: config, environment: world.environment(), stateFiles: state, retryDelays: [])
        let gate = StreamGate(heartbeat: config.heartbeat_seconds)
        let now = Date()
        guard case .delivered = await runtime.runStream(.calendar, gate: gate, now: now) else { return XCTFail() }
        guard case .unchanged = await runtime.runStream(.calendar, gate: gate, now: now.addingTimeInterval(60)) else { return XCTFail() }
        XCTAssertEqual(world.organizer.pushes(.calendar).count, 1)
        guard case .delivered = await runtime.runStream(.calendar, gate: gate, now: now.addingTimeInterval(901)) else {
            return XCTFail("the heartbeat re-pushes an unchanged snapshot")
        }
        XCTAssertEqual(world.organizer.pushes(.calendar).count, 2)
        world.calendars.calendarList.append(CalendarInfo(id: "c2", title: "Work", color: nil, account: "iCloud", account_type: "caldav"))
        guard case .delivered = await runtime.runStream(.calendar, gate: gate, now: now.addingTimeInterval(920)) else {
            return XCTFail("a change pushes at once")
        }
    }

    func testAFailedPushIsRetriedOnTheNextRun() async throws {
        let world = sampleWorld()
        let runtime = HelperRuntime(config: testConfig(), environment: world.environment(), stateFiles: state, retryDelays: [])
        let gate = StreamGate(heartbeat: 900)
        world.organizer.forcedStatus = 500
        guard case .failed = await runtime.runStream(.calendar, gate: gate) else { return XCTFail() }
        world.organizer.forcedStatus = nil
        guard case .delivered = await runtime.runStream(.calendar, gate: gate) else { return XCTFail("the same snapshot is pushed again") }
    }

    func testAStoreChangeTriggersAnEarlyRun() async throws {
        let world = sampleWorld()
        var config = testConfig()
        config.reminders.enabled = false
        config.calendar.interval_seconds = 3600
        config.calendar.debounce_seconds = 0
        let d = Daemon(config: config, environment: world.environment(), options: options())
        try d.start()
        let first = await waitUntil { world.organizer.pushes(.calendar).count == 1 && world.changes.count == 1 }
        XCTAssertTrue(first)
        world.calendars.eventList.removeAll()
        world.changes.fire()
        let second = await waitUntil { world.organizer.pushes(.calendar).count == 2 }
        await d.stop()
        XCTAssertTrue(second, "the change re-ran the calendar job before its hour was up")
        XCTAssertEqual((world.organizer.pushes(.calendar).last?["events"] as? [Any])?.count, 0)
        XCTAssertEqual(world.changes.count, 0, "stop removes the observer")
    }
}
