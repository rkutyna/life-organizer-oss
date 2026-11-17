import XCTest
@testable import HelperCore

// Reminders sync tests over an in-memory `ReminderStore`: no EventKit, no real reminders.

// MARK: - mapping

final class ReminderMappingTests: XCTestCase {
    let ny = TimeZone(identifier: "America/New_York")!

    func testPriorityBothWays() {
        XCTAssertEqual([0, 1, 4, 5, 6, 9].map(ReminderMapping.organizerPriority), [nil, 1, 1, 2, 3, 3])
        XCTAssertEqual([nil, 1, 2, 3].map(ReminderMapping.eventKitPriority), [0, 1, 5, 9])
        for p in [nil, 1, 2, 3] as [Int?] {
            XCTAssertEqual(ReminderMapping.organizerPriority(ReminderMapping.eventKitPriority(p)), p)
        }
    }

    func testDueRoundTripAllDayAndTimed() {
        let allDay = ReminderMapping.components(date: "2026-10-21", time: nil, zone: ny)
        XCTAssertNil(allDay?.hour)
        XCTAssertNil(allDay?.timeZone, "an all-day due date floats")
        XCTAssertEqual(ReminderMapping.due(from: allDay, zone: ny).date, "2026-10-21")
        XCTAssertNil(ReminderMapping.due(from: allDay, zone: ny).time)

        let timed = ReminderMapping.components(date: "2026-10-21", time: "09:05", zone: ny)
        XCTAssertEqual(timed?.hour, 9)
        XCTAssertEqual(timed?.timeZone, ny)
        let back = ReminderMapping.due(from: timed, zone: ny)
        XCTAssertEqual(back.date, "2026-10-21")
        XCTAssertEqual(back.time, "09:05")
        XCTAssertNil(ReminderMapping.components(date: nil, time: "09:00"))
    }

    func testTimedDueInAnotherZoneReadsAsLocalWallClock() {
        var comps = DateComponents(year: 2026, month: 10, day: 21, hour: 15, minute: 0)
        comps.timeZone = TimeZone(identifier: "UTC")
        let local = ReminderMapping.due(from: comps, zone: ny)
        XCTAssertEqual(local.date, "2026-10-21")
        XCTAssertEqual(local.time, "11:00")
        let floating = DateComponents(year: 2026, month: 10, day: 21, hour: 8, minute: 30)
        XCTAssertEqual(ReminderMapping.due(from: floating, zone: ny).time, "08:30")
    }

    func testMinutePrecision() {
        XCTAssertEqual(ReminderMapping.minuteTime("09:30:15"), "09:30")
        XCTAssertEqual(rv("x", date: "2026-10-21", time: "09:30:00").due_time, "09:30")
        XCTAssertNil(rv("x", date: nil, time: "09:30").due_time, "a time needs a date")
    }

    func testDueAlarmInstant() {
        let timed = ReminderMapping.components(date: "2026-10-21", time: "09:00", zone: ny)
        XCTAssertEqual(ReminderMapping.instant(of: timed).map { ISODate.string($0, timeZone: ny) }, "2026-10-21T09:00:00-04:00")
        XCTAssertNil(ReminderMapping.instant(of: ReminderMapping.components(date: "2026-10-21", time: nil)))
    }
}

// MARK: - wire

