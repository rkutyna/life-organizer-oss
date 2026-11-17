import Foundation
import OrganizerAPI
import Testing

/// The Reminders wire format as the server sends it (shapes copied from the demo server, values
/// fictional), and the facade's helpers and request bodies.
@Suite("Reminders decoding")
struct RemindersDecodingTests {
    static let reminderJSON = #"""
    {
      "id": 7, "source": "apple", "account_id": null, "external_id": null,
      "list_id": "list-home", "list_title": "Home", "list_color": "#FF9500",
      "title": "Call Acme support", "notes": "Ask for Jane Doe",
      "due_date": "2026-11-17", "due_time": "11:00:00", "priority": 1,
      "completed": false, "completed_at": null, "url": null,
      "modified_at": "2026-11-16T03:16:50.058412Z", "mirrored_at": null, "in_provider": false,
      "sync": {
        "state": "failed",
        "pending_fields": ["title", "due"],
        "pending_ops": [
          {"id": 31, "reminder_id": 7, "kind": "create", "applier": "helper",
           "fields": {"title": "Call Acme support", "due_date": "2026-11-17", "due_time": "11:00", "priority": 1, "notes": null},
           "state": "failed", "error": "The list is read-only", "conflicts": [],
           "created_at": "2026-11-16T03:10:00Z", "created_by": "me", "applied_at": null},
          {"id": 32, "reminder_id": 7, "kind": "update", "applier": "helper",
           "fields": {"title": "Call Acme support"}, "state": "pending", "error": null,
           "conflicts": [{"field": "title", "kept": "provider", "provider_value": "a", "organizer_value": "b"}],
           "created_at": "2026-11-16T03:12:00Z", "created_by": "claude", "applied_at": null}
        ],
        "waiting_since": "2026-11-16T03:10:00Z",
        "error": "The list is read-only"
      }
    }
    """#

    static let listsJSON = #"""
    [
      {"id": "list-home", "title": "Home", "color": "#FF9500", "source": "apple", "account_id": null,
       "account": "iCloud", "account_type": "caldav", "writable": true, "is_default": true,
       "supports_time": true, "supports_priority": true, "open_count": 4},
      {"id": "shared", "title": "Shared", "color": null, "source": "apple", "account_id": null,
       "account": "iCloud", "account_type": null, "writable": false, "is_default": false,
       "supports_time": true, "supports_priority": true, "open_count": 1},
      {"id": "g-1", "title": "My Tasks", "color": null, "source": "google", "account_id": 3,
       "account": "jane@example.com", "account_type": "google", "writable": true, "is_default": false,
       "supports_time": false, "supports_priority": false, "open_count": 2}
    ]
    """#

    static let statusJSON = #"""
    {
      "helper": {"source": "reminders", "label": "Mac helper (Apple Reminders)", "state": "ok",
                 "last_success_at": "2026-11-17T03:16:50.058412Z", "last_attempt_at": null,
                 "last_error": null, "last_error_at": null, "stale_after_seconds": 2700},
      "google": [{"account_id": 3, "label": "jane@example.com",
                  "freshness": {"source": "reminders:3", "label": "Google Tasks", "state": "error",
                                "last_success_at": null, "last_attempt_at": null,
                                "last_error": "token revoked", "last_error_at": null, "stale_after_seconds": 900}}],
      "last_ops_poll_at": null, "helper_polling": false,
      "pending_ops": 1, "failed_ops": 1, "oldest_pending_at": "2026-11-16T03:10:00Z",
      "waiting_for_device": true
    }
    """#

    @Test func decodesAReminderWithItsQueuedOps() throws {
        let reminder = try APIJSON.decoder().decode(ReminderOut.self, from: Data(Self.reminderJSON.utf8))
        #expect(reminder.dueDate == LocalDate("2026-11-17"))
        #expect(reminder.dueTime == LocalTime(hour: 11, minute: 0))
        #expect(reminder.sync.state == .failed)
        #expect(reminder.sync.pendingFields == [.title, .due])
        #expect(reminder.sync.pendingOps.count == 2)
        #expect(reminder.failedOps.map(\.id) == [31])
        #expect(reminder.sync.pendingOps[1].conflicts.first?.kept == .provider)
        #expect(reminder.isSyncInFlight == false)
        #expect(reminder.sync.waitingSince != nil)
    }

    @Test func waitingForDeviceIsInFlight() throws {
        // The sync state is the first "state" in the text (the ops come after it).
        var json = Self.reminderJSON
        let first = try #require(json.range(of: #""state": "failed""#))
        json.replaceSubrange(first, with: #""state": "waiting_for_device""#)
        let reminder = try APIJSON.decoder().decode(ReminderOut.self, from: Data(json.utf8))
        #expect(reminder.sync.state == .waitingForDevice)
        #expect(reminder.isSyncInFlight)
    }

    @Test func decodesListsAndFindsReadOnlyOnes() throws {
        let lists = try APIJSON.decoder().decode([ReminderListOut].self, from: Data(Self.listsJSON.utf8))
        #expect(lists.count == 3)
        #expect(lists.list("g-1")?.source == .google)
        #expect(lists.list("g-1")?.supportsTime == false)
        #expect(lists.isReadOnly("shared"))
        #expect(!lists.isReadOnly("list-home"))
        #expect(!lists.isReadOnly(nil))
        #expect(!lists.isReadOnly("gone"))
    }

    @Test func decodesTheStatus() throws {
        let status = try APIJSON.decoder().decode(ReminderStatusOut.self, from: Data(Self.statusJSON.utf8))
        #expect(status.helper.state == .ok)
        #expect(status.google.first?.freshness.state == .error)
        #expect(status.waitingForDevice)
        #expect(status.pendingOps == 1 && status.failedOps == 1)
    }

    @Test func createLeavesOutWhatIsNotSet() throws {
        let body = ReminderCreate(title: "Buy stamps", listId: .value("list-home"), dueDate: .value(LocalDate("2026-11-20")!))
        let json = try #require(try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(body)) as? [String: Any])
        #expect(json["title"] as? String == "Buy stamps")
        #expect(json["list_id"] as? String == "list-home")
        #expect(json["due_date"] as? String == "2026-11-20")
        #expect(json["due_time"] == nil)
        #expect(json["priority"] == nil)
    }

    @Test func updateSendsNullToClear() throws {
        var changes = ReminderUpdate()
        changes.dueDate = .null
        let json = try #require(try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(changes)) as? [String: Any])
        #expect(json.keys.sorted() == ["due_date"])
        #expect(json["due_date"] is NSNull)
    }
}
