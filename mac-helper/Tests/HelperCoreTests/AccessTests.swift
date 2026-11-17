import XCTest
@testable import HelperCore

/// The optional Cloudflare Access service token: config keys, the Keychain fallback for the
/// secret, the two headers on every request, and `doctor` reporting it without its value.
final class AccessTests: XCTestCase {
    var dir: URL!
    var state: HelperStateFiles { HelperStateFiles(directory: dir.appendingPathComponent("state").path) }

    override func setUp() { dir = tempDir() }

    func writeConfig(_ c: HelperConfig) throws -> String {
        let path = dir.appendingPathComponent("helper.json").path
        try JSONEncoder().encode(c).write(to: URL(fileURLWithPath: path))
        return path
    }

    func accessConfig(id: String? = "abc.access", secret: String? = nil) -> HelperConfig {
        var c = testConfig()
        c.server.cf_access_client_id = id
        c.server.cf_access_client_secret = secret
        return c
    }

    func testTheKeysDecodeAndDefaultToNothing() throws {
        let json = #"{"server": {"url": "https://organizer.example.com", "cf_access_client_id": "abc.access", "cf_access_client_secret": null}}"#
        let c = try JSONCoding.decoder().decode(HelperConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.server.cf_access_client_id, "abc.access")
        XCTAssertNil(c.server.cf_access_client_secret)
        XCTAssertNil(HelperConfig().server.cf_access_client_id)
        XCTAssertEqual(AccessResolver.resolve(config: testConfig(), keychain: FakeKeychain()).source, .notConfigured)
    }

    func testTheSecretComesFromTheConfigElseTheKeychain() {
        let keychain = FakeKeychain([FakeKeychain.key(Paths.defaultBundleId, "cf-access-client-secret"): "from-keychain\n"])
        let fromConfig = AccessResolver.resolve(config: accessConfig(secret: "from-config"), keychain: keychain)
        XCTAssertEqual(fromConfig.credentials, AccessCredentials(clientID: "abc.access", clientSecret: "from-config"))
        XCTAssertEqual(keychain.reads, 0)
        let fromKeychain = AccessResolver.resolve(config: accessConfig(), keychain: keychain)
        XCTAssertEqual(fromKeychain.credentials?.clientSecret, "from-keychain")
        XCTAssertEqual(fromKeychain.source, .keychain(service: Paths.defaultBundleId, account: "cf-access-client-secret"))
        let missing = AccessResolver.resolve(config: accessConfig(), keychain: FakeKeychain())
        XCTAssertNil(missing.credentials)
        XCTAssertTrue(missing.source.description.contains("set-cf-access-secret"))
    }

    func testEveryRequestCarriesBothHeadersWithTheBearer() async throws {
        let organizer = FakeOrganizer()
        let client = ServerClient(baseURL: URL(string: "https://organizer.example.com"), tokens: TokenProvider(fixed: organizer.acceptedToken),
                                  transport: organizer, retryDelays: [],
                                  access: AccessProvider(fixed: AccessCredentials(clientID: "abc.access", clientSecret: "shh")))
        _ = try await client.fetchReminderOps()
        let request = try XCTUnwrap(organizer.requests.first)
        XCTAssertEqual(request.headers["CF-Access-Client-Id"], "abc.access")
        XCTAssertEqual(request.headers["CF-Access-Client-Secret"], "shh")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(organizer.acceptedToken)")
    }

    func testNoHeadersWithoutAnAccessToken() async throws {
        let organizer = FakeOrganizer()
        let runtime = HelperRuntime(config: { var c = testConfig(token: organizer.acceptedToken); c.server.cf_access_client_id = nil; return c }(),
                                    environment: FakeWorld(organizer: organizer).environment(), stateFiles: state, retryDelays: [])
        _ = try await runtime.server.fetchReminderOps()
        XCTAssertNil(organizer.requests.first?.headers["CF-Access-Client-Id"])
        XCTAssertNil(organizer.requests.first?.headers["CF-Access-Client-Secret"])
    }

    func testTheRuntimeSendsTheKeychainSecret() async throws {
        let world = FakeWorld()
        try world.keychain.write("kc-secret", service: Paths.defaultBundleId, account: "cf-access-client-secret")
        var c = accessConfig()
        c.server.token = world.organizer.acceptedToken
        let runtime = HelperRuntime(config: c, environment: world.environment(), stateFiles: state, retryDelays: [])
        _ = try await runtime.server.fetchReminderOps()
        XCTAssertEqual(world.organizer.requests.first?.headers["CF-Access-Client-Id"], "abc.access")
        XCTAssertEqual(world.organizer.requests.first?.headers["CF-Access-Client-Secret"], "kc-secret")
    }

    func testDoctorReportsAccessWithoutItsValues() async throws {
        let world = FakeWorld()
        let output = Output()
        var c = accessConfig(secret: "very-secret-value")
        c.server.token = world.organizer.acceptedToken
        let path = try writeConfig(c)
        _ = await CLI.main(["--config", path, "doctor"], context: cliContext(world: world, state: state, output: output))
        XCTAssertTrue(output.out.contains("[ ok ] cloudflare access: client id and secret in the config file"), output.out)
        XCTAssertFalse(output.out.contains("very-secret-value"), "doctor printed the secret")
        XCTAssertEqual(world.organizer.requests.first?.headers["CF-Access-Client-Secret"], "very-secret-value")

        let plain = Output()
        _ = await CLI.main(["--config", try writeConfig(testConfig(token: world.organizer.acceptedToken)), "doctor"],
                           context: cliContext(world: world, state: state, output: plain))
        XCTAssertTrue(plain.out.contains("cloudflare access: not set"), plain.out)
    }

    func testSetAccessSecretStoresItAndNeverPrintsIt() async throws {
        let world = FakeWorld()
        let output = Output()
        let path = try writeConfig(accessConfig())
        let code = await CLI.main(["--config", path, "set-cf-access-secret"],
                                  context: cliContext(world: world, state: state, output: output, secret: " s3cret-access\n"))
        XCTAssertEqual(code, 0, output.err)
        XCTAssertEqual(world.keychain.value(service: Paths.defaultBundleId, account: "cf-access-client-secret"), "s3cret-access")
        XCTAssertFalse(output.out.contains("s3cret"), output.out)
        XCTAssertFalse(output.err.contains("s3cret"), output.err)
        XCTAssertEqual(try CLI.parse(["set-cf-access-secret"]).command, .setAccessSecret)
    }
}
