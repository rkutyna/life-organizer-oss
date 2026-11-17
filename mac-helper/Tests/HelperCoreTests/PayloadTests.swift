import XCTest
@testable import HelperCore

/// The calendar payload against the server's contract (server/app/modules/calendar_ext/ingest.py
/// and its test fixture tests/support.py: `push_body`, `ek_calendar`, `ek_event`).
final class CalendarPayloadTests: XCTestCase {
    // The keys the server fixture builds, copied from support.py.
    static let envelopeKeys: Set<String> = ["source", "window", "calendars", "events", "collected_at", "host"]
    static let windowKeys: Set<String> = ["start", "end"]
    static let calendarKeys: Set<String> = ["id", "title", "color", "account", "account_type"]
    static let eventKeys: Set<String> = ["uid", "calendar_id", "title", "start", "end", "all_day", "location", "url",
                                         "occurrence_start", "status"]

    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    func date(_ s: String) -> Date { ISODate.parse(s)! }

    func sampleBody() -> CalendarBody {
        CalendarBody(window: .init(start: date("2026-04-01T00:00:00+09:00"), end: date("2026-05-01T00:00:00+09:00")),
                     calendars: [CalendarInfo(id: "c1", title: "Work", color: "#3366CC", account: "iCloud", account_type: "caldav"),
                                 CalendarInfo(id: "c2", title: "Family", color: nil, account: nil, account_type: nil)],
                     events: [CalendarEvent(uid: "e1", calendar_id: "c1", title: "Dentist", start: date("2026-04-15T09:00:00+09:00"),
                                            end: date("2026-04-15T10:00:00+09:00"), all_day: false, location: nil, url: nil,
                                            occurrence_start: date("2026-04-15T09:00:00+09:00"), status: "confirmed")])
    }

