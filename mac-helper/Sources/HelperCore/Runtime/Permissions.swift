import EventKit
import Foundation

/// EventKit authorization, as the helper reports it.
public enum HelperAuthorization: String, Sendable, Codable {
    case notDetermined, restricted, denied, fullAccess, writeOnly, unknown

    public init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .fullAccess: self = .fullAccess
        case .writeOnly: self = .writeOnly
        @unknown default: self = .unknown
        }
    }

    /// A request can still show the prompt (denied and restricted need System Settings).
    public var canRequest: Bool { self == .notDetermined || self == .writeOnly }
}

/// Calendars and Reminders access, behind a protocol so the runtime is tested without EventKit.
public protocol PermissionsProvider: Sendable {
    /// Never prompts.
    func calendars() -> HelperAuthorization
    /// Never prompts.
    func reminders() -> HelperAuthorization
    /// Asks for full access (shows the prompt the first time). True when granted.
    func requestCalendars() async -> Bool
    func requestReminders() async -> Bool
}

/// The real permissions, for this process's responsible app (the helper binary when launchd
/// runs it; the terminal app when run from a shell).
public final class EventKitPermissions: PermissionsProvider, @unchecked Sendable {
    private let store: @Sendable () -> EKEventStore

    public init(store: @escaping @Sendable () -> EKEventStore) { self.store = store }

    public func calendars() -> HelperAuthorization { HelperAuthorization(EKEventStore.authorizationStatus(for: .event)) }
    public func reminders() -> HelperAuthorization { HelperAuthorization(EKEventStore.authorizationStatus(for: .reminder)) }

    public func requestCalendars() async -> Bool {
        do { return try await store().requestFullAccessToEvents() } catch {
            log.error("calendar: requestFullAccessToEvents failed: \(error)")
            return false
        }
    }

    public func requestReminders() async -> Bool {
        do { return try await store().requestFullAccessToReminders() } catch {
            log.error("reminders: requestFullAccessToReminders failed: \(error)")
            return false
        }
    }
}
