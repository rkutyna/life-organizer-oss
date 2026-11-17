import AppKit
import Foundation
import OrganizerAPI
import OrganizerCore
import OrganizerTestSupport
import SwiftUI
import Testing

@testable import OrganizerUI

/// Draws Mac screens into PNGs without a visible window or screen-recording permission. Data is
/// loaded before drawing, since an offscreen window never runs `.task`. A snapshot test runs
/// only when both variables are set:
///
///     ORGANIZER_TEST_SERVER=http://localhost:8680 ORGANIZER_TEST_TOKEN=... \
///       ORGANIZER_SNAPSHOT_DIR=/tmp/mac swift test --filter Snapshot
///
/// Add `ORGANIZER_SNAPSHOT_APPEARANCE=dark` (and another directory) for dark mode. The server
/// must be a local demo one (`python -m app.demo_seed`); snapshots only read from it.
@MainActor
enum Snapshot {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let enabled = environment["ORGANIZER_SNAPSHOT_DIR"] != nil && environment["ORGANIZER_TEST_SERVER"] != nil
    static var directory: URL { URL(fileURLWithPath: environment["ORGANIZER_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()) }
    static var server: URL { URL(string: environment["ORGANIZER_TEST_SERVER"] ?? "http://localhost:8680")! }

    /// An app environment pointed at the test server with the test token, and a throwaway cache.
    static func app() throws -> AppEnvironment {
        let host = server.host() ?? ""
        try #require(ServerConfig.isLoopback(host), "snapshots only read from a local server, not \(host)")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = server
        return AppEnvironment(
            resolveServer: { .init(url: url, source: .environment) },
            tokenStore: MemoryTokenStore(environment["ORGANIZER_TEST_TOKEN"]),
            accessSecretStore: MemoryTokenStore(),
            accessIDDefaults: UserDefaults(suiteName: "organizer-snapshots-\(UUID().uuidString)") ?? .standard,
            environment: [:],
            cache: temporaryCache()
        )
    }

    static var appearance: NSAppearance? {
        environment["ORGANIZER_SNAPSHOT_APPEARANCE"] == "dark" ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
    }

    /// Draws `view` at `size` into `<directory>/<name>.png`.
    static func render(_ view: some View, size: CGSize, name: String) throws {
        let backed = view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: backed)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        // A key window draws list selections in their accent color (not as a black block).
        window.makeKey()
        let until = Date().addingTimeInterval(2)
        while Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

@Suite(.enabled(if: Snapshot.enabled))
@MainActor
struct ShellSnapshotTests {
    @Test func renderShellAndSettings() async throws {
        let app = try Snapshot.app()
        try Snapshot.render(SettingsForm().environment(app), size: CGSize(width: 560, height: 760), name: "mac-settings")
        try Snapshot.render(FirstLaunchView {}.environment(app), size: CGSize(width: 560, height: 420), name: "mac-first-launch")
    }
}
