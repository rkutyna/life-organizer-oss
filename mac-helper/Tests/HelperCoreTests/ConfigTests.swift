import XCTest
@testable import HelperCore

final class ConfigTests: XCTestCase {
    func testAnEmptyConfigTakesTheDefaults() throws {
        let c = try JSONDecoder().decode(HelperConfig.self, from: Data("{}".utf8))
        XCTAssertNil(c.serverURL, "no default host")
        XCTAssertNil(c.server.token)
        XCTAssertEqual(c.server.timeout_seconds, 30)
        XCTAssertEqual(c.bundle_id, "com.lifeorganizerformac.helper")
        XCTAssertEqual(c.launchAgentLabel, "com.lifeorganizerformac.helper")
        XCTAssertEqual(c.keychainService, "com.lifeorganizerformac.helper")
        XCTAssertEqual(c.keychainAccount, "ingest-token")
        XCTAssertEqual(c.heartbeat_seconds, 900)
        XCTAssertTrue(c.calendar.enabled)
        XCTAssertEqual(c.calendar.interval_seconds, 300)
        XCTAssertEqual(c.calendar.past_days, 365)
        XCTAssertTrue(c.reminders.enabled && c.reminders.apply_ops && c.reminders.alarm_at_due_time)
        XCTAssertEqual(c.reminders.ops_poll_seconds, 30)
        XCTAssertEqual(c.reminders.snapshot_seconds, 180)
        XCTAssertEqual(c.reminders.completed_days, 30)
        XCTAssertEqual(c.logPath, Paths.logFile)
    }

