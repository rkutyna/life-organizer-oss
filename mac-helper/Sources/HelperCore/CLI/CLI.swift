import Foundation

public enum Command: Equatable {
    case run
    case doctor
    case status
    case install(binary: String?, printOnly: Bool)
    case uninstall
    case setToken
    case setAccessSecret
    case version
    case help
}

public struct CLIOptions: Equatable {
    public var command: Command
    public var configPath: String
    public var verbose: Bool
}

public enum CLIError: Error, CustomStringConvertible, Equatable {
    case usage(String)
    public var description: String { if case .usage(let s) = self { return s }; return "" }
}

/// What the CLI touches outside itself, so commands are tested with fakes.
public struct CLIContext: @unchecked Sendable {
    public var makeEnvironment: (HelperConfig) -> HelperEnvironment
    /// The token for `set-token`: stdin (without echo when it is a terminal).
    public var readSecret: () -> String?
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var stateFiles: HelperStateFiles
    /// `launchctl print` summary for a label (read-only), nil when not loaded.
    public var launchAgentState: (String) -> String?
    /// `codesign -dv` of this executable (read-only), nil when unavailable.
    public var signature: () -> SignatureSummary?

    public init(makeEnvironment: @escaping (HelperConfig) -> HelperEnvironment,
                readSecret: @escaping () -> String?,
                out: @escaping (String) -> Void,
                err: @escaping (String) -> Void,
                stateFiles: HelperStateFiles,
                launchAgentState: @escaping (String) -> String?,
                signature: @escaping () -> SignatureSummary?) {
        self.makeEnvironment = makeEnvironment
        self.readSecret = readSecret
        self.out = out
        self.err = err
        self.stateFiles = stateFiles
        self.launchAgentState = launchAgentState
        self.signature = signature
    }

    public static var live: CLIContext {
        CLIContext(
            makeEnvironment: { HelperEnvironment.live(config: $0) },
            readSecret: { CLI.readSecretFromStdin() },
            out: { print($0) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            stateFiles: .standard,
            launchAgentState: { LaunchAgent.loadedState(label: $0) },
            signature: { SignatureSummary.current() }
        )
    }
}

public enum CLI {
    public static let usage = """
    organizer-helper: sends Apple Calendar and Apple Reminders to your organizer, and applies
    the reminder changes you make there.

    USAGE
      organizer-helper run              the daemon (what the LaunchAgent runs); asks for
                                        Calendars and Reminders access on its first run
      organizer-helper set-token        store the ingest token in the Keychain (reads stdin)
      organizer-helper set-cf-access-secret
                                        store a Cloudflare Access service token's client
                                        secret in the Keychain (reads stdin)
      organizer-helper doctor           read-only checks; never prompts for permissions
      organizer-helper status           what the daemon last did (from its status file)
      organizer-helper install [--binary PATH] [--print]
                                        write and load the LaunchAgent (--print shows the
                                        plist and changes nothing)
      organizer-helper uninstall        unload and remove the LaunchAgent
      organizer-helper version
      organizer-helper help

    OPTIONS
      --config PATH     default \(Paths.configFile)
      -v, --verbose     debug logging
    """

    public static func parse(_ args: [String]) throws -> CLIOptions {
        var rest = args
        var configPath = Paths.configFile

        func take(_ flag: String) throws -> String? {
            guard let i = rest.firstIndex(of: flag) else { return nil }
            guard i + 1 < rest.count, !rest[i + 1].hasPrefix("-") else { throw CLIError.usage("\(flag) needs a value") }
            let v = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
            return v
        }
        func flag(_ names: String...) -> Bool {
            var found = false
            for n in names { while let i = rest.firstIndex(of: n) { rest.remove(at: i); found = true } }
            return found
        }

        if let c = try take("--config") { configPath = Paths.expand(c) }
        let verbose = flag("-v", "--verbose")
        if flag("-h", "--help") { return CLIOptions(command: .help, configPath: configPath, verbose: verbose) }
        guard let sub = rest.first else { return CLIOptions(command: .help, configPath: configPath, verbose: verbose) }
        rest.removeFirst()

        let command: Command
        switch sub {
        case "run": command = .run
        case "doctor": command = .doctor
        case "status": command = .status
        case "install":
            let bin = try take("--binary")
            command = .install(binary: bin.map(Paths.expand), printOnly: flag("--print"))
        case "uninstall": command = .uninstall
        case "set-token": command = .setToken
        case "set-cf-access-secret": command = .setAccessSecret
        case "version", "--version": command = .version
        case "help": command = .help
        default: throw CLIError.usage("unknown command '\(sub)'")
        }
        if let extra = rest.first { throw CLIError.usage("unexpected argument '\(extra)'") }
        return CLIOptions(command: command, configPath: configPath, verbose: verbose)
    }

    /// Exit code of `run` when another helper holds the lock.
    public static let exitLockHeld: Int32 = 3

