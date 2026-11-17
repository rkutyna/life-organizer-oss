import Foundation
import OrganizerAPI

/// What a screen knows about one piece of server data: the value (maybe a cached copy), when
/// it was fetched, whether a refresh is running, and the last refresh's error.
///
/// A value and an error can both be set: that is a cached copy shown while the server is
/// unreachable, and the freshness badge says so.
public struct Loadable<Value: Sendable>: Sendable {
    public var value: Value?
    public var fetchedAt: Date?
    public var isRefreshing: Bool
    /// The last refresh's failure; cleared by the next success.
    public var error: APIError?
    /// The value came from the disk cache and has not been refreshed since.
    public var isCached: Bool

    public init(value: Value? = nil, fetchedAt: Date? = nil, isRefreshing: Bool = false,
                error: APIError? = nil, isCached: Bool = false) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.isRefreshing = isRefreshing
        self.error = error
        self.isCached = isCached
    }

    public enum Phase: Sendable {
        /// Nothing to show yet and a load is running (or about to).
        case loading
        /// Nothing to show and the load failed.
        case failed(APIError)
        /// Something to show (fresh or cached).
        case content
    }

    public var phase: Phase {
        if value != nil { return .content }
        if let error, !isRefreshing { return .failed(error) }
        return .loading
    }

    /// Whether to show the "as of" badge (see `Freshness`).
    public func showsFreshness(now: Date = Date(), threshold: TimeInterval = Freshness.defaultThreshold) -> Bool {
        value != nil && Freshness.showsBadge(fetchedAt: fetchedAt, refreshFailed: error != nil,
                                             now: now, threshold: threshold)
    }

    /// The same state with the value transformed (for derived views).
    public func map<T: Sendable>(_ transform: (Value) -> T) -> Loadable<T> {
        Loadable<T>(value: value.map(transform), fetchedAt: fetchedAt, isRefreshing: isRefreshing,
                    error: error, isCached: isCached)
    }
}

/// When a copy on screen must say how old it is ("a copy shows its age").
public enum Freshness {
    /// Data younger than this is fresh enough to show without a badge.
    public static let defaultThreshold: TimeInterval = 5 * 60

    /// Show "as of <time>" when the copy is older than `threshold`, or when the last refresh
    /// failed (so a cached copy is never mistaken for live data).
    public static func showsBadge(fetchedAt: Date?, refreshFailed: Bool, now: Date, threshold: TimeInterval) -> Bool {
        guard let fetchedAt else { return refreshFailed }
        return refreshFailed || now.timeIntervalSince(fetchedAt) > threshold
    }

    /// The oldest fetch time among several sources: a screen built from several reads is as
    /// old as its oldest part.
    public static func oldest(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.min()
    }

    /// How old a copy is at `now`, in words: "just now" (under 45 seconds), "12 minutes ago",
    /// "yesterday". The "as of" badge and every other freshness line say it the same way.
    /// Nonisolated, so pure helpers and tests off the main actor can use it.
    public static func age(of date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
