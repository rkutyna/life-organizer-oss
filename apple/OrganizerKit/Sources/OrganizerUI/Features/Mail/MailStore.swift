import Foundation
import Observation
import OrganizerAPI
import OrganizerCore

/// The filters the inbox lists by. One query is one read of `/api/mail/messages`.
nonisolated struct MailQuery: Hashable, Sendable {
    var account: Int?
    var folder: API.Mail.ListMessagesFolder = .inbox
    /// Subject, sender or recipients (the server's `q`), trimmed.
    var text: String = ""
    /// The sender's name or address (the server's `sender`), trimmed.
    var sender: String = ""

    /// How many headers one read asks for (the web asks for the same).
    static let limit = 200

    var endpoint: Endpoint<MailMessageList> {
        API.Mail.listMessages(
            account: account,
            folder: folder,
            q: text.isEmpty ? nil : text,
            sender: sender.isEmpty ? nil : sender,
            limit: Self.limit
        )
    }

    /// Only the typed filters differ (so the change waits for typing to pause).
    func differsOnlyInText(from other: MailQuery) -> Bool {
        account == other.account && folder == other.folder && self != other
    }

    var isFiltered: Bool { !text.isEmpty || !sender.isEmpty }
}

/// The Mail screen's state: the header list for the current filters, the accounts, and the one
/// message open in the reader. Read only: there is no write here at all, because the API has
/// none (the server's "sync now" is browser-only).
///
/// - The list is a `Resource` per query. Changing a filter replaces it; the old list stays on
///   screen while the new one loads (unless the new one fails).
/// - The reader is a `Resource` for the open message, in memory only. Mail is never cached on
///   disk (`Endpoint.isCacheable` skips `/api/mail/`), and the server never stores bodies.
/// - A 403 means the token has no `mail` scope; the screen says how to make one.
@MainActor
@Observable
final class MailStore {
    nonisolated static let noScopeMessage =
        "This token has no mail scope. Make a token with the api and mail scopes in the web app's Settings → API tokens."

    // MARK: Filters (bound to the header controls)

    var account: Int?
    var folder: API.Mail.ListMessagesFolder = .inbox
    var searchText = ""
    var senderText = ""

