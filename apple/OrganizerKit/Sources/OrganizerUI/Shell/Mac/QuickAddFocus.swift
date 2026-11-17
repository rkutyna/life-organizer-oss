import Foundation

/// File › New Reminder (⌘N): asks the Reminders screen to focus its quick-add field. The menu
/// bumps `requests`; the screen watches it, so a request made before the screen appears is
/// still honored once it does.
@MainActor
@Observable
public final class QuickAddFocus {
    public static let shared = QuickAddFocus()

    /// Incremented by every request.
    public private(set) var requests = 0

    public static func request() { shared.requests += 1 }
}
