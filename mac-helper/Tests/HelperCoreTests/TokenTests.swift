import XCTest
@testable import HelperCore

/// Collects a CLI run's output.
final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var _out: [String] = []
    private var _err: [String] = []
    var out: String { lock.withLock { _out.joined(separator: "\n") } }
    var err: String { lock.withLock { _err.joined(separator: "\n") } }
    func o(_ s: String) { lock.withLock { _out.append(s) } }
    func e(_ s: String) { lock.withLock { _err.append(s) } }
}

func cliContext(world: FakeWorld, state: HelperStateFiles, output: Output, secret: String? = nil) -> CLIContext {
    CLIContext(makeEnvironment: { _ in world.environment() }, readSecret: { secret }, out: output.o, err: output.e,
               stateFiles: state, launchAgentState: { _ in nil }, signature: { nil })
}

final class TokenTests: XCTestCase {
    let service = Paths.defaultBundleId
    let account = "ingest-token"

    func testTheConfigTokenWinsOverTheKeychain() {
        let keychain = FakeKeychain([FakeKeychain.key(service, account): "from-keychain"])
        let r = TokenResolver.resolve(config: testConfig(token: "from-config"), keychain: keychain)
        XCTAssertEqual(r.token, "from-config")
        XCTAssertEqual(r.source, .config)
        XCTAssertEqual(keychain.reads, 0, "the Keychain is not read when the config has the token")
    }

    func testANullTokenFallsBackToTheKeychain() {
        let keychain = FakeKeychain([FakeKeychain.key(service, account): "from-keychain\n"])
        let r = TokenResolver.resolve(config: testConfig(token: nil), keychain: keychain)
        XCTAssertEqual(r.token, "from-keychain")
        XCTAssertEqual(r.source, .keychain(service: service, account: account))
        XCTAssertEqual(TokenResolver.resolve(config: testConfig(token: "   "), keychain: keychain).token, "from-keychain", "blank is unset")
    }

    func testTheKeychainServiceAndAccountAreConfigurable() {
        var config = testConfig(token: nil)
        config.bundle_id = "org.example.helper"
        config.keychain.account = "work-token"
        let keychain = FakeKeychain([FakeKeychain.key("org.example.helper", "work-token"): "abc"])
        XCTAssertEqual(TokenResolver.resolve(config: config, keychain: keychain).token, "abc")
        config.keychain.service = "org.example.other"
        XCTAssertNil(TokenResolver.resolve(config: config, keychain: keychain).token)
    }

    func testMissingAndUnreadableTokensSayWhy() {
        let missing = TokenResolver.resolve(config: testConfig(token: nil), keychain: FakeKeychain())
        XCTAssertNil(missing.token)
        XCTAssertTrue(missing.source.description.contains("set-token"))
        let keychain = FakeKeychain()
        keychain.failRead = -25293  // errSecAuthFailed
        let broken = TokenResolver.resolve(config: testConfig(token: nil), keychain: keychain)
        XCTAssertNil(broken.token)
        guard case .keychainError = broken.source else { return XCTFail("\(broken.source)") }
    }

