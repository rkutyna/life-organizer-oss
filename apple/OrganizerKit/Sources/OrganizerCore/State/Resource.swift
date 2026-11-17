import Foundation
import Observation
import OrganizerAPI

/// One read from the API, kept on screen: the store pattern's building block.
///
/// It starts with the last good copy from the disk cache (so a screen has data at once, even
/// offline), and `refresh()` replaces it from the network. A failed refresh keeps the value and
/// records the error, which the freshness badge shows. Stores hold one `Resource` per read:
///
///     @MainActor @Observable final class RemindersStore {
///         let lists: Resource<[ReminderListOut]>
///         init(client: OrganizerClient) {
///             lists = Resource(API.Reminders.reminderLists(), client: client)
///         }
///     }
///
/// For an optimistic write, change the value with `modify`, send the request, and on failure
/// put the previous value back with `restore`.
@MainActor
@Observable
public final class Resource<Value: Decodable & Sendable> {
    public private(set) var state: Loadable<Value>

    @ObservationIgnored public let endpoint: Endpoint<Value>
    @ObservationIgnored private let client: OrganizerClient
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    public init(_ endpoint: Endpoint<Value>, client: OrganizerClient) {
        self.endpoint = endpoint
        self.client = client
        if let cached = client.cached(endpoint) {
            state = Loadable(value: cached.value, fetchedAt: cached.fetchedAt, isCached: true)
        } else {
            state = Loadable()
        }
    }

    /// A resource with a fixed value and no network, for previews and tests.
    public init(preview value: Value?, fetchedAt: Date? = Date(), error: APIError? = nil, client: OrganizerClient) {
        self.endpoint = Endpoint(method: .get, path: "/preview")
        self.client = client
        state = Loadable(value: value, fetchedAt: value == nil ? nil : fetchedAt, error: error)
    }

    public var value: Value? { state.value }

    /// Fetches now. Calls made while one is running wait for it instead of sending another.
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.load() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Refreshes unless a copy younger than `maxAge` is on screen (a tab switch, not a pull).
    public func refreshIfStale(maxAge: TimeInterval = 30) async {
        if let fetchedAt = state.fetchedAt, !state.isCached, Date().timeIntervalSince(fetchedAt) < maxAge {
            return
        }
        await refresh()
    }

    private func load() async {
        state.isRefreshing = true
        do {
            let fetched = try await client.fetch(endpoint)
            state = Loadable(value: fetched.value, fetchedAt: fetched.fetchedAt)
        } catch {
            state.isRefreshing = false
            if !Self.isCancellation(error) {
                state.error = APIError(error)
            }
        }
    }

    /// Changes the value on screen at once (an optimistic write) and returns the value before
    /// the change, to pass to `restore` if the request fails.
    @discardableResult
    public func modify(_ change: (inout Value) -> Void) -> Value? {
        let before = state.value
        if var value = state.value {
            change(&value)
            state.value = value
        }
        return before
    }

    /// Puts back a value `modify` returned (the write failed).
    public func restore(_ value: Value?) {
        state.value = value
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }
}
