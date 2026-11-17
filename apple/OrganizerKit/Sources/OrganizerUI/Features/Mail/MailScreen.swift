import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The Mail module's root screen (the registry names this type; keep the name). The read-only
/// inbox: mirrored headers on the left, the open message on the right.
///
/// Nothing here can change mail. There is no send, delete, move, flag or mark-read anywhere,
/// because the API has none; and "sync now" is browser-only on the server, so the app only
/// re-reads the mirror (Refresh, ⌘R).
struct MailScreen: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        MailView(store: app.store { MailStore(client: $0) })
    }
}

/// Handles `lifeorganizer://mail?message=7` (and the optional `folder`, `account`, `q`): opens
/// that message, with the filters the link names.
struct MailView: View {
    @Bindable var store: MailStore
    @Environment(AppEnvironment.self) private var app
    @FocusState private var focus: MailField?

    enum MailField: Hashable {
        case search, sender, list
    }

    var body: some View {
        ModuleNavigationStack {
            VStack(spacing: 0) {
                if !store.hasNoAccounts {
                    MailFilterBar(store: store, focus: $focus)
                    MailAccountErrors(accounts: store.accounts)
                    Divider()
                }
                LoadingScaffold(status: store.status, refresh: { await store.refresh() }) {
                    if store.hasNoAccounts {
                        noAccounts
                    } else {
                        split
                    }
                }
            }
            .navigationTitle("Mail")
            .toolbar { toolbar }
            .background { shortcuts }
            .task(id: store.query) {
                if store.isTypingChange {
                    try? await Task.sleep(for: .milliseconds(300))
                    if Task.isCancelled { return }
                }
                await store.load()
            }
            .task(id: store.selectedID) { await store.loadReader() }
            .task { await poll() }
            .task(id: app.deepLink(for: .mail)?.id) { apply(app.deepLink(for: .mail)) }
        }
    }

    // MARK: Layout

    private var split: some View {
        HSplitView {
            MailHeaderList(store: store)
                .focused($focus, equals: .list)
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
            MailReaderPane(store: store)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noAccounts: some View {
        EmptyStateView(
            "No mail accounts yet",
            systemImage: "envelope",
            message: "Connect an IMAP account (iCloud, Fastmail, Outlook) or a Google account with Gmail in the web app's Settings → Connected accounts. Mail is only read: nothing in your mailbox is ever changed."
        ) {
            OpenInWebLink(path: "/settings", title: "Open Settings in Web")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read the mirrored headers (the server syncs mailboxes every 15 minutes)")
            .accessibilityIdentifier("mail.refresh")
            OpenInWebLink(path: webPath)
                .help("Open this view in the web app")
        }
    }

    private var webPath: String {
        store.selectedID.map { "/mail?m=\($0)" } ?? "/mail"
    }

    /// Keyboard: ⌘F search, ⌥⌘F sender. (J/K and Esc are on the list.)
    private var shortcuts: some View {
        Group {
            Button("Search") { focus = .search }
                .keyboardShortcut("f")
            Button("Filter by Sender") { focus = .sender }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Behaviour

    /// Re-reads the list every five minutes while the screen is visible, as the web does.
    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))
            if Task.isCancelled { return }
            await store.list.refresh()
        }
    }

    private func apply(_ link: DeepLink?) {
        guard let link else { return }
        defer { app.consume(link) }
        store.apply(link)
    }
}

// MARK: - Filters

