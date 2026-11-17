import OrganizerAPI
import OrganizerCore
import SwiftUI

/// "as of 12 minutes ago": shown when the data on screen is an old copy or the last refresh
/// failed (DESIGN §1, "a copy shows its age"). `LoadingScaffold` places it for you; use it
/// directly only in custom layouts and widgets.
///
///     FreshnessBadge(fetchedAt: state.fetchedAt, error: state.error, isRefreshing: state.isRefreshing)
public struct FreshnessBadge: View {
    let fetchedAt: Date?
    let error: APIError?
    let isRefreshing: Bool
    let retry: (() async -> Void)?

    public init(fetchedAt: Date?, error: APIError? = nil, isRefreshing: Bool = false,
                retry: (() async -> Void)? = nil) {
        self.fetchedAt = fetchedAt
        self.error = error
        self.isRefreshing = isRefreshing
        self.retry = retry
    }

    public init(status: LoadStatus, retry: (() async -> Void)? = nil) {
        self.init(fetchedAt: status.fetchedAt, error: status.error, isRefreshing: status.isRefreshing, retry: retry)
    }

    public var body: some View {
        Group {
            if let retry {
                Button { Task { await retry() } } label: { label }
                    .buttonStyle(.plain)
                    .help(error?.message ?? "Refresh")
            } else {
                label
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(error.map { "Last refresh failed: \($0.message)" } ?? "")
    }

    private var label: some View {
        HStack(spacing: 5) {
            if isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: error == nil ? "clock" : (error?.isOffline == true ? "wifi.slash" : "exclamationmark.arrow.circlepath"))
                    .imageScale(.small)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(text(now: context.date))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        // Not `.secondary`: on the material it fell below the audit's contrast (DESIGN §1 wants
        // the age readable).
        .foregroundStyle(error == nil ? Palette.mutedForeground : Palette.status(.stale))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    private func text(now: Date) -> String {
        guard let fetchedAt else { return error == nil ? "Not loaded yet" : "Couldn't load" }
        let age = Freshness.age(of: fetchedAt, now: now)
        if let error {
            return error.isOffline ? "Offline · as of \(age)" : "Couldn't refresh · as of \(age)"
        }
        return "as of \(age)"
    }
}

/// The combined state of the reads behind one screen, for `LoadingScaffold` and
/// `FreshnessBadge`. A screen built from several reads is as old as its oldest part.
public struct LoadStatus: Sendable {
    public var hasValue: Bool
    public var isRefreshing: Bool
    public var error: APIError?
    public var fetchedAt: Date?

    public init(hasValue: Bool, isRefreshing: Bool = false, error: APIError? = nil, fetchedAt: Date? = nil) {
        self.hasValue = hasValue
        self.isRefreshing = isRefreshing
        self.error = error
        self.fetchedAt = fetchedAt
    }

    /// One read's status.
    public init<Value>(_ state: Loadable<Value>) {
        self.init(hasValue: state.value != nil, isRefreshing: state.isRefreshing, error: state.error,
                  fetchedAt: state.fetchedAt)
    }

    /// The screen needs `primary` to show anything; `secondary` reads only add to it (their
    /// failure shows as staleness, not as an error screen).
    public init(primary: LoadStatus, secondary: [LoadStatus] = []) {
        let all = [primary] + secondary
        self.init(
            hasValue: primary.hasValue,
            isRefreshing: all.contains { $0.isRefreshing },
            error: primary.error ?? secondary.compactMap(\.error).first,
            fetchedAt: Freshness.oldest(all.filter(\.hasValue).map(\.fetchedAt))
        )
    }

    public func showsFreshness(now: Date = Date(), threshold: TimeInterval = Freshness.defaultThreshold) -> Bool {
        hasValue && Freshness.showsBadge(fetchedAt: fetchedAt, refreshFailed: error != nil, now: now, threshold: threshold)
    }
}

extension Loadable {
    public var status: LoadStatus { LoadStatus(self) }
}