    func testRequestsCarryABearerToken() async throws {
        let organizer = FakeOrganizer(token: "abc123")
        let client = ServerClient(baseURL: URL(string: "https://organizer.example.com"), tokens: TokenProvider(fixed: "abc123"),
                                  transport: organizer, retryDelays: [])
        _ = try await client.fetchReminderOps()
        let request = try XCTUnwrap(organizer.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer abc123")
        XCTAssertNil(request.headers["X-Ingest-Token"], "the old header is gone")
        XCTAssertEqual(request.path, "/api/ingest/reminders/ops")
    }

    func testABaseURLWithAPathPrefixIsKept() async throws {
        let organizer = FakeOrganizer()
        let client = ServerClient(baseURL: URL(string: "https://organizer.example.com/prefix"), tokens: TokenProvider(fixed: organizer.acceptedToken),
                                  transport: organizer, retryDelays: [])
        _ = try await client.fetchReminderOps()
        XCTAssertEqual(organizer.requests.first?.path, "/prefix/api/ingest/reminders/ops")
    }

    func testNoTokenNoRequest() async {
        let organizer = FakeOrganizer()
        let client = ServerClient(baseURL: URL(string: "https://organizer.example.com"), tokens: TokenProvider(fixed: nil),
                                  transport: organizer, retryDelays: [])
        do {
            _ = try await client.fetchReminderOps()
            XCTFail("sent without a token")
        } catch {
            XCTAssertTrue("\(error)".contains("set-token"), "\(error)")
        }
        XCTAssertTrue(organizer.requests.isEmpty)
    }

    func testARejectedTokenIsReadAgainFromTheKeychain() async throws {
        let keychain = FakeKeychain([FakeKeychain.key(service, account): "old"])
        let organizer = FakeOrganizer(token: "new")
        let tokens = TokenProvider(config: testConfig(token: nil), keychain: keychain)
        let client = ServerClient(baseURL: URL(string: "https://organizer.example.com"), tokens: tokens, transport: organizer, retryDelays: [])
        do { _ = try await client.fetchReminderOps(); XCTFail("old token accepted") } catch {
            XCTAssertTrue("\(error)".contains("401"), "\(error)")
        }
        // `set-token` stores a new token while the daemon runs.
        try keychain.write("new", service: service, account: account)
        _ = try await client.fetchReminderOps()
        XCTAssertEqual(organizer.requests.last?.headers["Authorization"], "Bearer new")
        XCTAssertEqual(keychain.reads, 2)
        _ = try await client.fetchReminderOps()
        XCTAssertEqual(keychain.reads, 2, "an accepted token is cached")
    }

    func testRetriesOnServerErrorsButNotOnClientErrors() async throws {
        let organizer = FakeOrganizer()
        organizer.forcedStatus = 503
        let client = ServerClient(baseURL: URL(string: "https://organizer.example.com"), tokens: TokenProvider(fixed: organizer.acceptedToken),
                                  transport: organizer, retryDelays: [0, 0])
        let payload = try PayloadEncoder.encode(stream: .reminders, body: RemindersBody(lists: [], default_list_id: nil, reminders: []), host: nil)
        do { try await client.deliver(payload); XCTFail("503 delivered") } catch {}
        XCTAssertEqual(organizer.requests.count, 3)
        organizer.forcedStatus = 422
        do { try await client.deliver(payload); XCTFail("422 delivered") } catch {}
        XCTAssertEqual(organizer.requests.count, 4)
    }
}

final class CLICommandTests: XCTestCase {
    var dir: URL!
    var state: HelperStateFiles { HelperStateFiles(directory: dir.appendingPathComponent("state").path) }