    func testPayloadKeysMatchTheServerContract() throws {
        let payload = try PayloadEncoder.encode(stream: .calendar, body: sampleBody(), host: "test-mac", collectedAt: t0, timeZone: tokyo)
        let obj = try JSONSerialization.jsonObject(with: payload.json) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), Self.envelopeKeys)
        XCTAssertEqual(obj["source"] as? String, "eventkit")
        XCTAssertEqual(obj["host"] as? String, "test-mac")
        XCTAssertEqual(Set((obj["window"] as! [String: Any]).keys), Self.windowKeys)
        let cals = obj["calendars"] as! [[String: Any]]
        for c in cals { XCTAssertEqual(Set(c.keys), Self.calendarKeys) }
        XCTAssertTrue(cals[1]["color"] is NSNull, "optional fields are explicit nulls")
        XCTAssertTrue(cals[1]["account"] is NSNull)
        let event = (obj["events"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(event.keys), Self.eventKeys)
        XCTAssertTrue(event["location"] is NSNull)
        XCTAssertTrue(event["url"] is NSNull)
        XCTAssertEqual(event["all_day"] as? Bool, false)
        XCTAssertEqual(event["start"] as? String, "2026-04-15T09:00:00+09:00", "every time carries an offset")
        XCTAssertEqual((obj["window"] as! [String: Any])["start"] as? String, "2026-04-01T00:00:00+09:00")
    }

    /// Cross-check with the server's own fixture when this checkout has it.
    func testTheServerFixtureNamesTheSameKeys() throws {
        let support = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/app/modules/calendar_ext/tests/support.py")
        guard let text = try? String(contentsOf: support, encoding: .utf8) else {
            throw XCTSkip("server fixture not in this checkout")
        }
        for key in Self.envelopeKeys.union(Self.calendarKeys).union(Self.eventKeys) {
            XCTAssertTrue(text.contains("\"\(key)\":"), "support.py does not send \(key)")
        }
    }

    func testAllDayEventsTravelAsLocalMidnightsWithAnExclusiveEnd() throws {
        let cal = calendar(tokyo)
        // EventKit's shape: midnight to 23:59:59 of the last day.
        let raw = CalendarEvent(uid: "e-day", calendar_id: "c1", title: "Conference day", start: date("2026-04-15T00:00:00+09:00"),
                                end: date("2026-04-15T23:59:59+09:00"), all_day: true, location: nil, url: nil,
                                occurrence_start: date("2026-04-15T00:00:00+09:00"), status: "confirmed")
        let source = FakeCalendarSource(calendars: [CalendarInfo(id: "c1", title: "Work", color: nil, account: "iCloud", account_type: "caldav")],
                                        events: [raw])
        var config = HelperConfig.Calendar()
        config.past_days = 30
        config.future_days = 30
        let body = CalendarCollector(source: source, config: config, calendar: cal).collect(now: date("2026-04-10T12:00:00+09:00"))
        let payload = try PayloadEncoder.encode(stream: .calendar, body: body, host: nil, collectedAt: t0, timeZone: tokyo)
        let event = ((try JSONSerialization.jsonObject(with: payload.json) as! [String: Any])["events"] as! [[String: Any]])[0]
        XCTAssertEqual(event["start"] as? String, "2026-04-15T00:00:00+09:00")
        XCTAssertEqual(event["end"] as? String, "2026-04-16T00:00:00+09:00")
        XCTAssertEqual(event["occurrence_start"] as? String, "2026-04-15T00:00:00+09:00")
        XCTAssertEqual(event["all_day"] as? Bool, true)
    }

    func testAllDayNormalizationEdgeCases() {
        let cal = calendar(tokyo)
        func ev(_ s: String, _ e: String) -> CalendarEvent {
            CalendarEvent(uid: "u", calendar_id: "c", title: "", start: date(s), end: date(e), all_day: true, location: nil, url: nil,
                          occurrence_start: date(s), status: "none")
        }
        // Three days ending at 23:59:59 of the third.
        let multi = CalendarCollector.normalizeAllDay(ev("2026-04-15T00:00:00+09:00", "2026-04-17T23:59:59+09:00"), calendar: cal)
        XCTAssertEqual(ISODate.string(multi.end, timeZone: tokyo), "2026-04-18T00:00:00+09:00")
        // Already an exclusive midnight: kept.
        let exact = CalendarCollector.normalizeAllDay(ev("2026-04-15T00:00:00+09:00", "2026-04-16T00:00:00+09:00"), calendar: cal)
        XCTAssertEqual(ISODate.string(exact.end, timeZone: tokyo), "2026-04-16T00:00:00+09:00")
        // A zero-length all-day event still spans its day.
        let zero = CalendarCollector.normalizeAllDay(ev("2026-04-15T00:00:00+09:00", "2026-04-15T00:00:00+09:00"), calendar: cal)
        XCTAssertEqual(ISODate.string(zero.end, timeZone: tokyo), "2026-04-16T00:00:00+09:00")
        // Timed events are untouched.
        var timed = ev("2026-04-15T09:30:00+09:00", "2026-04-15T10:00:00+09:00")
        timed.all_day = false
        XCTAssertEqual(CalendarCollector.normalizeAllDay(timed, calendar: cal), timed)
    }

    func testCollectorSortsDedupesAndQueriesTheWindow() {
        let cal = calendar(TimeZone(identifier: "America/New_York")!)
        let a = CalendarEvent(uid: "b", calendar_id: "c1", title: "Later", start: date("2026-04-15T15:00:00Z"), end: date("2026-04-15T16:00:00Z"),
                              all_day: false, location: nil, url: nil, occurrence_start: date("2026-04-15T15:00:00Z"), status: "confirmed")
        let b = CalendarEvent(uid: "a", calendar_id: "c1", title: "Earlier", start: date("2026-04-15T13:00:00Z"), end: date("2026-04-15T14:00:00Z"),
                              all_day: false, location: "Room 1", url: "https://example.com/meet", occurrence_start: date("2026-04-15T13:00:00Z"),
                              status: "tentative")
        let source = FakeCalendarSource(calendars: [
            CalendarInfo(id: "c2", title: "Work", color: nil, account: "iCloud", account_type: "caldav"),
            CalendarInfo(id: "c1", title: "Home", color: nil, account: "iCloud", account_type: "caldav"),
        ], events: [a, b, a])
        let body = CalendarCollector(source: source, config: HelperConfig.Calendar(), calendar: cal).collect(now: date("2026-04-10T12:00:00Z"))
        XCTAssertEqual(body.events.map(\.uid), ["a", "b"], "sorted by start, duplicates dropped")
        XCTAssertEqual(body.calendars.map(\.title), ["Home", "Work"])
        XCTAssertEqual(source.queries.count, 1)
        XCTAssertEqual(source.queries[0].0, body.window.start)
        XCTAssertEqual(source.queries[0].1, body.window.end)
        XCTAssertLessThan(body.window.start, body.window.end)
    }

    func testCalendarWindowIsDayAligned() {
        let cal = calendar(TimeZone(identifier: "America/New_York")!)
        let now = date("2026-10-18T22:01:57Z")
        let w1 = CalendarCollector.window(now: now, pastDays: 365, futureDays: 365, calendar: cal)
        let w2 = CalendarCollector.window(now: now.addingTimeInterval(3600), pastDays: 365, futureDays: 365, calendar: cal)
        XCTAssertEqual(w1, w2)
        XCTAssertEqual(cal.component(.hour, from: w1.start), 0)
        XCTAssertLessThan(w1.start, now.addingTimeInterval(-364 * 86_400))
        XCTAssertGreaterThan(w1.end, now.addingTimeInterval(365 * 86_400))
    }
}

