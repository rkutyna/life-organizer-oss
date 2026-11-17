import XCTest
@testable import HelperCore

// Regression tests: created ops keyed by server instance, plain http refused, config
// permissions checked at `run`, and reverse-DNS names for the bundle id and LaunchAgent label.

final class InstanceKeyedCreatesTests: XCTestCase {
    func createOp(id: Int, instance: String?) -> ReminderOp {
        ReminderOp(id: id, reminder_id: 1, kind: "create",
                   fields: OpFields(present: ["title", "list_id"], title: "Pay rent", list_id: "L-errands"),
                   queued_at: t0, instance: instance)
    }

    func testAnotherInstancesOpWithTheSameIdIsCreated() {
        let store = makeStore()
        var state = RemindersState()
        state.recordCreated(op: 1, instance: "old-db", .init(local_id: "r1", external_id: "ext-r1", at: t0))
        let a = ReminderOpsApplier(store: store, state: state)
        let out = a.apply(createOp(id: 1, instance: "new-db"), now: t0 + 3600)
        XCTAssertEqual(store.writes, ["create L-errands Pay rent"])
        XCTAssertEqual(out, .ack(.success(external: "ext-new-1", local: "new-1")))
        XCTAssertEqual(a.state.created(op: 1, instance: "new-db")?.local_id, "new-1")
        XCTAssertEqual(a.state.created(op: 1, instance: "old-db")?.local_id, "r1")
    }

    func testABareIdEntryIsNotTakenForAnInstancesOp() {
        let store = makeStore()
        let state = RemindersState(created_ops: [1: .init(local_id: "r1", external_id: "ext-r1", at: t0)])
        _ = ReminderOpsApplier(store: store, state: state).apply(createOp(id: 1, instance: "new-db"), now: t0)
        XCTAssertEqual(store.writes, ["create L-errands Pay rent"])
    }

    func testTheSameInstancesLostAckIsAckedAgainWithoutAWrite() {
        let store = makeStore()
        var state = RemindersState()
        state.recordCreated(op: 1, instance: "db", .init(local_id: "r1", external_id: "ext-r1", at: t0))
        let out = ReminderOpsApplier(store: store, state: state).apply(createOp(id: 1, instance: "db"), now: t0)
        XCTAssertEqual(store.writes, [])
        XCTAssertEqual(out, .ack(.success(external: "ext-r1", local: "r1")))
    }

    func testTheStateFileKeysByInstance() throws {
        var state = RemindersState()
        state.recordCreated(op: 7, instance: "abc", .init(local_id: "r", external_id: nil, at: t0))
        state.recordCreated(op: 8, .init(local_id: "s", external_id: nil, at: t0))
        XCTAssertEqual(Set(state.created_ops.keys), ["abc:7", "8"])
        let back = try JSONCoding.decoder().decode(RemindersState.self, from: JSONCoding.encoder().encode(state))
        XCTAssertEqual(back, state)
    }

    func testTheOpsResponseCarriesTheInstanceOntoEachOp() throws {
        let json = #"{"instance_id":"db-1","server_time":"2026-10-19T12:00:00+00:00","ops":[{"id":3,"reminder_id":9,"kind":"complete","queued_at":"2026-10-19T11:00:00+00:00"}]}"#
        let ops = try JSONCoding.decoder().decode(ReminderOpsResponse.self, from: Data(json.utf8)).instancedOps
        XCTAssertEqual(ops.map(\.instance), ["db-1"])
    }

    func testAcksAreAddressedToTheOpsInstance() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore()
        let server = FakeRemindersServer()
        server.ops = [ReminderOp(id: 1, reminder_id: 1, kind: "complete", external_id: "ext-r1", local_id: "r1",
                                 queued_at: t0, instance: "db-1")]
        let sync = RemindersSync(store: store, completedDays: 30, statePath: dir.appendingPathComponent("reminders.json").path)
        _ = await sync.applyOps(server: server, now: t0)
        XCTAssertEqual(server.acks.map(\.1.instance_id), ["db-1"])
    }

    func testA409AckIsDroppedLikeAWithdrawnOp() async throws {
        let transport = StatusTransport(status: 409)
        let client = ServerClient(baseURL: URL(string: "https://organizer.example.com"), tokens: TokenProvider(fixed: "t"),
                                  transport: transport, retryDelays: [])
        let delivered = try await client.ackReminderOp(1, OpAck.success().addressed(to: ReminderOp(id: 1, reminder_id: 1, kind: "complete", queued_at: t0, instance: "db")))
        XCTAssertFalse(delivered)
        let body = try XCTUnwrap(transport.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["instance_id"] as? String, "db")
    }
}

/// Answers every request with one status.
final class StatusTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    private(set) var lastBody: Data?
    init(status: Int) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastBody = request.httpBody
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data("{}".utf8), response)
    }
}

final class InsecureHTTPTests: XCTestCase {
    func config(_ url: String, allow: Bool = false) -> HelperConfig {
        var c = HelperConfig()
        c.server = HelperConfig.Server(url: url, token: "t", allow_insecure_http: allow)
        return c
    }

