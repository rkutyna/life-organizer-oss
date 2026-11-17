import CoreGraphics
import EventKit
import Foundation

/// `CalendarSource` over EventKit. Reads only; never saves or removes anything.
public final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore) { self.store = store }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map { cal in
            CalendarInfo(id: cal.calendarIdentifier, title: cal.title, color: EventKitMapping.hex(cal.cgColor),
                         account: cal.source?.title, account_type: cal.source.map { EventKitMapping.sourceType($0.sourceType) })
        }
    }

    public func events(from start: Date, to end: Date) -> [CalendarEvent] {
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return [] }
        // EventKit only matches within a four-year span per predicate; query year by year to
        // stay well inside it whatever the configured window.
        var out: [CalendarEvent] = []
        var chunkStart = start
        while chunkStart < end {
            let chunkEnd = min(Calendar.current.date(byAdding: .year, value: 1, to: chunkStart)!, end)
            let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: calendars)
            out.append(contentsOf: store.events(matching: predicate).compactMap(Self.map))
            chunkStart = chunkEnd
        }
        return out
    }

    static func map(_ ev: EKEvent) -> CalendarEvent? {
        guard let start = ev.startDate, let end = ev.endDate, let cal = ev.calendar else { return nil }
        let external = ev.calendarItemExternalIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let uid = external ?? ev.calendarItemIdentifier
        guard !uid.isEmpty else { return nil }
        return CalendarEvent(
            uid: uid,
            calendar_id: cal.calendarIdentifier,
            title: ev.title ?? "",
            start: start,
            end: end,
            all_day: ev.isAllDay,
            location: ev.location.flatMap { $0.isEmpty ? nil : $0 },
            url: ev.url?.absoluteString,
            occurrence_start: ev.occurrenceDate ?? start,
            status: EventKitMapping.status(ev.status)
        )
    }
}

/// EventKit enums and colors in the wire's spelling.
public enum EventKitMapping {
    static func status(_ s: EKEventStatus) -> String {
        switch s {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    static func sourceType(_ t: EKSourceType) -> String {
        switch t {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "mobileme"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    /// `#RRGGBB` in sRGB.
    static func hex(_ color: CGColor?) -> String? {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(comps[0]), byte(comps[1]), byte(comps[2]))
    }
}
