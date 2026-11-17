import OrganizerAPI
import SwiftUI

/// "Nothing here" for a screen or section: an SF Symbol, a title and a calm sentence.
///
///     EmptyStateView("Nothing to do", systemImage: "checkmark.circle",
///                    message: "Add one below. Dates like “friday 9am” are understood.")
public struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String?
    let actions: Actions

    public init(_ title: String, systemImage: String, message: String? = nil,
                @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            actions
        }
    }
}

/// A read failed and there is no cached copy to show. Shows the server's message and a Retry.
public struct ErrorStateView: View {
    let title: String
    let error: APIError
    let retry: (() async -> Void)?

    public init(_ title: String = "Couldn't load", error: APIError, retry: (() async -> Void)? = nil) {
        self.title = title
        self.error = error
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: error.isOffline ? "wifi.slash" : "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            if let retry {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// A first load with nothing cached yet.
public struct LoadingStateView: View {
    let label: String

    public init(_ label: String = "Loading…") {
        self.label = label
    }

    public var body: some View {
        ProgressView(label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
