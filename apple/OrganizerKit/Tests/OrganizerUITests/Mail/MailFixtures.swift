import Foundation

/// Synthetic mail responses shaped like the server's (`server/app/modules/mail/router.py`):
/// snake_case, `from` as a key, `untrusted: true` everywhere. Fictional people and domains.
enum MailFixtures {
    static let accountsJSON = #"""
    [
      {"id": 2, "kind": "imap", "label": "Work", "address": "jane@example.com", "state": "ok",
       "as_of": "2026-11-16T15:00:00Z", "error": null},
      {"id": 3, "kind": "gmail", "label": "Personal", "address": "jane.doe@example.org", "state": "error",
       "as_of": null, "error": "Google refused the stored sign-in"}
    ]
    """#

    static func header(id: Int, account: Int = 2, folder: String = "inbox", from: String = "Acme Recruiting",
                       address: String = "jobs@acme.example.com", subject: String = "Next steps",
                       date: String = "2026-11-16T14:05:00Z", warning: String? = nil) -> String {
        let warningJSON = warning.map { "\"\($0)\"" } ?? "null"
        return #"""
        {"id": \#(id), "account": \#(account), "folder": "\#(folder)",
         "from": {"name": "\#(from)", "address": "\#(address)"}, "sender_warning": \#(warningJSON),
         "to": [{"name": "Jane Doe", "address": "jane@example.com"}], "cc": [],
         "subject": "\#(subject)", "date": "\#(date)", "size": 4096,
         "message_id": "<m\#(id)@example.com>", "in_reply_to": null, "untrusted": true}
        """#
    }

    static func list(_ headers: [String]) -> String {
        #"{"accounts": \#(accountsJSON), "messages": [\#(headers.joined(separator: ","))], "untrusted": true}"#
    }

    static let inbox = list([
        header(id: 1),
        header(id: 2, from: "Jane Doe", address: "jane@example.org", subject: "Coffee next week?",
               date: "2026-11-15T09:00:00Z"),
        header(id: 3, account: 3, from: "Acme Billing", address: "billing@acme.example.net",
               subject: "Your invoice", date: "2026-11-14T09:00:00Z",
               warning: "The display name names another address than the one it came from."),
    ])

    static let empty = #"{"accounts": [], "messages": [], "untrusted": true}"#

    /// A read message: HTML converted to text, sender checks that verify, one warning, an
    /// attachment, and what the cleaner removed.
    static let detail = #"""
    {"id": 1, "account": 2, "folder": "inbox",
     "from": {"name": "Acme Recruiting", "address": "jobs@acme.example.com"}, "sender_warning": null,
     "to": [{"name": "Jane Doe", "address": "jane@example.com"}],
     "cc": [{"name": "", "address": "team@acme.example.com"}],
     "subject": "Next steps", "date": "2026-11-16T14:05:00Z", "size": 4096,
     "message_id": "<m1@example.com>", "in_reply_to": null, "untrusted": true,
     "reply_to": [{"name": "Scheduling", "address": "calendar@scheduler.example.net"}],
     "body": "Hi Jane,\n\nThanks for applying. Pick a time here: https://scheduler.example.net/acme\n\nAcme Recruiting",
     "body_source": "html", "truncated": false,
     "attachments": [{"filename": "role.pdf", "content_type": "application/pdf", "size": 52310}],
     "sender_checks": {"verified": true, "spf": "pass", "dkim": "pass", "dmarc": "pass",
                       "dmarc_from": "acme.example.com"},
     "removed": {"hidden_chars": 212, "invisible_chars": 14},
     "warnings": ["Replies go to calendar@scheduler.example.net, not the sender's domain."]}
    """#

    /// A message whose receiving server recorded no checks.
    static let unchecked = #"""
    {"id": 3, "account": 3, "folder": "inbox",
     "from": {"name": "Acme Billing", "address": "billing@acme.example.net"},
     "sender_warning": "The display name names another address than the one it came from.",
     "to": [], "cc": [], "subject": "", "date": "2026-11-14T09:00:00Z", "size": null,
     "message_id": null, "in_reply_to": null, "untrusted": true, "reply_to": [],
     "body": "", "body_source": "none", "truncated": true, "attachments": [],
     "sender_checks": null, "removed": {"hidden_chars": 0, "invisible_chars": 0},
     "warnings": ["The sender could not be verified (the receiving server recorded no SPF, DKIM or DMARC result): the From address may not be who sent it."]}
    """#

    static let forbidden = #"{"detail": "this token lacks the mail scope"}"#
}
