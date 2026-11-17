import Foundation
import OrganizerAPI
import Testing

@Suite("Wire formats")
struct WireFormatTests {
    // MARK: LocalDate / LocalTime

    @Test func localDateParsesAndFormats() throws {
        let day = try #require(LocalDate("2026-10-24"))
        #expect(day.year == 2026 && day.month == 10 && day.day == 24)
        #expect(day.string == "2026-10-24")
        #expect(LocalDate("2026-02-30") == nil)
        #expect(LocalDate("2026-1-5") == nil)
        #expect(LocalDate("tomorrow") == nil)
        #expect(LocalDate("2026-10-23")! < day)
    }

    @Test func localDateArithmeticInATimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let day = LocalDate(year: 2026, month: 10, day: 31)
        #expect(day.adding(days: 1, calendar: calendar) == LocalDate(year: 2026, month: 11, day: 1))
        // Across the DST change (Nov 1 2026 in New York).
        #expect(LocalDate(year: 2026, month: 11, day: 1).adding(days: 1, calendar: calendar) == LocalDate(year: 2026, month: 11, day: 2))
        #expect(day.days(until: LocalDate(year: 2026, month: 11, day: 7), calendar: calendar) == 7)
    }

    @Test func localTimeAcceptsServerAndClientForms() {
        #expect(LocalTime("15:00:00") == LocalTime(hour: 15, minute: 0))
        #expect(LocalTime("09:30") == LocalTime(hour: 9, minute: 30))
        #expect(LocalTime("9:30") == nil)
        #expect(LocalTime("24:00") == nil)
        #expect(LocalTime(hour: 7, minute: 5).string == "07:05")
    }

    // MARK: Datetimes

    @Test(arguments: [
        ("2026-10-24T04:25:37.903842Z", 1_792_815_937.903842),
        ("2026-10-24T04:25:37Z", 1_792_815_937.0),
        ("2026-10-24T00:25:37-04:00", 1_792_815_937.0),
        ("2026-10-24T04:25:37.5+00:00", 1_792_815_937.5),
        ("2026-10-24T04:25:37", 1_792_815_937.0),
        ("2026-10-24 04:25", 1_792_815_900.0),
    ])
    func parsesDateTimes(raw: String, epoch: Double) throws {
        let date = try #require(APIJSON.parseDateTime(raw))
        #expect(abs(date.timeIntervalSince1970 - epoch) < 0.000_01)
    }

    @Test(arguments: ["", "2026-10-24", "2026-10-24T25:00:00Z", "yesterday", "2026-10-24T04:25:37Zjunk"])
    func rejectsBadDateTimes(raw: String) {
        #expect(APIJSON.parseDateTime(raw) == nil)
    }

    @Test func dateTimeRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_792_815_937.25)
        let text = APIJSON.formatDateTime(date)
        #expect(text == "2026-10-24T04:25:37.250Z")
        #expect(APIJSON.parseDateTime(text) == date)
    }

    // MARK: Omittable

    @Test func patchBodySendsOnlyWhatIsSet() throws {
        let encoder = APIJSON.encoder()
        #expect(String(decoding: try encoder.encode(ReminderUpdate()), as: UTF8.self) == "{}")

        let clear = ReminderUpdate(dueDate: .null)
        #expect(String(decoding: try encoder.encode(clear), as: UTF8.self) == #"{"due_date":null}"#)

        let set = ReminderUpdate(title: .value("Call"), dueDate: .value(LocalDate("2026-10-24")!),
                             dueTime: .value(LocalTime(hour: 15, minute: 0)), priority: .orNull(nil))
        let json = String(decoding: try encoder.encode(set), as: UTF8.self)
        #expect(json == #"{"due_date":"2026-10-24","due_time":"15:00","priority":null,"title":"Call"}"#)
    }

    @Test func createBodyOmitsUnsetOptionals() throws {
        let body = ReminderCreate(title: "Buy milk", dueDate: .ifPresent(nil), priority: .ifPresent(2))
        let json = String(decoding: try APIJSON.encoder().encode(body), as: UTF8.self)
        #expect(json == #"{"priority":2,"title":"Buy milk"}"#)
    }

    @Test func omittableDecodesMissingAndNull() throws {
        let decoded = try APIJSON.decoder().decode(ReminderUpdate.self, from: Data(#"{"notes": "x", "due_date": null}"#.utf8))
        #expect(decoded.notes == .value("x"))
        #expect(decoded.dueDate == .null)
        #expect(decoded.title == .omitted)
    }

    // MARK: Endpoints

    @Test func endpointBuildsQueryAndCacheKey() {
        let endpoint = API.Reminders.listReminders(list: "work", includeCompleted: false)
        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/api/reminders")
        #expect(endpoint.query.map(\.name) == ["list", "include_completed"])
        #expect(endpoint.cacheKey == "GET /api/reminders?include_completed=false&list=work")
        #expect(endpoint.isRead)
        #expect(!API.Reminders.completeReminder(reminderId: 3).isRead)
        #expect(API.Reminders.completeReminder(reminderId: 3).path == "/api/reminders/3/complete")
    }

    @Test func mailIsNeverCached() {
        #expect(!API.Mail.readMessage(messageId: 3).isCacheable)
        #expect(!API.Mail.listMessages().isCacheable)
        #expect(API.Reminders.reminderLists().isCacheable)
    }

    @Test func pathSegmentsAreEncoded() {
        let endpoint = API.Reminders.getReminder(reminderId: 1)
        #expect(endpoint.path == "/api/reminders/1")
        #expect(Wire.segment("a b/c") == "a%20b%2Fc")
    }

    @Test func arrayQueryRepeats() {
        let endpoint = API.Jobs.listApplications(status: ["applied", "screen"])
        #expect(endpoint.query.filter { $0.name == "status" }.map(\.value) == ["applied", "screen"])
    }

    // MARK: Errors

    @Test func serverMessagesAreKept() {
        let conflict = APIError.fromResponse(status: 409, body: Data(#"{"detail": "the op was already applied in Apple Reminders"}"#.utf8))
        #expect(conflict == .server(status: 409, message: "the op was already applied in Apple Reminders"))
        #expect(conflict.isConflict)

        let validation = APIError.fromResponse(status: 422, body: Data(#"{"detail": [{"loc": ["body", "title"], "msg": "title is empty", "type": "value_error"}]}"#.utf8))
        #expect(validation.message == "title: title is empty")

        let bare = APIError.fromResponse(status: 500, body: Data("oops".utf8))
        #expect(bare.message.hasPrefix("500"))
    }

    @Test func offlineIsTransport() {
        let error = APIError(URLError(.notConnectedToInternet))
        #expect(error.isOffline)
        #expect(error.message == "You're offline.")
    }

    @Test func authFailuresAreNamed() {
        #expect(APIError.server(status: 401, message: "invalid or revoked API token").isUnauthorized)
        #expect(APIError.server(status: 403, message: "this credential lacks the 'mail' scope").isForbidden)
    }
}