    func testPartialOverrides() throws {
        let json = """
        {"server": {"url": "https://organizer.example.com/", "token": "t0k"},
         "bundle_id": "org.example.helper", "keychain": {"account": "other"},
         "calendar": {"enabled": false}, "reminders": {"apply_ops": false, "completed_days": 7},
         "host": "kitchen-mac", "log_path": "~/helper-test.log"}
        """
        let c = try JSONDecoder().decode(HelperConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.serverURL?.absoluteString, "https://organizer.example.com")
        XCTAssertEqual(c.server.token, "t0k")
        XCTAssertEqual(c.launchAgentLabel, "org.example.helper", "the label follows bundle_id")
        XCTAssertEqual(c.keychainService, "org.example.helper", "the Keychain service follows bundle_id")
        XCTAssertEqual(c.keychainAccount, "other")
        XCTAssertFalse(c.calendar.enabled)
        XCTAssertEqual(c.calendar.interval_seconds, 300)
        XCTAssertFalse(c.reminders.apply_ops)
        XCTAssertTrue(c.reminders.enabled)
        XCTAssertEqual(c.reminders.completed_days, 7)
        XCTAssertEqual(c.hostName, "kitchen-mac")
        XCTAssertEqual(c.logPath, NSHomeDirectory() + "/helper-test.log")

        let explicit = try JSONDecoder().decode(HelperConfig.self, from: Data(#"""
        {"launch_agent_label": "org.example.agent", "keychain": {"service": "org.example.keys", "account": ""}}
        """#.utf8))
        XCTAssertEqual(explicit.launchAgentLabel, "org.example.agent")
        XCTAssertEqual(explicit.keychainService, "org.example.keys")
        XCTAssertEqual(explicit.keychainAccount, "ingest-token")
    }

    func testServerURLMustBeHTTP() throws {
        for (url, ok) in [("https://organizer.example.com", true), ("http://localhost:8600", true),
                          ("http://192.0.2.10:8600", false), ("organizer.example.com", false),
                          ("ftp://organizer.example.com", false), ("  ", false)] {
            var c = HelperConfig()
            c.server.url = url
            XCTAssertEqual(c.serverURL != nil, ok, url)
        }
    }

    func testANullTokenIsAbsent() throws {
        let c = try JSONDecoder().decode(HelperConfig.self, from: Data(#"{"server": {"url": "https://organizer.example.com", "token": null}}"#.utf8))
        XCTAssertNil(c.server.token)
    }

    func testExampleConfigParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("helper.example.json")
        let c = try JSONDecoder().decode(HelperConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(c.serverURL?.absoluteString, "https://organizer.example.com")
        XCTAssertNil(c.server.token, "the example ships a null token")
        XCTAssertEqual(c.bundle_id, Paths.defaultBundleId)
        XCTAssertEqual(c.launchAgentLabel, Paths.defaultBundleId)
        XCTAssertEqual(c.keychainService, Paths.defaultBundleId)
        XCTAssertTrue(c.calendar.enabled && c.reminders.enabled)
    }

    func testInvalidJSONIsALoadError() throws {
        let path = tempDir().appendingPathComponent("helper.json").path
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try HelperConfig.load(path: path)) { error in
            guard case HelperConfig.LoadError.invalid = error else { return XCTFail("\(error)") }
        }
        let missing = try HelperConfig.load(path: path + ".missing")
        XCTAssertFalse(missing.exists)
    }

    func testTheEmbeddedInfoPlistIsNeutral() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, Paths.defaultBundleId)
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, HelperVersion.string, "keep the plist's version in step")
        XCTAssertNotNil(plist["NSCalendarsFullAccessUsageDescription"])
        XCTAssertNotNil(plist["NSRemindersFullAccessUsageDescription"])
        let usage = plist.keys.filter { $0.hasSuffix("UsageDescription") }
        XCTAssertEqual(Set(usage), ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription",
                                    "NSRemindersFullAccessUsageDescription", "NSRemindersUsageDescription",
                                    "NSLocalNetworkUsageDescription"])
    }
}

final class CLIParsingTests: XCTestCase {
    func testCommands() throws {
        XCTAssertEqual(try CLI.parse(["run"]).command, .run)
        XCTAssertEqual(try CLI.parse(["doctor"]).command, .doctor)
        XCTAssertEqual(try CLI.parse(["status"]).command, .status)
        XCTAssertEqual(try CLI.parse(["set-token"]).command, .setToken)
        XCTAssertEqual(try CLI.parse(["uninstall"]).command, .uninstall)
        XCTAssertEqual(try CLI.parse(["version"]).command, .version)
        XCTAssertEqual(try CLI.parse([]).command, .help)
        XCTAssertEqual(try CLI.parse(["-h"]).command, .help)
        XCTAssertEqual(try CLI.parse(["install", "--print"]).command, .install(binary: nil, printOnly: true))
        XCTAssertEqual(try CLI.parse(["install", "--binary", "/opt/bin/organizer-helper"]).command,
                       .install(binary: "/opt/bin/organizer-helper", printOnly: false))
    }

    func testOptions() throws {
        let o = try CLI.parse(["--config", "/tmp/helper-test.json", "doctor", "-v"])
        XCTAssertEqual(o.configPath, "/tmp/helper-test.json")
        XCTAssertTrue(o.verbose)
        XCTAssertEqual(try CLI.parse(["doctor"]).configPath, Paths.configFile)
        XCTAssertEqual(try CLI.parse(["--config", "~/x.json", "status"]).configPath, NSHomeDirectory() + "/x.json")
    }

    func testDefaultsStayClearOfAnotherInstalledHelper() {
        // The default config, bundle id and label are this project's own, so a copy of the
        // helper never reads or replaces another helper's config, Keychain item or LaunchAgent.
        XCTAssertTrue(Paths.configFile.hasSuffix("/.config/life-organizer-for-mac/helper.json"), Paths.configFile)
        XCTAssertEqual(Paths.defaultBundleId, "com.lifeorganizerformac.helper")
    }

    func testErrors() {
        XCTAssertThrowsError(try CLI.parse(["once"]), "once is gone")
        XCTAssertThrowsError(try CLI.parse(["frobnicate"]))
        XCTAssertThrowsError(try CLI.parse(["run", "extra"]))
        XCTAssertThrowsError(try CLI.parse(["--config"]))
    }

    func testLaunchAgentPlist() throws {
        let data = try LaunchAgent.plist(binary: "/usr/local/bin/organizer-helper", label: "org.example.helper", configPath: Paths.configFile)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        XCTAssertEqual(obj["Label"] as? String, "org.example.helper")
        XCTAssertEqual(obj["ProgramArguments"] as? [String], ["/usr/local/bin/organizer-helper", "run"])
        XCTAssertEqual(obj["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(obj["KeepAlive"] as? Bool, true)
        XCTAssertEqual(obj["LimitLoadToSessionType"] as? String, "Aqua")

        let custom = try LaunchAgent.plist(binary: "/usr/local/bin/organizer-helper", label: "x", configPath: "/tmp/other.json")
        let args = (try PropertyListSerialization.propertyList(from: custom, format: nil) as! [String: Any])["ProgramArguments"] as? [String]
        XCTAssertEqual(args, ["/usr/local/bin/organizer-helper", "run", "--config", "/tmp/other.json"])
    }

    func testLaunchctlPrintParsing() {
        let out = "gui/501/x = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n}"
        XCTAssertEqual(LaunchAgent.parsePrint(out), "state = running, pid = 4242")
        XCTAssertEqual(LaunchAgent.parsePrint("nothing"), "state = ?")
    }
}