    func testPlainHTTPToAnotherHostIsRefused() throws {
        let data = Data(#"{"server":{"url":"http://organizer.example.com","token":"t"}}"#.utf8)
        let c = try JSONDecoder().decode(HelperConfig.self, from: data)
        XCTAssertNil(c.serverURL)
        XCTAssertTrue(c.serverURLProblem?.contains("allow_insecure_http") == true, c.serverURLProblem ?? "")
    }

    func testLoopbackHTTPIsFine() {
        for url in ["http://localhost:8600", "http://127.0.0.1:8600", "http://[::1]:8600", "http://organizer.localhost"] {
            let c = config(url)
            XCTAssertNotNil(c.serverURL, url)
            XCTAssertNil(c.serverURLProblem, url)
            XCTAssertFalse(c.usesInsecureHTTP, url)
        }
        XCTAssertNil(config("http://127.0.0.1.example.com").serverURL)
    }

    func testAnExplicitOptInAllowsItAndIsFlagged() throws {
        let data = Data(#"{"server":{"url":"http://organizer.example.com","allow_insecure_http":true}}"#.utf8)
        let c = try JSONDecoder().decode(HelperConfig.self, from: data)
        XCTAssertNotNil(c.serverURL)
        XCTAssertTrue(c.usesInsecureHTTP)
        XCTAssertFalse(config("https://organizer.example.com", allow: true).usesInsecureHTTP)
    }

    func testDoctorFlagsBothCases() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = HelperStateFiles(directory: dir.appendingPathComponent("state").path)
        for (allow, expected) in [(false, "[FAIL] server url: server.url uses plain http"), (true, "[FAIL] server url: WARNING: plain http")] {
            let path = dir.appendingPathComponent("helper-\(allow).json").path
            var c = config("http://organizer.example.com", allow: allow)
            c.server.token = nil
            try JSONEncoder().encode(c).write(to: URL(fileURLWithPath: path))
            let output = Output()
            _ = await CLI.main(["--config", path, "doctor"], context: cliContext(world: FakeWorld(), state: state, output: output))
            XCTAssertTrue(output.out.contains(expected), output.out)
        }
    }
}

final class ConfigPermissionTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ json: String, mode: Int) throws -> String {
        let path = dir.appendingPathComponent("helper-\(UUID().uuidString).json").path
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    func testPermissionProblems() throws {
        let p644 = try write("{}", mode: 0o644), p664 = try write("{}", mode: 0o664), p600 = try write("{}", mode: 0o600)
        XCTAssertEqual(HelperConfig.permissionProblem(path: p644, holdsToken: true)?.refuse, false)
        XCTAssertNil(HelperConfig.permissionProblem(path: p644, holdsToken: false))
        XCTAssertEqual(HelperConfig.permissionProblem(path: p664, holdsToken: false)?.refuse, true)
        XCTAssertNil(HelperConfig.permissionProblem(path: p600, holdsToken: true))
    }

    /// `run` checks before it starts anything: no daemon, no lock, no network.
    func testRunRefusesAConfigOthersCanWrite() async throws {
        let log = dir.appendingPathComponent("helper.log").path
        let path = try write(#"{"server":{"url":"https://x.example.com"},"log_path":"\#(log)"}"#, mode: 0o666)
        let output = Output()
        let state = HelperStateFiles(directory: dir.appendingPathComponent("state").path)
        let code = await CLI.main(["--config", path, "run"], context: cliContext(world: FakeWorld(), state: state, output: output))
        XCTAssertEqual(code, 2)
        XCTAssertTrue(output.err.contains("writable by other users"), output.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.lock))
    }

    func testAWorldReadableTokenIsWarnedAbout() throws {
        let path = try write(#"{"server":{"url":"https://x.example.com","token":"secret"}}"#, mode: 0o644)
        let (c, _) = try HelperConfig.load(path: path)
        let problem = try XCTUnwrap(HelperConfig.permissionProblem(path: path, holdsToken: c.holdsToken))
        XCTAssertFalse(problem.refuse)
        XCTAssertTrue(problem.message.contains("readable by other users"))
        XCTAssertFalse(problem.message.contains("secret"))
    }
}

final class ReverseDNSNameTests: XCTestCase {
    func testLabelsAndBundleIdsMustBeReverseDNS() {
        for bad in [#"{"launch_agent_label":"../../.config/evil"}"#, #"{"launch_agent_label":"a/b.c"}"#,
                    #"{"bundle_id":"helper"}"#, #"{"bundle_id":"com..example"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(HelperConfig.self, from: Data(bad.utf8)), bad)
        }
        let ok = try? JSONDecoder().decode(HelperConfig.self, from: Data(#"{"bundle_id":"org.example.helper","launch_agent_label":"org.example-2.agent"}"#.utf8))
        XCTAssertEqual(ok?.launchAgentLabel, "org.example-2.agent")
    }

    func testTheScriptsValidateNames() throws {
        let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts")
        for name in ["install.sh", "release.sh"] {
            let text = try String(contentsOf: scripts.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains(#"reverse_dns='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'"#), name)
        }
    }
}
