import OrganizerAPI
import SwiftUI

/// Something a store tells the user after a write: a failure with the server's message (shown
/// as an alert), or a quiet confirmation with an optional Undo (shown as a banner).
///
///     store.notice = .failure("Couldn't save", error)
///     store.notice = .info("Deleted “Buy milk”", action: .init("Undo") { await store.restore(task) })
public struct Notice: Identifiable, Sendable {
    public struct Action: Sendable {
        public let label: String
        public let run: @MainActor @Sendable () async -> Void

        public init(_ label: String, run: @escaping @MainActor @Sendable () async -> Void) {
            self.label = label
            self.run = run
        }
    }

    public enum Kind: Sendable {
        case info
        case failure
    }

    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let message: String?
    public let action: Action?

    public static func info(_ title: String, action: Action? = nil) -> Notice {
        Notice(kind: .info, title: title, message: nil, action: action)
    }

    /// A write the server refused or that never arrived; `message` is the server's own words.
    public static func failure(_ title: String, _ error: any Error) -> Notice {
        Notice(kind: .failure, title: title, message: APIError(error).message, action: nil)
    }
}

extension View {
    /// Shows a store's notices: failures as an alert, info as a banner at the bottom that
    /// dismisses itself after a few seconds.
    ///
    ///     .notices($store.notice)
    public func notices(_ notice: Binding<Notice?>) -> some View {
        modifier(NoticeModifier(notice: notice))
    }
}

private struct NoticeModifier: ViewModifier {
    @Binding var notice: Notice?

    func body(content: Content) -> some View {
        content
            .alert(
                notice?.title ?? "",
                isPresented: Binding(
                    get: { notice?.kind == .failure },
                    set: { if !$0 { notice = nil } }
                ),
                presenting: notice
            ) { _ in
                Button("OK", role: .cancel) { notice = nil }
            } message: { notice in
                if let message = notice.message { Text(message) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let banner = notice, banner.kind == .info {
                    NoticeBanner(notice: banner) { notice = nil }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: banner.id) {
                            try? await Task.sleep(for: .seconds(6))
                            if notice?.id == banner.id { notice = nil }
                        }
                }
            }
            .animation(.snappy, value: notice?.id)
    }
}

private struct NoticeBanner: View {
    let notice: Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(notice.title)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = notice.action {
                Button(action.label) {
                    dismiss()
                    Task { await action.run() }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}
