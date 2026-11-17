import EventKit
import Foundation

/// Everything the runtime touches outside itself: EventKit (permissions, calendars, reminders,
/// change notifications), the network and the Keychain. `live` is the real Mac; tests build
/// one from fakes, so no test touches EventKit, the network or the Keychain.
public struct HelperEnvironment: @unchecked Sendable {
    public var permissions: PermissionsProvider
    public var makeCalendarSource: () -> CalendarSource
    public var makeReminderStore: (_ alarmAtDueTime: Bool) -> ReminderStore
    public var transport: HTTPTransport
    public var keychain: KeychainStore
    /// Calls `onChange` on every Calendar or Reminders change; returns a function that stops it.
    public var observeChanges: (_ onChange: @escaping @Sendable () -> Void) -> (() -> Void)
    /// Local days (calendar window, all-day events) and the payloads' UTC offset.
    public var calendar: Calendar

    public init(permissions: PermissionsProvider,
                makeCalendarSource: @escaping () -> CalendarSource,
                makeReminderStore: @escaping (_ alarmAtDueTime: Bool) -> ReminderStore,
                transport: HTTPTransport,
                keychain: KeychainStore,
                observeChanges: @escaping (_ onChange: @escaping @Sendable () -> Void) -> (() -> Void),
                calendar: Calendar = .current) {
        self.permissions = permissions
        self.makeCalendarSource = makeCalendarSource
        self.makeReminderStore = makeReminderStore
        self.transport = transport
        self.keychain = keychain
        self.observeChanges = observeChanges
        self.calendar = calendar
    }

    /// The real Mac. The one `EKEventStore` is created lazily, on first EventKit use.
    public static func live(config: HelperConfig) -> HelperEnvironment {
        let box = EventStoreBox()
        return HelperEnvironment(
            permissions: EventKitPermissions(store: { box.store }),
            makeCalendarSource: { EventKitCalendarSource(store: box.store) },
            makeReminderStore: { alarm in EventKitReminderStore(store: box.store, alarmAtDueTime: alarm) },
            transport: URLSessionTransport(timeout: config.server.timeout_seconds),
            keychain: SystemKeychain(),
            observeChanges: { onChange in
                let token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: box.store, queue: nil) { _ in
                    onChange()
                }
                return { NotificationCenter.default.removeObserver(token) }
            }
        )
    }
}

/// The helper's single `EKEventStore`, created on first use.
final class EventStoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _store: EKEventStore?

    var store: EKEventStore {
        lock.withLock {
            if let s = _store { return s }
            let s = EKEventStore()
            _store = s
            return s
        }
    }
}
