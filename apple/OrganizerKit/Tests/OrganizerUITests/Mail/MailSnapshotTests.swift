import AppKit
import OrganizerAPI
import OrganizerCore
import SwiftUI
import Testing

@testable import OrganizerUI

/// The Mail screen drawn offscreen against the demo server (headers only: the demo accounts have
/// no real mailbox, so opening one shows the server's connection error), and the reader drawn
/// from synthetic fixtures shaped like the real schema.
@Suite(.enabled(if: Snapshot.enabled))
@MainActor
struct MailSnapshotTests {
    @Test func renderMail() async throws {
        let app = try Snapshot.app()
        let store = app.store { MailStore(client: $0) }
        await store.load()
        try Snapshot.render(MailScreen().environment(app), size: CGSize(width: 1100, height: 720), name: "mac-mail")

        if let first = store.messages.first {
            store.select(first.id)
            await store.loadReader()
            try Snapshot.render(MailScreen().environment(app), size: CGSize(width: 1100, height: 720), name: "mac-mail-open-demo")
        }

        let detail = try APIJSON.decoder().decode(MailMessageDetail.self, from: Data(MailFixtures.detail.utf8))
        let account = MailAccountOut(id: 2, kind: .imap, label: "Work", address: "jane@example.com", state: .ok)
        try Snapshot.render(
            MailReaderView(state: Loadable(value: detail, fetchedAt: Date()), summary: nil, account: account, retry: {}),
            size: CGSize(width: 720, height: 760), name: "mac-mail-reader")

        let unchecked = try APIJSON.decoder().decode(MailMessageDetail.self, from: Data(MailFixtures.unchecked.utf8))
        try Snapshot.render(
            MailReaderView(state: Loadable(value: unchecked, fetchedAt: Date()), summary: nil, account: nil, retry: {}),
            size: CGSize(width: 720, height: 520), name: "mac-mail-reader-unchecked")

        let forbidden = Loadable<MailMessageDetail>(error: MailStore.explain(.server(status: 403, message: "forbidden")))
        try Snapshot.render(
            MailReaderView(state: forbidden, summary: nil, account: nil, retry: {}),
            size: CGSize(width: 720, height: 420), name: "mac-mail-reader-403")
    }
}
