import SwiftUI

/// What ⌘R refreshes: the screen on show publishes its scaffold's refresh (`LoadingScaffold`).
public struct ScreenRefreshAction {
    let run: () async -> Void
}

extension FocusedValues {
    /// The visible screen's refresh, for View › Refresh (⌘R).
    @Entry public var screenRefresh: ScreenRefreshAction?
}

import AppKit

/// The Mac menus. Add with `.commands { OrganizerCommands() }` on the main WindowGroup.
///
/// | Keys        | Command                                                      |
/// |-------------|--------------------------------------------------------------|
/// | ⌘1 … ⌘4     | Go › Calendar, Reminders, Jobs, Mail                          |
/// | g, then a letter | the web's go-to keys: c r j m s (`GoKeySequence`)       |
/// | ⌘N          | File › New Reminder: the Reminders quick-add field, focused   |
/// | ⌥⌘N         | File › New Window                                            |
/// | ⌘R          | View › Refresh: the screen on show                           |
/// | ⌘,          | Settings (the Settings scene)                                |
public struct OrganizerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.screenRefresh) private var refresh

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Reminder") {
                MacShell.show(.reminders, openWindow: openWindow)
                QuickAddFocus.request()
            }
            .keyboardShortcut("n")
            Button("New Window") {
                openWindow(id: MacShell.mainWindowID)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandGroup(before: .sidebar) {
            Button("Refresh") {
                guard let refresh else { return }
                Task { await refresh.run() }
            }
            .keyboardShortcut("r")
            .disabled(refresh == nil)
            Divider()
        }

        CommandMenu("Go") {
            ForEach(Array(MacShell.goModules.enumerated()), id: \.element.id) { index, module in
                Button(module.label) {
                    MacShell.show(module.id, openWindow: openWindow)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
    }
}

/// The web's "g, then a letter" go-to keys (web/src/app/Shell.tsx), in the main window: g c
/// Calendar, g r Reminders, g j Jobs, g m Mail, g s Settings. Menus cannot show a two-key
/// sequence, so a local key monitor reads it; it ignores keys while a text field has focus and
/// any key with ⌘, ⌃ or ⌥ held. Call `install()` once at launch.
@MainActor
public enum GoKeySequence {
    /// The web modules' `shortcut` letters.
    static let letters: [Character: ModuleID] = [
        "c": .calendar, "r": .reminders, "j": .jobs, "m": .mail, "s": .settings,
    ]
    /// How long after "g" the letter may come (the web's 1 s).
    static let window: TimeInterval = 1

    private static var monitor: Any?
    private static var pendingSince: Date?

    public static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    /// True when the key was part of a go-to sequence (and is swallowed).
    static func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let window = event.window, MacShell.isMainWindow(window),
              !(window.firstResponder is NSText), !(window.firstResponder is NSTextField),
              let key = event.charactersIgnoringModifiers?.lowercased().first
        else {
            pendingSince = nil
            return false
        }
        switch step(key, now: Date()) {
        case .ignore:
            return false
        case .started:
            return true
        case .go(let module):
            MacShell.selection = module
            return true
        }
    }

    enum Step: Equatable {
        /// Not part of a sequence: the key goes on as usual.
        case ignore
        /// "g": the next key may name a module.
        case started
        case go(ModuleID)
    }

    /// The sequence's state machine.
    static func step(_ key: Character, now: Date) -> Step {
        if let since = pendingSince {
            pendingSince = nil
            if now.timeIntervalSince(since) <= window, let module = letters[key] { return .go(module) }
            return .ignore
        }
        if key == "g" {
            pendingSince = now
            return .started
        }
        return .ignore
    }

    static func reset() { pendingSince = nil }
}
