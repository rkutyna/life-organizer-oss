import OrganizerAPI
import OrganizerCore
import SwiftUI

/// One message as the server fetched and cleaned it.
///
/// Everything in it is the sender's text, so:
/// - the untrusted banner comes first, above the subject (which the sender also wrote);
/// - the sender checks (SPF, DKIM, DMARC as the receiving server recorded them) and the server's
///   warnings sit above the body;
/// - the body is shown as plain text with `Text(verbatim:)`. The server always sends text (HTML
///   arrives converted, `body_source` says so), so there is no web view: nothing can run, load
///   a remote image or follow a link. Links are not even detected; a reader copies one to open it.
/// - every sender-written string goes through `Text(verbatim:)`, never a `LocalizedStringKey`,
///   so Markdown in a subject or name is not interpreted.
struct MailReaderView: View {
    let state: Loadable<MailMessageDetail>
    /// The list's header for this message, shown while the body loads or when it fails.
    let summary: MailMessageOut?
    let account: MailAccountOut?
    let retry: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MailUntrustedBanner()
                if let message = state.value {
                    MailMessageHeader(
                        subject: message.subject, from: message.from, to: message.to, cc: message.cc,
                        replyTo: message.replyTo, date: message.date, folder: message.folder.rawValue,
                        account: account
                    )
                    if message.folder != .sent {
                        MailSenderChecksView(checks: message.senderChecks)
                    }
                    if !message.warnings.isEmpty {
                        MailWarningsView(warnings: message.warnings)
                    }
                    MailBodyView(message: message)
                    if !message.attachments.isEmpty {
                        MailAttachmentsView(attachments: message.attachments)
                    }
                } else {
                    if let summary {
                        MailMessageHeader(
                            subject: summary.subject, from: summary.from, to: summary.to, cc: summary.cc,
                            replyTo: [], date: summary.date, folder: summary.folder.rawValue, account: account
                        )
                    }
                    if let error = state.error, !state.isRefreshing {
                        ErrorStateView("Couldn't open this message", error: error, retry: retry)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ProgressView("Fetching from the mailbox…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("mail.reader")
    }
}

/// The warning on every message: its text is the sender's, not the organizer's.
struct MailUntrustedBanner: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Palette.status(.error))
                .accessibilityHidden(true)
            Text("\(Text("Untrusted content.").fontWeight(.semibold)) Everything below, the subject and names included, was written by whoever sent it. Treat links and requests in it with care.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.status(.error).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.status(.error).opacity(0.4)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mail.untrusted")
    }
}

/// Subject, From, To, Cc, Reply-To, date and account.
struct MailMessageHeader: View {
    let subject: String
    let from: MailAddress
    let to: [MailAddress]
    let cc: [MailAddress]
    let replyTo: [MailAddress]
    let date: Date
    let folder: String
    let account: MailAccountOut?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: subject.isEmpty ? "(no subject)" : subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                row("From", MailFormat.person(from))
                if !to.isEmpty { row("To", to.map(MailFormat.person).joined(separator: ", ")) }
                if !cc.isEmpty { row("Cc", cc.map(MailFormat.person).joined(separator: ", ")) }
                if !replyTo.isEmpty { row("Reply-To", replyTo.map(MailFormat.person).joined(separator: ", ")) }
                row("Date", date.formatted(date: .abbreviated, time: .shortened))
                if let account {
                    row("Account", "\(account.label) · \(folder == "sent" ? "Sent" : "Inbox")")
                }
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(verbatim: value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Whether the From address is known to be real: DMARC for its own domain, and the SPF, DKIM and
/// DMARC results the receiving server recorded.
struct MailSenderChecksView: View {
    let checks: MailSenderChecks?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: symbol)
                .fontWeight(.medium)
                .foregroundStyle(tone)
            if let checks {
                HStack(spacing: 6) {
                    MailCheckPill(name: "SPF", value: checks.spf)
                    MailCheckPill(name: "DKIM", value: checks.dkim)
                    MailCheckPill(name: "DMARC", value: checks.dmarc)
                }
            } else {
                Text("The receiving server recorded no SPF, DKIM or DMARC result.")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedForeground)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mail.senderChecks")
    }

    private var title: String {
        guard let checks else { return "Sender not checked" }
        if checks.verified { return "Sender verified: DMARC passed for \(checks.dmarcFrom ?? "its domain")" }
        return "Sender not verified"
    }

    private var symbol: String {
        guard let checks else { return "questionmark.circle" }
        return checks.verified ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var tone: Color {
        guard let checks else { return Palette.mutedForeground }
        return checks.verified ? Palette.status(.ok) : Palette.status(.stale)
    }
}

/// "SPF pass", the value green when it passed.
struct MailCheckPill: View {
    let name: String
    let value: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(name)
                .foregroundStyle(Palette.mutedForeground)
            Text(verbatim: value ?? "none")
                .foregroundStyle(value == "pass" ? Palette.status(.ok) : (value == nil ? Palette.mutedForeground : Palette.status(.stale)))
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(.separator))
    }
}

/// The server's warnings: a From line that may not be the sender, an unverified sender, replies
/// that go elsewhere, hidden content.
struct MailWarningsView: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Label {
                    Text(verbatim: warning)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.status(.stale))
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.status(.stale).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.status(.stale).opacity(0.4)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mail.warnings")
    }
}

/// What the cleaner removed, then the body as plain text.
struct MailBodyView: View {
    let message: MailMessageDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: MailFormat.cleaned(message.removed, source: message.bodySource) + " Links are not clickable here.")
                .font(.caption)
                .foregroundStyle(Palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mail.removed")
            Group {
                if message.body.isEmpty {
                    Text("This message has no text to show.")
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: message.body)
                        .textSelection(.enabled)
                }
            }
            .font(.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .accessibilityIdentifier("mail.body")
            if message.truncated {
                Text("The message is long and was cut; open it in your mail app for the rest.")
                    .font(.caption)
                    .foregroundStyle(Palette.mutedForeground)
            }
        }
    }
}

/// Attachment names, types and sizes (the API serves nothing more).
struct MailAttachmentsView: View {
    let attachments: [MailAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Attachments (names only; open them in your mail app)")
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.mutedForeground)
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: attachment.filename.isEmpty ? "(unnamed)" : attachment.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: "\(attachment.contentType) · \(MailFormat.bytes(attachment.size))")
                        .font(.caption)
                        .foregroundStyle(Palette.mutedForeground)
                }
                .font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
