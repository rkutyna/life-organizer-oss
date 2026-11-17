import Foundation
import OrganizerAPI
import OrganizerTestSupport
import Testing

/// The mail responses as the server sends them (synthetic, fictional): `from` as a key, nullable
/// sender checks, the cleaner's counts. And the facade: reads only, never cached.
@Suite("Mail decoding")
struct MailDecodingTests {
    static let list = #"""
    {"accounts": [{"id": 2, "kind": "imap", "label": "Work", "address": "jane@example.com",
                   "state": "stale", "as_of": "2026-11-16T15:00:00.123456Z", "error": null}],
     "messages": [{"id": 9, "account": 2, "folder": "sent",
                   "from": {"name": "Jane Doe", "address": "jane@example.com"}, "sender_warning": null,
                   "to": [{"name": "", "address": "team@acme.example.com"}], "cc": [],
                   "subject": "Re: Hello", "date": "2026-11-16T14:05:00Z", "size": null,
                   "message_id": null, "in_reply_to": "<a@example.com>", "untrusted": true}],
     "untrusted": true}
    """#

    static let detail = #"""
    {"id": 1, "account": 2, "folder": "inbox",
     "from": {"name": "Acme", "address": "news@acme.example.com"},
     "sender_warning": "The From line names two addresses.",
     "to": [], "cc": [], "subject": "News", "date": "2026-11-16T14:05:00Z", "size": 1024,
     "message_id": "<m1@example.com>", "in_reply_to": null, "untrusted": true,
     "reply_to": [], "body": "Hello", "body_source": "mixed", "truncated": true, "attachments": [],
     "sender_checks": {"verified": false, "spf": "pass", "dkim": null, "dmarc": "none", "dmarc_from": null},
     "removed": {"hidden_chars": 3, "invisible_chars": 0},
     "warnings": ["The sender's domain (acme.example.com) could not be verified (DMARC none): the From address may be forged."]}
    """#

    @Test func decodesTheHeaderList() throws {
        let list = try APIJSON.decoder().decode(MailMessageList.self, from: Data(Self.list.utf8))
        #expect(list.untrusted == true)
        #expect(list.accounts.first?.state == .stale)
        #expect(list.accounts.first?.asOf != nil)
        let message = try #require(list.messages.first)
        #expect(message.folder == .sent)
        #expect(message.from.address == "jane@example.com")
        #expect(message.to.first?.name == "")
        #expect(message.size == nil && message.inReplyTo == "<a@example.com>")
    }

    @Test func decodesAMessageWithItsChecks() throws {
        let message = try APIJSON.decoder().decode(MailMessageDetail.self, from: Data(Self.detail.utf8))
        #expect(message.bodySource == .mixed)
        #expect(message.truncated)
        #expect(message.senderWarning != nil)
        #expect(message.senderChecks?.verified == false)
        #expect(message.senderChecks?.dkim == nil)
        #expect(message.senderChecks?.dmarc == "none")
        #expect(message.removed.hiddenChars == 3)
        #expect(message.warnings.count == 1)
    }

    @Test func decodesNullChecksAndUnknownValues() throws {
        var raw = Self.detail.replacingOccurrences(
            of: #""sender_checks": {"verified": false, "spf": "pass", "dkim": null, "dmarc": "none", "dmarc_from": null}"#,
            with: #""sender_checks": null"#)
        raw = raw.replacingOccurrences(of: #""body_source": "mixed""#, with: #""body_source": "rtf""#)
        let message = try APIJSON.decoder().decode(MailMessageDetail.self, from: Data(raw.utf8))
        #expect(message.senderChecks == nil)
        #expect(message.bodySource == .unknown("rtf"))
    }

    @Test func facadeReadsAndNeverCaches() async throws {
        let server = StubServer()
        server.respond(.get, "/api/mail/messages", json: Self.list)
        server.respond(.get, "/api/mail/messages/1", json: Self.detail)
        let cache = temporaryCache()
        let client = server.client(cache: cache)

        let list = try await client.mail.messages(account: 2, folder: .sent, q: "hello", sender: "jane", limit: 20)
        #expect(list.messages.count == 1)
        #expect(server.requests.last?.query == "account=2&folder=sent&q=hello&sender=jane&limit=20")
        let message = try await client.mail.message(id: 1)
        #expect(message.subject == "News")

        let endpoint = API.Mail.readMessage(messageId: 1)
        #expect(client.cached(endpoint) == nil)
        #expect(cache.read(key: client.cacheKey(endpoint)) == nil)
        #expect(cache.read(key: client.cacheKey(API.Mail.listMessages(account: 2, folder: .sent, q: "hello", sender: "jane", limit: 20))) == nil)
        #expect(server.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func forbiddenIsA403() async {
        let server = StubServer()
        server.respond(.get, "/api/mail/accounts", status: 403, json: #"{"detail": "this token has no mail scope"}"#)
        await #expect(throws: APIError.server(status: 403, message: "this token has no mail scope")) {
            try await server.client().mail.accounts()
        }
    }
}
