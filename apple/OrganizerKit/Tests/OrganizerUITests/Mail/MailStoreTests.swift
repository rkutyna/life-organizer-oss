import Foundation
import OrganizerAPI
import OrganizerCore
import OrganizerTestSupport
import Testing

@testable import OrganizerUI

/// The Mail store against a stub server: the list's filters reach the query, the reader reads one
/// message live, a 403 explains the missing scope, links open a message, nothing is ever written,
/// and no mail response reaches the disk cache.
@Suite("Mail store")
@MainActor
struct MailStoreTests {
    let server = StubServer()

    init() {
        server.respond(.get, "/api/mail/messages", json: MailFixtures.inbox)
        server.respond(.get, "/api/mail/messages/1", json: MailFixtures.detail)
        server.respond(.get, "/api/mail/messages/3", json: MailFixtures.unchecked)
    }

    private func queryItems(_ recorded: StubServer.Recorded?) -> [String: String] {
        let items = URLComponents(string: "http://x/?\(recorded?.query ?? "")")?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    // MARK: List

    @Test func loadsTheInboxWithAccounts() async {
        let store = MailStore(client: server.client())
        await store.load()
        #expect(store.messages.map(\.id) == [1, 2, 3])
        #expect(store.accounts.map(\.label) == ["Work", "Personal"])
        #expect(store.status.hasValue && store.status.error == nil)
        #expect(!store.hasNoAccounts)
        let query = queryItems(server.requests(.get, "/api/mail/messages").last)
        #expect(query == ["folder": "inbox", "limit": "200"])
    }

    @Test func filtersReachTheQuery() async {
        let store = MailStore(client: server.client())
        await store.load()
        store.account = 3
        store.folder = .sent
        store.searchText = "  invoice "
        store.senderText = "acme"
        await store.load()
        let query = queryItems(server.requests(.get, "/api/mail/messages").last)
        #expect(query == ["account": "3", "folder": "sent", "q": "invoice", "sender": "acme", "limit": "200"])
        #expect(store.loadedQuery.isFiltered)
    }

    @Test func typingIsDebouncedButFolderAndAccountAreNot() async {
        let store = MailStore(client: server.client())
        await store.load()
        store.searchText = "cof"
        #expect(store.isTypingChange)
        await store.load()
        #expect(!store.isTypingChange)
        store.folder = .sent
        #expect(!store.isTypingChange)
    }

    @Test func noAccountsIsItsOwnState() async {
        server.respond(.get, "/api/mail/messages", json: MailFixtures.empty)
        let store = MailStore(client: server.client())
        await store.load()
        #expect(store.hasNoAccounts)
        #expect(store.isEmpty)
    }

    @Test func forbiddenListExplainsTheMailScope() async {
        server.respond(.get, "/api/mail/messages", status: 403, json: MailFixtures.forbidden)
        let store = MailStore(client: server.client())
        await store.load()
        #expect(store.status.error?.status == 403)
        #expect(store.status.error?.message == MailStore.noScopeMessage)
        #expect(MailStore.noScopeMessage.contains("api and mail scopes"))
        #expect(store.messages.isEmpty)
    }

    @Test func aFailedNewQueryDoesNotShowTheOldList() async {
        let store = MailStore(client: server.client())
        await store.load()
        server.respond(.get, "/api/mail/messages", status: 500, json: #"{"detail": "database is locked"}"#)
        store.folder = .sent
        await store.load()
        #expect(store.messages.isEmpty)
        #expect(store.status.error?.message == "database is locked")
    }

    // MARK: Reader

    @Test func selectingAMessageReadsItLive() async throws {
        let store = MailStore(client: server.client())
        await store.load()
        store.select(1)
        await store.loadReader()
        let message = try #require(store.readerState?.value)
        #expect(message.bodySource == .html)
        #expect(message.senderChecks?.verified == true)
        #expect(message.removed.hiddenChars == 212)
        #expect(message.warnings.count == 1)
        #expect(server.requests(.get, "/api/mail/messages/1").count == 1)
        // Loading again keeps the copy; selecting the same message keeps it too.
        await store.loadReader()
        store.select(1)
        await store.loadReader()
        #expect(server.requests(.get, "/api/mail/messages/1").count == 1)
        store.select(nil)
        #expect(store.reader == nil && store.readerState == nil)
    }

    @Test func readerShowsTheServersErrorAndExplains403() async {
        server.respond(.get, "/api/mail/messages/2", status: 503, json: #"{"detail": "mail account 2 is missing its settings"}"#)
        let store = MailStore(client: server.client())
        store.select(2)
        await store.loadReader()
        #expect(store.readerState?.error?.message == "mail account 2 is missing its settings")

        server.respond(.get, "/api/mail/messages/1", status: 403, json: MailFixtures.forbidden)
        store.select(1)
        await store.loadReader()
        #expect(store.readerState?.error?.message == MailStore.noScopeMessage)
    }

    @Test func stepMovesThroughTheList() async {
        let store = MailStore(client: server.client())
        await store.load()
        store.step(1)
        #expect(store.selectedID == 1)
        store.step(1)
        store.step(1)
        store.step(1)
        #expect(store.selectedID == 3)
        store.step(-1)
        #expect(store.selectedID == 2)
    }

    // MARK: Links

    @Test func deepLinkOpensTheMessage() throws {
        let store = MailStore(client: server.client())
        let link = try #require(DeepLink(URL(string: "lifeorganizer://mail?message=7")!))
        store.apply(link)
        #expect(store.selectedID == 7)
        #expect(store.folder == .inbox)
        store.apply(DeepLink(module: .mail, query: ["message": "3", "folder": "sent", "account": "2", "q": "acme"]))
        #expect(store.selectedID == 3)
        #expect(store.folder == .sent && store.account == 2 && store.searchText == "acme")
        store.apply(DeepLink(module: .mail, query: ["message": "nope"]))
        #expect(store.selectedID == 3)
    }

    // MARK: Read only, never cached

    @Test func everythingIsAGet() async {
        let store = MailStore(client: server.client())
        await store.load()
        store.select(1)
        await store.loadReader()
        await store.refresh()
        #expect(!server.requests.isEmpty)
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.body == nil })
    }

    @Test func mailIsNeverWrittenToTheDiskCache() async throws {
        let cache = temporaryCache()
        let client = server.client(cache: cache)
        let store = MailStore(client: client)
        await store.load()
        store.select(1)
        await store.loadReader()
        #expect(store.readerState?.value != nil)

        let list = MailQuery().endpoint
        let detail = API.Mail.readMessage(messageId: 1)
        #expect(!list.isCacheable && !detail.isCacheable)
        #expect(client.cached(list) == nil)
        #expect(client.cached(detail) == nil)
        // Not just hidden by `cached`: nothing was written under either key.
        #expect(cache.read(key: client.cacheKey(list)) == nil)
        #expect(cache.read(key: client.cacheKey(detail)) == nil)
        #expect(cache.size() == 0)
        // A new store (the next launch) starts with nothing.
        #expect(MailStore(client: client).list.value == nil)
    }

    // MARK: Formatting

    @Test func rowsNameTheSenderOrTheRecipients() async throws {
        let store = MailStore(client: server.client())
        await store.load()
        let first = try #require(store.messages.first)
        #expect(MailFormat.who(first) == "Acme Recruiting")
        var sent = first
        sent.folder = .sent
        #expect(MailFormat.who(sent) == "To: Jane Doe")
        sent.to = []
        #expect(MailFormat.who(sent) == "To: (nobody)")
        #expect(MailFormat.person(MailAddress(name: "", address: "a@example.com")) == "a@example.com")
        #expect(MailFormat.bytes(52310) == "51 KB")
    }

    @Test func cleanedLineCountsWhatWasRemoved() {
        #expect(MailFormat.cleaned(MailRemoved(hiddenChars: 0, invisibleChars: 0), source: .plain)
            == "Cleaned: nothing hidden was found. Shown as plain text.")
        #expect(MailFormat.cleaned(MailRemoved(hiddenChars: 1200, invisibleChars: 3), source: .html)
            .hasPrefix("Cleaned: removed 1,200 hidden and 3 invisible characters"))
    }
}
