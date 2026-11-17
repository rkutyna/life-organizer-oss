import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The screen scaffold every module uses: loading, error, empty, content, and freshness.
///
/// - Nothing to show yet: a spinner (first launch) or the error with Try Again.
/// - Something to show (fresh or cached): `content`, or `empty` when `isEmpty`.
/// - An old copy or a failed refresh: the "as of" badge above the content.
/// - Pull to refresh (iOS) runs `refresh`; the empty and error states scroll, so it works
///   there too.
///
///     LoadingScaffold(status: store.status, isEmpty: store.isEmpty, refresh: store.refresh) {
///         List { ... }
///     } empty: {
///         EmptyStateView("Nothing to do", systemImage: "checkmark.circle")
///     }
public struct LoadingScaffold<Content: View, Empty: View>: View {
    let status: LoadStatus
    let isEmpty: Bool
    let refresh: () async -> Void
    let content: Content
    let empty: Empty

    public init(
        status: LoadStatus,
        isEmpty: Bool = false,
        refresh: @escaping () async -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder empty: () -> Empty = { EmptyView() }
    ) {
        self.status = status
        self.isEmpty = isEmpty
        self.refresh = refresh
        self.content = content()
        self.empty = empty()
    }

    public var body: some View {
        Group {
            if status.hasValue {
                if isEmpty {
                    scrollable { empty }
                } else {
                    content
                }
            } else if let error = status.error, !status.isRefreshing {
                scrollable { ErrorStateView(error: error, retry: refresh) }
            } else {
                LoadingStateView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if status.showsFreshness() {
                FreshnessBadge(status: status, retry: refresh)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: status.showsFreshness())
        .refreshable { await refresh() }
        // View › Refresh (⌘R) on the Mac refreshes the screen on show: only a visible scaffold
        // offers it, so a tab in the background never answers.
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .focusedSceneValue(\.screenRefresh, isVisible ? ScreenRefreshAction(run: refresh) : nil)
    }

    @State private var isVisible = false

    /// A full-height scroll view, so pull to refresh works on an empty or error screen.
    private func scrollable(@ViewBuilder _ inner: () -> some View) -> some View {
        ScrollView {
            inner().containerRelativeFrame([.horizontal, .vertical])
        }
    }
}