    /// Entry point used by the executable. Returns the process exit code.
    public static func main(_ args: [String], context: CLIContext = .live) async -> Int32 {
        let opts: CLIOptions
        do { opts = try parse(args) } catch {
            context.err("error: \(error)\n\n\(usage)")
            return 2
        }

        switch opts.command {
        case .help:
            context.out(usage)
            return 0
        case .version:
            context.out("organizer-helper \(HelperVersion.string) (\(Bundle.main.bundleIdentifier ?? "no embedded Info.plist"))")
            return 0
        default:
            break
        }

        let config: HelperConfig
        let exists: Bool
        do {
            (config, exists) = try HelperConfig.load(path: opts.configPath)
        } catch {
            context.err("error: \(error)")
            if opts.command == .run {
                log.configure(path: Paths.logFile, verbose: opts.verbose)
                log.error("\(error)")
            }
            return 2
        }

        switch opts.command {
        case .run:
            log.configure(path: config.logPath, verbose: opts.verbose)
            if !exists { log.warn("no config at \(opts.configPath); using defaults") }
            if exists, let problem = HelperConfig.permissionProblem(path: opts.configPath, holdsToken: config.holdsToken) {
                if problem.refuse {
                    log.error("not starting: \(problem.message)")
                    context.err("error: \(problem.message)")
                    return 2
                }
                log.error("WARNING: \(problem.message)")
                context.err("WARNING: \(problem.message)")
            }
            return await runDaemon(config: config, context: context)
        case .doctor:
            log.configure(path: nil, verbose: opts.verbose)
            return await Doctor.run(config: config, configPath: opts.configPath, configExists: exists, context: context)
        case .status:
            return StatusCommand.run(config: config, context: context)
        case .setToken:
            return setToken(config: config, context: context)
        case .setAccessSecret:
            return setAccessSecret(config: config, context: context)
        case .install(let binary, let printOnly):
            let bin = binary ?? currentExecutable()
            let label = config.launchAgentLabel
            if printOnly {
                guard let data = try? LaunchAgent.plist(binary: URL(fileURLWithPath: bin).resolvingSymlinksInPath().path,
                                                        label: label, configPath: opts.configPath) else { return 1 }
                context.out("# would write \(Paths.launchAgentPlist(label: label))")
                context.out(String(decoding: data, as: UTF8.self))
                return 0
            }
            if !exists { context.err("warning: no config at \(opts.configPath) yet; the helper will not push until it has a server url") }
            do {
                for n in try LaunchAgent.install(binary: bin, label: label, configPath: opts.configPath) { context.out(n) }
                return 0
            } catch {
                context.err("install failed: \(error)")
                return 1
            }
        case .uninstall:
            do {
                for n in try LaunchAgent.uninstall(label: config.launchAgentLabel) { context.out(n) }
                return 0
            } catch {
                context.err("uninstall failed: \(error)")
                return 1
            }
        case .help, .version:
            return 0
        }
    }

    /// `run`: returns only when the helper cannot start; launchd's SIGTERM ends the process.
    static func runDaemon(config: HelperConfig, context: CLIContext) async -> Int32 {
        let daemon = Daemon(config: config, environment: context.makeEnvironment(config),
                            options: Daemon.Options(stateFiles: context.stateFiles))
        do {
            try daemon.start()
        } catch {
            log.error("not starting: \(error)")
            if case HelperStartError.anotherHelperRunning = error { return exitLockHeld }
            return 1
        }
        while true {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    /// `set-token`: reads the token from stdin and stores it in the Keychain under the config's
    /// service and account. The token is never printed.
    static func setToken(config: HelperConfig, context: CLIContext) -> Int32 {
        guard let raw = context.readSecret() else {
            context.err("error: no token on stdin")
            return 2
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            context.err("error: the token is empty")
            return 2
        }
        guard !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            context.err("error: the token contains whitespace; paste only the token")
            return 2
        }
        let env = context.makeEnvironment(config)
        do {
            try env.keychain.write(token, service: config.keychainService, account: config.keychainAccount)
        } catch {
            context.err("error: \(error)")
            return 1
        }
        context.out("stored the token in the Keychain (service \(config.keychainService), account \(config.keychainAccount))")
        if let t = config.server.token, !t.isEmpty {
            context.out("note: the config's server.token is set and takes precedence; set it to null to use the Keychain")
        }
        return 0
    }

    /// `set-cf-access-secret`: reads a Cloudflare Access client secret from stdin and stores it in
    /// the Keychain (the config's service, account `cf-access-client-secret`). Never printed.
    static func setAccessSecret(config: HelperConfig, context: CLIContext) -> Int32 {
        guard let raw = context.readSecret() else {
            context.err("error: no secret on stdin")
            return 2
        }
        let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, !secret.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            context.err("error: the secret is empty or contains whitespace; paste only the secret")
            return 2
        }
        let env = context.makeEnvironment(config)
        do {
            try env.keychain.write(secret, service: config.keychainService, account: HelperConfig.accessSecretAccount)
        } catch {
            context.err("error: \(error)")
            return 1
        }
        context.out("stored the Cloudflare Access secret in the Keychain (service \(config.keychainService), account \(HelperConfig.accessSecretAccount))")
        if (config.server.cf_access_client_id ?? "").isEmpty {
            context.out("note: set server.cf_access_client_id in the config too; without it no Access headers are sent")
        }
        if let s = config.server.cf_access_client_secret, !s.isEmpty {
            context.out("note: the config's server.cf_access_client_secret is set and takes precedence; set it to null to use the Keychain")
        }
        return 0
    }

    /// The token from stdin: without echo when stdin is a terminal, else everything piped in.
    static func readSecretFromStdin() -> String? {
        if isatty(STDIN_FILENO) == 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            guard let p = readpassphrase("Paste it (input hidden), then press Return: ", &buffer, buffer.count, 0) else {
                return nil
            }
            let s = String(cString: p)
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            return s
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    static func currentExecutable() -> String {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "organizer-helper"
    }
}