final class ReminderWireTests: XCTestCase {
    func testSnapshotKeysMatchTheContractWithExplicitNulls() throws {
        let rec = ReminderRecord(localId: "r1", externalId: nil, listId: "L-1", values: rv("Buy milk"))
        let body = RemindersBody(lists: [ReminderListInfo(ReminderListRecord(id: "L-1", title: "Groceries"))], default_list_id: nil,
                                 reminders: [ReminderInfo(rec)])
        let payload = try PayloadEncoder.encode(stream: .reminders, body: body, host: nil, collectedAt: t0)
        let obj = try JSONSerialization.jsonObject(with: payload.json) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["lists", "default_list_id", "reminders", "collected_at", "host"])
        XCTAssertTrue(obj["default_list_id"] is NSNull)
        XCTAssertTrue(obj["host"] is NSNull, "host null is sent as null")
        let r = (obj["reminders"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(r.keys), ["external_id", "local_id", "list_id", "title", "notes", "due_date", "due_time", "priority",
                                     "completed", "completed_at", "url", "created_at", "modified_at"])
        for key in ["external_id", "due_date", "due_time", "priority", "completed_at", "url", "created_at", "modified_at"] {
            XCTAssertTrue(r[key] is NSNull, key)
        }
        XCTAssertEqual(r["notes"] as? String, "")
        let l = (obj["lists"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(l.keys), ["id", "title", "color", "account", "account_type", "writable"])
        XCTAssertFalse(String(decoding: payload.json, as: UTF8.self).contains("organizer_"), "no Organizer-list keys")
    }

    func testOpDecodingKeepsWhichKeysWereSent() throws {
        let json = #"""
        {"ops": [{"id": 4, "reminder_id": 9, "kind": "update", "external_id": "ext-r1", "local_id": "r1",
                  "fields": {"title": "New", "due_date": null, "due_time": null},
                  "base": {"title": "Old", "due_date": "2026-10-21", "due_time": "09:00"},
                  "queued_at": "2026-10-19T12:00:00.123456+00:00"}], "server_time": "2026-10-19T12:00:05Z"}
        """#
        let op = try JSONCoding.decoder().decode(ReminderOpsResponse.self, from: Data(json.utf8)).ops[0]
        XCTAssertEqual(op.fields.present, ["title", "due_date", "due_time"])
        XCTAssertEqual(op.fields.valueFields, [.title, .due])
        XCTAssertFalse(op.fields.has(.priority))
        XCTAssertEqual(op.fields.applied(to: rv("Old", date: "2026-10-21", time: "09:00")), rv("New"))
        XCTAssertEqual(op.queued_at.timeIntervalSince1970, ISODate.parse("2026-10-19T12:00:00.123Z")!.timeIntervalSince1970, accuracy: 0.001,
                       "Python's microseconds parse")
    }

    func testCompleteAndCreateOpsDecodeWithoutFieldsOrBase() throws {
        let json = #"""
        {"ops": [{"id": 1, "reminder_id": 2, "kind": "complete", "external_id": null, "local_id": "r1",
                  "fields": {}, "base": {"completed": false}, "queued_at": "2026-10-19T12:00:00Z"},
                 {"id": 2, "reminder_id": 3, "kind": "create", "external_id": null, "local_id": null,
                  "fields": {"title": "Call the dentist", "list_id": "L-errands"}, "base": null, "queued_at": "2026-10-19T12:00:00Z"},
                 {"id": 3, "reminder_id": 4, "kind": "uncomplete", "queued_at": "2026-10-19T12:00:00Z"}]}
        """#
        let ops = try JSONCoding.decoder().decode(ReminderOpsResponse.self, from: Data(json.utf8)).ops
        XCTAssertEqual(ops.map(\.kind), ["complete", "create", "uncomplete"])
        XCTAssertEqual(ops[0].base.completed, false)
        XCTAssertEqual(ops[1].base.present, [])
        XCTAssertEqual(ops[1].fields.list_id, "L-errands")
        XCTAssertEqual(ops[2].fields.present, [])
    }

    func testAckEncodingUsesProviderNames() throws {
        let failure = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(OpAck.failure("nope"))) as! [String: Any]
        XCTAssertEqual(Set(failure.keys), ["ok", "external_id", "local_id", "error", "conflicts", "instance_id"])
        XCTAssertEqual(failure["ok"] as? Bool, false)
        XCTAssertEqual(failure["error"] as? String, "nope")
        XCTAssertTrue(failure["external_id"] is NSNull)
        XCTAssertEqual((failure["conflicts"] as? [Any])?.count, 0)

        let ack = OpAck.success(conflicts: [OpConflict(field: .title, kept: .provider, provider: "Buy oat milk", organizer: nil)])
        let obj = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(ack)) as! [String: Any]
        XCTAssertTrue(obj["error"] is NSNull)
        let conflict = (obj["conflicts"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(conflict.keys), ["field", "kept", "provider_value", "organizer_value"])
        XCTAssertEqual(conflict["kept"] as? String, "provider")
        XCTAssertEqual(conflict["provider_value"] as? String, "Buy oat milk")
        XCTAssertTrue(conflict["organizer_value"] is NSNull)
        XCTAssertEqual(ConflictWinner.organizer.rawValue, "organizer")
    }
}

// MARK: - ops

final class ReminderOpsApplierTests: XCTestCase {
    func applier(_ store: FakeReminderStore, state: RemindersState = RemindersState()) -> ReminderOpsApplier {
        ReminderOpsApplier(store: store, state: state)
    }

    func op(_ id: Int, _ kind: String, reminder: Int = 1, ext: String? = "ext-r1", local: String? = "r1",
            fields: OpFields = OpFields(), base: OpFields = OpFields(), queued: Date = t0) -> ReminderOp {
        ReminderOp(id: id, reminder_id: reminder, kind: kind, external_id: ext, local_id: local, fields: fields, base: base, queued_at: queued)
    }

    @discardableResult
    func okAck(_ outcome: ReminderOpsApplier.Outcome, file: StaticString = #filePath, line: UInt = #line) -> OpAck? {
        guard case .ack(let a) = outcome else { XCTFail("expected an ack, got \(outcome)", file: file, line: line); return nil }
        XCTAssertTrue(a.ok, a.error ?? "", file: file, line: line)
        return a
    }

    func failAck(_ outcome: ReminderOpsApplier.Outcome, file: StaticString = #filePath, line: UInt = #line) -> OpAck? {
        guard case .ack(let a) = outcome else { XCTFail("expected an ack, got \(outcome)", file: file, line: line); return nil }
        XCTAssertFalse(a.ok, file: file, line: line)
        return a
    }

    func testCreateInTheDefaultList() {
        let store = makeStore()
        let a = applier(store)
        let fields = OpFields(present: ["title", "notes", "due_date", "due_time", "priority", "list_id"], title: "Call the dentist", notes: "",
                              due_date: "2026-10-23", due_time: "17:00", priority: 2, list_id: nil)
        let ack = okAck(a.apply(op(1, "create", reminder: 9, ext: nil, local: nil, fields: fields)))
        let made = store.items[ack?.local_id ?? ""]
        XCTAssertEqual(made?.listId, "L-groceries")
        XCTAssertEqual(made?.values, rv("Call the dentist", date: "2026-10-23", time: "17:00", priority: 2))
        XCTAssertEqual(ack?.external_id, made?.externalId)
        XCTAssertEqual(a.state.created(op: 1)?.local_id, made?.localId)
    }

    func testARetriedCreateIsAckedAgainNotDuplicated() {
        let store = makeStore()
        let first = applier(store)
        let fields = OpFields(present: ["title", "list_id"], title: "Buy stamps", list_id: "L-errands")
        let a1 = okAck(first.apply(op(1, "create", reminder: 9, ext: nil, local: nil, fields: fields)))
        // The ack was lost: the op comes back in the next batch, with the state saved before the ack.
        let second = applier(store, state: first.state)
        let a2 = okAck(second.apply(op(1, "create", reminder: 9, ext: nil, local: nil, fields: fields)))
        XCTAssertEqual(a1, a2)
        XCTAssertEqual(store.writes, ["create L-errands Buy stamps"])
    }

    func testCreateRefusesReadOnlyAndMissingLists() {
        let store = makeStore()
        for list in ["L-shared", "L-missing"] {
            _ = failAck(applier(store).apply(op(1, "create", reminder: 9, ext: nil, local: nil,
                                                 fields: OpFields(present: ["title", "list_id"], title: "X", list_id: list))))
        }
        store.defaultId = nil
        let noDefault = failAck(applier(store).apply(op(2, "create", reminder: 9, ext: nil, local: nil,
                                                         fields: OpFields(present: ["title"], title: "X"))))
        XCTAssertTrue(noDefault?.error?.contains("default list") ?? false)
        XCTAssertEqual(store.writes, [])
    }

    func testUpdateAppliesWhatReminderStillHoldsAsBase() {
        let store = makeStore()
        let ack = okAck(applier(store).apply(op(1, "update", fields: OpFields(present: ["title", "priority"], title: "Buy milk x2", priority: 1),
                                                base: OpFields(present: ["title", "priority"], title: "Buy milk", priority: nil))))
        XCTAssertEqual(ack?.conflicts, [])
        XCTAssertEqual(store.items["r1"]?.values, rv("Buy milk x2", priority: 1))
    }

    func testConflictProviderNewerKeepsReminders() {
        let store = makeStore()
        store.items["r1"]?.values.title = "Buy milk (phone)"
        store.items["r1"]?.modifiedAt = t0.addingTimeInterval(100)
        let ack = okAck(applier(store).apply(op(1, "update", fields: OpFields(present: ["title"], title: "Buy milk x2"),
                                                base: OpFields(present: ["title"], title: "Buy milk"), queued: t0.addingTimeInterval(50))))
        XCTAssertEqual(ack?.conflicts, [OpConflict(field: .title, kept: .provider, provider: "Buy milk (phone)", organizer: "Buy milk x2")])
        XCTAssertEqual(ack?.conflicts.first?.kept, "provider")
        XCTAssertEqual(store.items["r1"]?.values.title, "Buy milk (phone)")
        XCTAssertEqual(store.writes, [])
    }

    func testConflictOrganizerNewerApplies() {
        let store = makeStore()
        store.items["r1"]?.values.title = "Buy milk (phone)"
        store.items["r1"]?.modifiedAt = t0.addingTimeInterval(10)
        let ack = okAck(applier(store).apply(op(1, "update", fields: OpFields(present: ["title"], title: "Buy milk x2"),
                                                base: OpFields(present: ["title"], title: "Buy milk"), queued: t0.addingTimeInterval(50))))
        XCTAssertEqual(ack?.conflicts.map(\.kept), ["organizer"])
        XCTAssertEqual(ack?.conflicts.first?.provider_value, "Buy milk (phone)")
        XCTAssertEqual(ack?.conflicts.first?.organizer_value, "Buy milk x2")
        XCTAssertEqual(store.items["r1"]?.values.title, "Buy milk x2")
    }

    func testDifferentFieldsMergeWithoutConflict() {
        let store = makeStore()
        store.items["r1"]?.values.notes = "phone note"
        store.items["r1"]?.modifiedAt = t0.addingTimeInterval(100)
        let ack = okAck(applier(store).apply(op(1, "update", fields: OpFields(present: ["title"], title: "Buy milk x2"),
                                                base: OpFields(present: ["title"], title: "Buy milk"), queued: t0.addingTimeInterval(50))))
        XCTAssertEqual(ack?.conflicts, [])
        XCTAssertEqual(store.items["r1"]?.values, rv("Buy milk x2", notes: "phone note"))
    }

    func testDueTravelsAsOneFieldAndConflictsAsOne() {
        let store = makeStore()
        store.items["r1"]?.values = rv("Buy milk", date: "2026-10-22", time: "10:00")
        store.items["r1"]?.modifiedAt = t0.addingTimeInterval(100)
        let ack = okAck(applier(store).apply(op(1, "update", fields: OpFields(present: ["due_date", "due_time"], due_date: "2026-10-25", due_time: nil),
                                                base: OpFields(present: ["due_date", "due_time"], due_date: "2026-10-21", due_time: "09:00"),
                                                queued: t0.addingTimeInterval(50))))
        XCTAssertEqual(ack?.conflicts, [OpConflict(field: .due, kept: .provider, provider: "2026-10-22 10:00", organizer: "2026-10-25")])
        XCTAssertEqual(store.items["r1"]?.values.due_date, "2026-10-22")
    }

    func testReapplyingIsHarmless() {
        let store = makeStore()
        store.items["r1"]?.values.title = "Buy milk x2"
        okAck(applier(store).apply(op(1, "update", fields: OpFields(present: ["title"], title: "Buy milk x2"),
                                      base: OpFields(present: ["title"], title: "Buy milk"))))
        XCTAssertEqual(store.writes, [], "a field already at the op's value is not written")
    }

    func testMoveToAnotherList() {
        let store = makeStore()
        okAck(applier(store).apply(op(1, "update", fields: OpFields(present: ["list_id"], list_id: "L-errands"),
                                      base: OpFields(present: ["list_id"], list_id: "L-groceries"))))
        XCTAssertEqual(store.items["r1"]?.listId, "L-errands")
        for bad in ["L-shared", "L-missing"] {
            _ = failAck(applier(store).apply(op(2, "update", fields: OpFields(present: ["list_id"], list_id: bad))))
        }
        XCTAssertEqual(store.items["r1"]?.listId, "L-errands")
    }

    func testListMovedOnBothSidesProviderNewerStays() {
        let store = makeStore()
        store.items["r1"]?.listId = "L-errands"
        store.items["r1"]?.modifiedAt = t0.addingTimeInterval(100)
        let ack = okAck(applier(store).apply(op(1, "update", fields: OpFields(present: ["list_id"], list_id: "L-shared"),
                                                base: OpFields(present: ["list_id"], list_id: "L-groceries"), queued: t0.addingTimeInterval(50))))
        XCTAssertEqual(ack?.conflicts.map(\.field), ["list"])
        XCTAssertEqual(ack?.conflicts.map(\.kept), ["provider"])
        XCTAssertEqual(store.items["r1"]?.listId, "L-errands")
    }

    func testAReadOnlyListIsNeverWritten() {
        let store = makeStore()
        store.put(ReminderRecord(localId: "s1", externalId: "ext-s1", listId: "L-shared", values: rv("Shared task")))
        let a = failAck(applier(store).apply(op(1, "complete", ext: "ext-s1", local: "s1")))
        XCTAssertTrue(a?.error?.contains("read-only") ?? false)
        XCTAssertEqual(store.writes, [])
    }

    func testCompleteIsIdempotent() {
        let store = makeStore()
        let a = applier(store)
        okAck(a.apply(op(1, "complete"), now: t0 + 42))
        XCTAssertEqual(store.items["r1"]?.values.completed, true)
        XCTAssertEqual(store.items["r1"]?.completionDate, t0 + 42)
        okAck(a.apply(op(1, "complete")))
        XCTAssertEqual(store.writes.count, 1)
    }

    func testCompleteAlwaysAppliesEvenWhenRemindersIsNewer() {
        let store = makeStore()
        store.items["r1"]?.modifiedAt = t0.addingTimeInterval(500)
        okAck(applier(store).apply(op(1, "complete", queued: t0)))
        XCTAssertEqual(store.items["r1"]?.values.completed, true)
    }

    func testUncompleteNeverUndoesANewerCompletion() {
        let store = makeStore()
        store.items["r1"]?.values.completed = true
        store.items["r1"]?.completionDate = t0.addingTimeInterval(100)
        let kept = okAck(applier(store).apply(op(1, "uncomplete", queued: t0.addingTimeInterval(50))))
        XCTAssertEqual(kept?.conflicts, [OpConflict(field: .completed, kept: .provider, provider: "true", organizer: "false")])
        XCTAssertEqual(store.items["r1"]?.values.completed, true)

        store.items["r1"]?.completionDate = t0.addingTimeInterval(10)
        okAck(applier(store).apply(op(2, "uncomplete", queued: t0.addingTimeInterval(50))))
        XCTAssertEqual(store.items["r1"]?.values.completed, false)
    }

    func testTargetIsFoundByExternalIdThenLocalId() {
        let store = makeStore()
        okAck(applier(store).apply(op(1, "complete", ext: "ext-r1", local: "stale-local")))
        XCTAssertEqual(store.items["r1"]?.values.completed, true)
        store.items["r1"]?.values.completed = false
        okAck(applier(store).apply(op(2, "complete", ext: "unknown-ext", local: "r1")))
        XCTAssertEqual(store.items["r1"]?.values.completed, true)
    }

    func testAMissingReminderFailsAndNothingIsDeleted() {
        let store = makeStore()
        _ = failAck(applier(store).apply(op(1, "complete", ext: "gone", local: "gone")))
        _ = failAck(applier(store).apply(op(2, "delete")))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.writes, [])
    }

    func testAnOpRightAfterItsCreateFindsTheNewReminder() {
        let store = makeStore()
        let a = applier(store)
        okAck(a.apply(op(1, "create", reminder: 9, ext: nil, local: nil, fields: OpFields(present: ["title"], title: "Stamps"))))
        okAck(a.apply(op(2, "complete", reminder: 9, ext: nil, local: nil)))
        XCTAssertEqual(store.items.values.first { $0.values.title == "Stamps" }?.values.completed, true)
        // Without its create in the batch, an unconfirmed reminder waits.
        XCTAssertEqual(applier(store).apply(op(3, "complete", reminder: 10, ext: nil, local: nil)),
                       .later("waiting for the reminder's create"))
    }
}

// MARK: - collector

final class RemindersCollectorTests: XCTestCase {
    func testEveryListAndRecentCompletionsAreSent() async throws {
        let store = makeStore()
        store.put(ReminderRecord(localId: "d-new", externalId: nil, listId: "L-errands", values: rv("Done lately", completed: true),
                                 completionDate: t0 - 5 * 86_400))
        store.put(ReminderRecord(localId: "d-old", externalId: nil, listId: "L-errands", values: rv("Done long ago", completed: true),
                                 completionDate: t0 - 60 * 86_400))
        store.put(ReminderRecord(localId: "s1", externalId: nil, listId: "L-shared", values: rv("Shared task")))
        let body = try await RemindersCollector(store: store, completedDays: 30).collect(now: t0)
        XCTAssertEqual(body.lists.map(\.id), ["L-errands", "L-groceries", "L-shared"])
        XCTAssertEqual(body.lists.first { $0.id == "L-shared" }?.writable, false)
        XCTAssertEqual(Set(body.reminders.map(\.local_id)), ["r1", "d-new", "s1"])
        XCTAssertEqual(body.default_list_id, "L-groceries")
    }

    func testADefaultListThatIsNotListedIsNull() async throws {
        let store = makeStore()
        store.defaultId = "L-elsewhere"
        let body = try await RemindersCollector(store: store, completedDays: 30).collect(now: t0)
        XCTAssertNil(body.default_list_id)
    }
}

// MARK: - the ops step against a fake server

final class FakeRemindersServer: RemindersServer {
    var ops: [ReminderOp]? = []
    var acks: [(Int, OpAck)] = []
    var withdrawn: Set<Int> = []
    var failAcksFrom: Int?

    func fetchReminderOps() async throws -> [ReminderOp]? { ops }

    func ackReminderOp(_ id: Int, _ ack: OpAck) async throws -> Bool {
        if let from = failAcksFrom, id >= from { throw PushError.transport("offline") }
        acks.append((id, ack))
        ops?.removeAll { $0.id == id }
        return !withdrawn.contains(id)
    }
}

final class RemindersSyncTests: XCTestCase {
    var dir: URL!

    override func setUp() { dir = tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeSync(_ store: FakeReminderStore) -> RemindersSync {
        RemindersSync(store: store, completedDays: 30, statePath: dir.appendingPathComponent("reminders.json").path)
    }

    func testOpsAreAppliedAndAckedInOrder() async {
        let store = makeStore()
        let server = FakeRemindersServer()
        server.ops = [
            ReminderOp(id: 1, reminder_id: 9, kind: "create", fields: OpFields(present: ["title"], title: "Stamps"), queued_at: t0),
            ReminderOp(id: 2, reminder_id: 9, kind: "complete", queued_at: t0),
            ReminderOp(id: 3, reminder_id: 1, kind: "complete", external_id: "ext-r1", local_id: "r1", queued_at: t0),
        ]
        let r = await makeSync(store).applyOps(server: server, now: t0)
        XCTAssertEqual(server.acks.map(\.0), [1, 2, 3])
        XCTAssertTrue(server.acks.allSatisfy { $0.1.ok })
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.summary, "ops 3: applied 3, failed 0, later 0")
        XCTAssertEqual(store.items["r1"]?.values.completed, true)
    }

    func testALostAckStopsTheBatchAndTheRetryDoesNotDuplicate() async {
        let store = makeStore()
        let server = FakeRemindersServer()
        server.ops = [
            ReminderOp(id: 5, reminder_id: 9, kind: "create", fields: OpFields(present: ["title"], title: "Stamps"), queued_at: t0),
            ReminderOp(id: 6, reminder_id: 1, kind: "complete", external_id: "ext-r1", local_id: "r1", queued_at: t0),
        ]
        server.failAcksFrom = 5
        let sync = makeSync(store)
        let first = await sync.applyOps(server: server, now: t0)
        XCTAssertTrue(first.failed)
        XCTAssertEqual(store.items["r1"]?.values.completed, false, "the batch stopped at the failed ack")

        // A new process (state reloaded from disk) retries.
        server.failAcksFrom = nil
        _ = await makeSync(store).applyOps(server: server, now: t0)
        XCTAssertEqual(store.writes.filter { $0.hasPrefix("create") }.count, 1)
        XCTAssertEqual(server.acks.map(\.0), [5, 6])
        XCTAssertEqual(server.acks[0].1.local_id, store.items.values.first { $0.values.title == "Stamps" }?.localId)
    }

    func testAWithdrawnOpIsDropped() async {
        let store = makeStore()
        let server = FakeRemindersServer()
        server.ops = [ReminderOp(id: 7, reminder_id: 1, kind: "complete", external_id: "ext-r1", local_id: "r1", queued_at: t0)]
        server.withdrawn = [7]
        let r = await makeSync(store).applyOps(server: server, now: t0)
        XCTAssertEqual(r.summary, "ops 1: applied 1, failed 0, later 0, withdrawn 1")
        XCTAssertFalse(r.failed)
    }

    func testNoEndpointMeansNothingToDo() async {
        let store = makeStore()
        let server = FakeRemindersServer()
        server.ops = nil
        let r = await makeSync(store).applyOps(server: server, now: t0)
        XCTAssertFalse(r.failed || r.changed)
        XCTAssertEqual(store.writes, [])
    }

    func testCreatedOpsArePrunedAfterAWeek() {
        var state = RemindersState(created_ops: [1: .init(local_id: "a", external_id: nil, at: t0 - 8 * 86_400),
                                                 2: .init(local_id: "b", external_id: nil, at: t0 - 86_400)])
        state.prune(now: t0)
        XCTAssertNil(state.created(op: 1))
        XCTAssertEqual(state.created(op: 2)?.local_id, "b")
        let path = dir.appendingPathComponent("reminders.json").path
        state.save(path: path)
        XCTAssertEqual(RemindersState.load(path: path), state)
    }
}
