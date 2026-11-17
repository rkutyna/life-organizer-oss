// swift-tools-version:6.2
// OrganizerKit: everything the Mac app shares. The Xcode app target is a thin shell over these
// libraries.
//
//   OrganizerAPI   generated API types and operations, the HTTP client (bearer token), the
//                  response cache, module facades (client.reminders, client.jobs, ...).
//                  Foundation only.
//   OrganizerCore  app configuration (server address, token in the Keychain), Loadable/Resource
//                  state, the freshness rule, date formatting, the quick-add parser. No views.
//   OrganizerUI    SwiftUI: design system, app shell and module registry, one folder per
//                  module under Sources/OrganizerUI/Features/.
import PackageDescription

let package = Package(
    name: "OrganizerKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OrganizerAPI", targets: ["OrganizerAPI"]),
        .library(name: "OrganizerCore", targets: ["OrganizerCore"]),
        .library(name: "OrganizerUI", targets: ["OrganizerUI"]),
    ],
    targets: [
        .target(name: "OrganizerAPI"),
        .target(name: "OrganizerCore", dependencies: ["OrganizerAPI"]),
        .target(
            name: "OrganizerUI",
            dependencies: ["OrganizerAPI", "OrganizerCore"],
            // Views and stores live on the main actor; pure helpers are marked `nonisolated`.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Test helpers (StubServer: a fake API with canned responses). Tests only.
        .target(name: "OrganizerTestSupport", dependencies: ["OrganizerAPI"], path: "Tests/Support"),
        .testTarget(name: "OrganizerAPITests", dependencies: ["OrganizerAPI", "OrganizerTestSupport"]),
        .testTarget(
            name: "OrganizerCoreTests",
            dependencies: ["OrganizerCore", "OrganizerTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OrganizerUITests",
            dependencies: ["OrganizerUI", "OrganizerCore", "OrganizerTestSupport"]
        ),
    ]
)