final class EncodingTests: XCTestCase {
    func testHashIgnoresCollectedAtButEnvelopeHasIt() throws {
        let body = RemindersBody(lists: [], default_list_id: nil, reminders: [])
        let p1 = try PayloadEncoder.encode(stream: .reminders, body: body, host: "mac", collectedAt: Date(timeIntervalSince1970: 1))
        let p2 = try PayloadEncoder.encode(stream: .reminders, body: body, host: "mac", collectedAt: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(p1.bodyHash, p2.bodyHash)
        XCTAssertNotEqual(p1.json, p2.json)
        let obj = try JSONSerialization.jsonObject(with: p1.json) as! [String: Any]
        XCTAssertEqual(obj["host"] as? String, "mac")
        XCTAssertNotNil(obj["collected_at"] as? String)
    }

    func testDatesAreISO8601WithAnOffset() {
        let s = ISODate.string(Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: -4 * 3600)!)
        XCTAssertEqual(s, "1969-12-31T20:00:00-04:00")
        XCTAssertEqual(ISODate.string(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!), "1970-01-01T00:00:00+00:00",
                       "UTC is spelled as an offset too")
        XCTAssertEqual(ISODate.parse(s), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ISODate.parse("2026-10-18T21:44:20.975Z")?.timeIntervalSince1970 ?? 0, 1_792_359_860.975, accuracy: 0.001)
        XCTAssertEqual(ISODate.trimFraction("2026-10-18T21:44:20.975123+00:00"), "2026-10-18T21:44:20.975+00:00")
        XCTAssertEqual(ISODate.trimFraction("2026-10-18T21:44:20+00:00"), "2026-10-18T21:44:20+00:00")
    }

    func testStreamGateChangeDetectionAndHeartbeat() {
        let gate = StreamGate(heartbeat: 900)
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(gate.shouldPush(.calendar, hash: "h1", now: start))
        // A failed push does not mark: still due.
        XCTAssertTrue(gate.shouldPush(.calendar, hash: "h1", now: start.addingTimeInterval(10)))
        gate.markPushed(.calendar, hash: "h1", at: start)
        XCTAssertFalse(gate.shouldPush(.calendar, hash: "h1", now: start.addingTimeInterval(10)))
        XCTAssertTrue(gate.shouldPush(.calendar, hash: "h2", now: start.addingTimeInterval(10)))
        XCTAssertTrue(gate.shouldPush(.calendar, hash: "h1", now: start.addingTimeInterval(901)), "heartbeat")
        XCTAssertTrue(gate.shouldPush(.reminders, hash: "h1", now: start), "streams are independent")
        XCTAssertTrue(StreamGate(heartbeat: 0).shouldPush(.calendar, hash: "h", now: start))
    }
}