    override func setUp() { dir = tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func writeConfig(_ c: HelperConfig) throws -> String {
        let path = dir.appendingPathComponent("helper.json").path
        try JSONEncoder().encode(c).write(to: URL(fileURLWithPath: path))
        return path
    }

    func testSetTokenStoresItInTheKeychainAndNeverPrintsIt() async throws {
        let world = FakeWorld()
        let output = Output()
        let path = try writeConfig(testConfig(token: nil))
        let code = await CLI.main(["--config", path, "set-token"],
                                  context: cliContext(world: world, state: state, output: output, secret: "  s3cret-token\n"))
        XCTAssertEqual(code, 0, output.err)
        XCTAssertEqual(world.keychain.value(service: Paths.defaultBundleId, account: "ingest-token"), "s3cret-token")
        XCTAssertFalse(output.out.contains("s3cret"), output.out)
        XCTAssertFalse(output.err.contains("s3cret"), output.err)
        XCTAssertTrue(output.out.contains("service \(Paths.defaultBundleId), account ingest-token"), output.out)
    }

    func testSetTokenRefusesEmptyAndWhitespaceTokens() async throws {
        let path = try writeConfig(testConfig(token: nil))
        for bad in ["", "   \n", "two words"] as [String?] + [nil] {
            let world = FakeWorld()
            let output = Output()
            let code = await CLI.main(["--config", path, "set-token"], context: cliContext(world: world, state: state, output: output, secret: bad))
            XCTAssertEqual(code, 2, String(describing: bad))
            XCTAssertNil(world.keychain.value(service: Paths.defaultBundleId, account: "ingest-token"))
        }
    }

    func testSetTokenNotesThatAConfigTokenWins() async throws {
        let output = Output()
        let path = try writeConfig(testConfig(token: "in-config"))
        _ = await CLI.main(["--config", path, "set-token"], context: cliContext(world: FakeWorld(), state: state, output: output, secret: "abc"))
        XCTAssertTrue(output.out.contains("takes precedence"), output.out)
        XCTAssertFalse(output.out.contains("in-config"))
    }

    func testDoctorReportsWhereTheTokenCameFromWithoutPrintingIt() async throws {
        let world = FakeWorld()
        try world.keychain.write(world.organizer.acceptedToken, service: Paths.defaultBundleId, account: "ingest-token")
        let output = Output()
        let path = try writeConfig(testConfig(token: nil))
        let code = await CLI.main(["--config", path, "doctor"], context: cliContext(world: world, state: state, output: output))
        let text = output.out
        XCTAssertTrue(text.contains("[ ok ] ingest token: Keychain (service \(Paths.defaultBundleId), account ingest-token)"), text)
        XCTAssertTrue(text.contains("[ ok ] server: reachable, token accepted (HTTP 422)"), text)
        XCTAssertFalse(text.contains(world.organizer.acceptedToken), "doctor printed the token")
        XCTAssertTrue(world.permissions.requests.isEmpty, "doctor never asks for access")
        // The doctor's server check wrote nothing: an empty body the server rejects.
        XCTAssertEqual(world.organizer.requests.count, 1)
        XCTAssertEqual(world.organizer.requests[0].path, "/api/ingest/calendar")
        XCTAssertEqual((world.organizer.requests[0].json as? [String: Any])?.count, 0)
        _ = code  // the test binary has no embedded Info.plist, so doctor flags that and exits 1
    }

    func testDoctorFlagsARejectedToken() async throws {
        let world = FakeWorld()
        let output = Output()
        let path = try writeConfig(testConfig(token: "wrong-token"))
        _ = await CLI.main(["--config", path, "doctor"], context: cliContext(world: world, state: state, output: output))
        XCTAssertTrue(output.out.contains("[FAIL] server: reachable, token REJECTED (HTTP 401)"), output.out)
        XCTAssertTrue(output.out.contains("[ ok ] ingest token: config file (server.token)"), output.out)
        XCTAssertFalse(output.out.contains("wrong-token"))
    }

    func testStatusReadsTheStatusFile() async throws {
        let output = Output()
        let path = try writeConfig(testConfig())
        _ = await CLI.main(["--config", path, "status"], context: cliContext(world: FakeWorld(), state: state, output: output))
        XCTAssertTrue(output.out.contains("no status yet"), output.out)

        var st = DaemonStatus(pid: 42, version: HelperVersion.string, started_at: t0, updated_at: t0,
                              calendar_authorization: "fullAccess", reminders_authorization: "denied", streams: [:])
        var cal = DaemonStatus.Stream()
        cal.last_success = t0
        cal.last_result = "pushed: calendars=2 events=10"
        st.streams["calendar"] = cal
        st.save(path: state.status)
        let again = Output()
        _ = await CLI.main(["--config", path, "status"], context: cliContext(world: FakeWorld(), state: state, output: again))
        XCTAssertTrue(again.out.contains("calendar: last success"), again.out)
        XCTAssertTrue(again.out.contains("reminders access: denied"), again.out)
    }

    func testAnInvalidConfigFailsCleanly() async throws {
        let path = dir.appendingPathComponent("helper.json").path
        try Data("{".utf8).write(to: URL(fileURLWithPath: path))
        let output = Output()
        let code = await CLI.main(["--config", path, "status"], context: cliContext(world: FakeWorld(), state: state, output: output))
        XCTAssertEqual(code, 2)
        XCTAssertTrue(output.err.contains("invalid JSON"), output.err)
    }

    func testInstallPrintChangesNothing() async throws {
        let output = Output()
        var config = testConfig()
        config.launch_agent_label = "org.example.test-agent"
        let path = try writeConfig(config)
        let code = await CLI.main(["--config", path, "install", "--print", "--binary", "/usr/local/bin/organizer-helper"],
                                  context: cliContext(world: FakeWorld(), state: state, output: output))
        XCTAssertEqual(code, 0)
        XCTAssertTrue(output.out.contains("<string>org.example.test-agent</string>"), output.out)
        XCTAssertTrue(output.out.contains("<string>--config</string>"), output.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.launchAgentPlist(label: "org.example.test-agent")))
    }
}
