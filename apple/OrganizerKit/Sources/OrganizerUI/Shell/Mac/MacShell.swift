import AppKit
import SwiftUI

/// Mac window plumbing shared by the menu bar extra and the menus: which module the window
/// shows, and bringing the main window forward (or opening one).
@MainActor
public enum MacShell {
    /// The main `WindowGroup`'s id (`WindowGroup(id: MacShell.mainWindowID)` in the app).
    public static let mainWindowID = "main"

    /// RootView's selection (`@AppStorage("shell.selection")`). Writing it switches the window's
    /// module, the same as clicking the sidebar, so the menus need no hook in RootView.
    static let selectionKey = "shell.selection"

    /// The module the window shows.
    public static var selection: ModuleID {
        get { UserDefaults.standard.string(forKey: selectionKey).flatMap(ModuleID.init(rawValue:)) ?? .calendar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectionKey) }
    }

    /// The modules the Go menu lists, in sidebar order (Settings has ⌘, instead).
    static var goModules: [AppModule] { ModuleRegistry.all.filter { $0.id != .settings } }

    /// Selects `module` (if given) and brings the main window forward, opening one if none is open.
    public static func show(_ module: ModuleID? = nil, openWindow: OpenWindowAction) {
        if let module { selection = module }
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: mainWindowID)
        }
    }

    /// The first open main window.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { ($0.isVisible || $0.isMiniaturized) && isMainWindow($0) }
    }

    /// A window of the main WindowGroup. SwiftUI names them after the group's id
    /// (`main-AppWindow-1`); failing that, any document-style window that is not Settings (the
    /// menu bar extra's window is a panel).
    static func isMainWindow(_ window: NSWindow) -> Bool {
        let id = window.identifier?.rawValue ?? ""
        if id.hasPrefix(mainWindowID) { return true }
        return !(window is NSPanel) && window.canBecomeMain && !id.localizedCaseInsensitiveContains("settings")
    }
}

extension View {
    /// The main window's size limits: room for the sidebar and a module screen side by side.
    public func macMainWindowFrame() -> some View {
        frame(minWidth: 820, idealWidth: 1200, minHeight: 560, idealHeight: 800)
    }
}