/// Inbox / Sent, the account, and the two searches; the accounts' freshness on the right.
struct MailFilterBar: View {
    @Bindable var store: MailStore
    var focus: FocusState<MailView.MailField?>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Picker("Folder", selection: $store.folder) {
                Label("Inbox", systemImage: "tray").tag(API.Mail.ListMessagesFolder.inbox)
                Label("Sent", systemImage: "paperplane").tag(API.Mail.ListMessagesFolder.sent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("mail.folder")

            Picker("Account", selection: $store.account) {
                Text("All accounts").tag(Int?.none)
                if !store.accounts.isEmpty { Divider() }
                ForEach(store.accounts, id: \.id) { account in
                    Text(verbatim: account.label).tag(Int?.some(account.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("mail.account")

            MailSearchField(text: $store.searchText, prompt: "Search subjects, senders, recipients",
                            systemImage: "magnifyingglass")
                .focused(focus, equals: .search)
                .frame(minWidth: 160, maxWidth: 300)
                .accessibilityIdentifier("mail.search")

            MailSearchField(text: $store.senderText, prompt: "From", systemImage: "person")
                .focused(focus, equals: .sender)
                .frame(minWidth: 100, maxWidth: 180)
                .accessibilityIdentifier("mail.sender")

            Spacer(minLength: 0)

            MailAccountsFreshness(accounts: store.accounts)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A rounded text field with a leading symbol and a clear button.
struct MailSearchField: View {
    @Binding var text: String
    let prompt: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

/// One dot per account, colored by its mirror's freshness; hovering says how old it is.
struct MailAccountsFreshness: View {
    let accounts: [MailAccountOut]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(accounts, id: \.id) { account in
                HStack(spacing: 4) {
                    ColorDot(Palette.status(account.state.rawValue), size: 7)
                    Text(verbatim: account.label)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Palette.mutedForeground)
                .help(help(account))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(account.label): \(account.state.rawValue)")
            }
        }
    }

    private func help(_ account: MailAccountOut) -> String {
        var lines = ["\(account.label) (\(account.address))"]
        if let asOf = account.asOf {
            lines.append("Headers synced \(Freshness.age(of: asOf)) (\(asOf.formatted(date: .abbreviated, time: .shortened)))")
        } else {
            lines.append("Headers never synced")
        }
        if account.state == .error, let error = account.error {
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }
}

/// Accounts whose last sync failed, with the server's message. Hidden when none failed.
struct MailAccountErrors: View {
    let accounts: [MailAccountOut]

    var body: some View {
        let failing = accounts.filter { $0.state == .error }
        if !failing.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(failing, id: \.id) { account in
                    Label {
                        Text(verbatim: "\(account.label): \(account.error ?? "the last sync failed")")
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.status(.error))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - List

/// The mirrored headers, newest first. ↑↓ (or J/K) move through them; Esc closes the reader.
struct MailHeaderList: View {
    @Bindable var store: MailStore

    var body: some View {
        let showsAccount = store.accounts.count > 1 && store.account == nil
        List(selection: Binding(get: { store.selectedID }, set: { store.select($0) })) {
            ForEach(store.messages, id: \.id) { message in
                MailMessageRow(
                    message: message,
                    account: showsAccount ? store.account(id: message.account)?.label : nil
                )
                .tag(message.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if store.isEmpty, store.status.hasValue, !store.list.state.isRefreshing {
                empty
            }
        }
        .onKeyPress("j") { store.step(1); return .handled }
        .onKeyPress("k") { store.step(-1); return .handled }
        .onKeyPress(.escape) { store.select(nil); return .handled }
        .accessibilityIdentifier("mail.list")
    }

    private var empty: some View {
        let query = store.loadedQuery
        if query.isFiltered {
            return EmptyStateView("No headers match", systemImage: "magnifyingglass",
                                  message: "Search looks at subjects, names and addresses of the mirrored headers.")
        }
        return EmptyStateView(query.folder == .sent ? "Nothing sent" : "Inbox is empty",
                              systemImage: query.folder == .sent ? "paperplane" : "tray",
                              message: "Only the recent window of mail is mirrored.")
    }
}

/// One header: who, when, a warning when the From line may not be the sender, the subject.
struct MailMessageRow: View {
    let message: MailMessageOut
    let account: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: MailFormat.who(message))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.senderWarning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.status(.stale))
                        .imageScale(.small)
                        .help(message.senderWarning ?? "")
                        .accessibilityLabel("The sender shown may not be real")
                }
                Text(MailFormat.listDate(message.date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: message.subject.isEmpty ? "(no subject)" : message.subject)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let account {
                Text(verbatim: account)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reader pane

/// The right side: nothing open, or the open message.
struct MailReaderPane: View {
    @Bindable var store: MailStore

    var body: some View {
        if let id = store.selectedID, let state = store.readerState {
            let summary = store.messages.first { $0.id == id }
            MailReaderView(
                state: state,
                summary: summary,
                account: (state.value?.account ?? summary?.account).flatMap { store.account(id: $0) },
                retry: { await store.reader?.refresh() }
            )
            .id(id)
        } else {
            EmptyStateView(
                "No message open",
                systemImage: "envelope.open",
                message: "Opening one fetches it from the mailbox and cleans it. It isn't marked as read, and its body is never stored."
            )
        }
    }
}

#Preview {
    MailScreen().environment(AppEnvironment.preview())
}
