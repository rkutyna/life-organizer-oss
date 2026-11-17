import Foundation

extension OrganizerClient {
    /// The unified calendar feed and its sources: `/api/calendar`.
    public var calendar: CalendarAPI { CalendarAPI(client: self) }
}

public struct CalendarAPI: Sendable {
    let client: OrganizerClient

    /// Every source's items overlapping [start, end), or only the listed source keys. The
    /// screens read through `Resource` (Features/Calendar), so the copy is kept; this is for
    /// one-off calls.
    public func items(from start: Date, to end: Date, sources: [String]? = nil) async throws -> CalendarResponse {
        try await client.send(API.Calendar.getCalendar(start: start, end: end, sources: sources?.joined(separator: ",")))
    }

    /// Every calendar source with its color, and its freshness where it is mirrored.
    public func sources() async throws -> [CalendarSourceOut] {
        try await client.send(API.Calendar.listSources())
    }
}