    /// The query the controls describe now.
    var query: MailQuery {
        MailQuery(
            account: account,
            folder: folder,
            text: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            sender: senderText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: Reads

    /// The list for `loadedQuery`.
    private(set) var list: Resource<MailMessageList>
    private(set) var loadedQuery: MailQuery
    /// The last list that loaded, shown while a new query's first read runs.
    private var previous: MailMessageList?

    /// The message selected in the list (or opened by a link).
    private(set) var selectedID: Int?
    /// The open message, read live.
    private(set) var reader: Resource<MailMessageDetail>?

    @ObservationIgnored let client: OrganizerClient

    init(client: OrganizerClient) {
        self.client = client
        let query = MailQuery()
        loadedQuery = query
        list = Resource(query.endpoint, client: client)
    }

    // MARK: Loading

    /// Loads the list for the current filters, unless a copy younger than a minute is on screen.
    func load() async {
        switchToCurrentQuery()
        await list.refreshIfStale(maxAge: 60)
    }

    /// Fetches the list (and the open message) now.
    func refresh() async {
        switchToCurrentQuery()
        let reader = self.reader
        async let headers: Void = list.refresh()
        if let reader { await reader.refresh() }
        await headers
    }

    /// Whether the controls' query changed only in its typed text (debounce before loading).
    var isTypingChange: Bool {
        query.differsOnlyInText(from: loadedQuery)
    }

    private func switchToCurrentQuery() {
        let next = query
        guard next != loadedQuery else { return }
        if let value = list.value { previous = value }
        loadedQuery = next
        list = Resource(next.endpoint, client: client)
    }

    // MARK: What the screen shows

    /// The list's status for `LoadingScaffold`: a previous list counts as content while the new
    /// query loads, and a 403 carries the "no mail scope" message.
    var status: LoadStatus {
        var status = list.state.status
        if !status.hasValue, status.error == nil, previous != nil {
            status.hasValue = true
        }
        status.error = status.error.map(Self.explain)
        return status
    }

    /// The headers on screen: the current list, else (while it loads) the previous one.
    var messages: [MailMessageOut] {
        if let value = list.value { return value.messages }
        guard list.state.error == nil else { return [] }
        return previous?.messages ?? []
    }

    var accounts: [MailAccountOut] {
        list.value?.accounts ?? previous?.accounts ?? []
    }

    func account(id: Int) -> MailAccountOut? {
        accounts.first { $0.id == id }
    }

    /// Loaded, and no account is connected.
    var hasNoAccounts: Bool {
        list.value != nil && accounts.isEmpty
    }

    var isEmpty: Bool { messages.isEmpty }

    /// The reader's state, with a 403 explained.
    var readerState: Loadable<MailMessageDetail>? {
        guard var state = reader?.state else { return nil }
        state.error = state.error.map(Self.explain)
        return state
    }

    /// A 403 from `/api/mail` means the token lacks the `mail` scope: say how to fix it.
    nonisolated static func explain(_ error: APIError) -> APIError {
        error.isForbidden ? .server(status: 403, message: noScopeMessage) : error
    }

    // MARK: Selection

    /// Opens a message in the reader (fetched now) or closes it (nil). Selecting the open
    /// message again keeps its copy.
    func select(_ id: Int?) {
        guard id != selectedID else { return }
        selectedID = id
        reader = id.map { Resource(API.Mail.readMessage(messageId: $0), client: client) }
    }

    /// Loads the open message unless it already loaded.
    func loadReader() async {
        guard let reader, reader.value == nil else { return }
        await reader.refresh()
    }

    /// The next (`delta` 1) or previous (-1) message in the list.
    func step(_ delta: Int) {
        let list = messages
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID }
        let next = index.map { min(list.count - 1, max(0, $0 + delta)) } ?? 0
        select(list[next].id)
    }

    // MARK: Links

    /// `lifeorganizer://mail?message=7&folder=sent&account=2&q=invoice`: sets the filters it
    /// names and opens the message.
    func apply(_ link: DeepLink) {
        if let raw = link.query["folder"] {
            folder = API.Mail.ListMessagesFolder(rawValue: raw) == .sent ? .sent : .inbox
        }
        if let raw = link.query["account"] {
            account = Int(raw)
        }
        if let text = link.query["q"] {
            searchText = text
        }
        if let raw = link.query["message"] ?? link.query["m"] ?? link.path.first, let id = Int(raw) {
            select(id)
        }
    }
}

/// Small pure helpers the views and tests share.
nonisolated enum MailFormat {
    /// "Jane Doe <jane@example.com>", or the address alone.
    static func person(_ address: MailAddress) -> String {
        address.name.isEmpty ? address.address : "\(address.name) <\(address.address)>"
    }

    /// Who a row names: the sender in the inbox, "To: …" in Sent.
    static func who(_ message: MailMessageOut) -> String {
        if message.folder == .sent {
            guard let first = message.to.first else { return "To: (nobody)" }
            let rest = message.to.count > 1 ? " +\(message.to.count - 1)" : ""
            return "To: \(first.name.isEmpty ? first.address : first.name)\(rest)"
        }
        let name = message.from.name.isEmpty ? message.from.address : message.from.name
        return name.isEmpty ? "(no sender)" : name
    }

    /// "3:05 PM" today, "Nov 10" this year, "Nov 10, 2025" before.
    static func listDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func bytes(_ size: Int) -> String {
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(Int((Double(size) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }

    /// What the cleaner removed, in a sentence, and how the body is shown.
    static func cleaned(_ removed: MailRemoved, source: MailMessageDetail.BodySource) -> String {
        let total = removed.hiddenChars + removed.invisibleChars
        let first = total == 0
            ? "Cleaned: nothing hidden was found."
            : "Cleaned: removed \(removed.hiddenChars.formatted()) hidden and \(removed.invisibleChars.formatted()) invisible characters before showing it."
        let shown = source == .html ? "Shown as plain text converted from HTML." : "Shown as plain text."
        return "\(first) \(shown)"
    }
}
