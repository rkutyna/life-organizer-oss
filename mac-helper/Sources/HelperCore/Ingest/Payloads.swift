import Foundation

// Wire types for `POST /api/ingest/calendar`. Property names ARE the JSON keys, spelled exactly
// as the server's `CalendarPushIn` model (server/app/modules/calendar_ext/ingest.py), so a
// rename here is a contract change. Every nil optional is sent as JSON null (`NullCodable`).
// The envelope fields `collected_at` and `host` are added by `PayloadEncoder`.

public struct CalendarBody: Codable, Equatable, Sendable {
    public var source = "eventkit"
    public var window: Window
    public var calendars: [CalendarInfo]
    public var events: [CalendarEvent]

    public init(window: Window, calendars: [CalendarInfo], events: [CalendarEvent]) {
        self.window = window; self.calendars = calendars; self.events = events
    }

    public struct Window: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date
        public init(start: Date, end: Date) { self.start = start; self.end = end }
    }
}

public struct CalendarInfo: Codable, Equatable, Sendable {
    /// `EKCalendar.calendarIdentifier`.
    public var id: String
    public var title: String
    /// `#RRGGBB`.
    @NullCodable public var color: String?
    /// `EKSource.title`, e.g. iCloud.
    @NullCodable public var account: String?
    /// caldav | mobileme | local | exchange | subscribed | birthdays | unknown.
    @NullCodable public var account_type: String?

    public init(id: String, title: String, color: String?, account: String?, account_type: String?) {
        self.id = id; self.title = title; self.color = color; self.account = account; self.account_type = account_type
    }
}

public struct CalendarEvent: Codable, Equatable, Sendable {
    /// `calendarItemExternalIdentifier`, else `calendarItemIdentifier`.
    public var uid: String
    public var calendar_id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var all_day: Bool
    @NullCodable public var location: String?
    @NullCodable public var url: String?
    /// The original start of this occurrence (recurring events are expanded).
    public var occurrence_start: Date
    /// none | confirmed | tentative | canceled | unknown.
    public var status: String

    public init(uid: String, calendar_id: String, title: String, start: Date, end: Date, all_day: Bool,
                location: String?, url: String?, occurrence_start: Date, status: String) {
        self.uid = uid; self.calendar_id = calendar_id; self.title = title; self.start = start; self.end = end
        self.all_day = all_day; self.location = location; self.url = url
        self.occurrence_start = occurrence_start; self.status = status
    }
}
