// swift-tools-version:6.0
import Foundation
import PackageDescription

// The Info.plist is linked into the executable's __TEXT,__info_plist section, so the bare
// (unbundled) binary carries a bundle identifier and the Calendars and Reminders usage strings
// that macOS needs before it shows the permission prompts.
//
// The path is absolute (computed from this file's location) and passed as one linker argument,
// so a checkout under a directory whose name has spaces still links. `scripts/release.sh` points
// ORGANIZER_HELPER_INFO_PLIST at a generated copy when it builds with another bundle id.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let infoPlist = ProcessInfo.processInfo.environment["ORGANIZER_HELPER_INFO_PLIST"].flatMap { $0.isEmpty ? nil : $0 }
    ?? packageDir + "/Resources/Info.plist"

let package = Package(
    name: "organizer-helper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "organizer-helper", targets: ["organizer-helper"]),
        // The helper as a library, so the Mac app (apple/) can run it in-process.
        .library(name: "HelperCore", targets: ["HelperCore"]),
    ],
    targets: [
        .target(
            name: "HelperCore",
            path: "Sources/HelperCore",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "organizer-helper",
            dependencies: ["HelperCore"],
            path: "Sources/organizer-helper",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ]),
            ]
        ),
        .testTarget(
            name: "HelperCoreTests",
            dependencies: ["HelperCore"],
            path: "Tests/HelperCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
