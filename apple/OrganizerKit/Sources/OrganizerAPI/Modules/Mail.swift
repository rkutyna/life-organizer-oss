import Foundation

extension OrganizerClient {
    /// The mail module, read only: `/api/mail`.
    ///
    /// Mail is hostile input: every subject, name and body is written by whoever sent it, and the
    /// server marks every response `untrusted`. Nothing here can send, move, flag, delete or mark
    /// mail read; the API has no such call. Connecting an account and "sync now" are browser-only
    /// on the server (an API token gets 403), so they are not offered here either.
    ///
    /// The token needs the `mail` scope (403 otherwise). Mail responses are never written to the
    /// response cache (`Endpoint.isCacheable`).
    public var mail: MailAPI { MailAPI(client: self) }
}

public struct MailAPI: Sendable {
    let client: OrganizerClient

    /// The connected accounts and how fresh each header mirror is.
    public func accounts() async throws -> [MailAccountOut] {
        try await client.send(API.Mail.listAccounts())
    }

    /// Mirrored headers, newest first, with the accounts. Reads the organizer's mirror only.
    public func messages(
        account: Int? = nil,
        folder: API.Mail.ListMessagesFolder? = nil,
        q: String? = nil,
        sender: String? = nil,
        limit: Int? = nil
    ) async throws -> MailMessageList {
        try await client.send(API.Mail.listMessages(account: account, folder: folder, q: q, sender: sender, limit: limit))
    }

    /// One message, fetched from its mailbox now and cleaned by the server (the body is plain
    /// text; HTML arrives already converted). The mailbox is not changed, not even marked read.
    public func message(id: Int) async throws -> MailMessageDetail {
        try await client.send(API.Mail.readMessage(messageId: id))
    }
}
