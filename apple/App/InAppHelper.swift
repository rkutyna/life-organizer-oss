import EventKit
import Foundation
import HelperCore
import Observation
import OrganizerAPI
import OrganizerCore
import OrganizerUI

/// The Mac helper (`mac-helper/`, HelperCore) run inside the app, as an alternative to its own
/// LaunchAgent: it sends Apple Calendar and Apple Reminders to the organizer and applies the
/// reminder changes queued there.
///
/// - **Off by default.** Settings → Helper turns it on; the switch is remembered.
/// - **Its own token**, with the `ingest` scope only, kept in the Keychain apart from the app's
///   API token. The app's server address and Cloudflare Access token are reused.
/// - **One helper at a time.** It takes the same lock as the command-line helper, so it refuses to
///   start while a LaunchAgent helper runs (and the other way round).
/// - **No prompt on its own.** Calendars and Reminders access is asked for only when you press
///   Request Access in Settings → Helper.
@MainActor
@Observable
final class InAppHelper {
    static let shared = InAppHelper()

    enum Phase: Equatable {
        case off
        case running
        /// Turned on but could not start, and why.
        case refused(String)
    }

    static let enabledKey = "helper.runInApp"

    private(set) var phase: Phase = .off
    private(set) var status: DaemonStatus?
    private(set) var calendars: HelperAuthorization = .unknown
    private(set) var reminders: HelperAuthorization = .unknown
    private(set) var hasToken = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    @ObservationIgnored private var daemon: Daemon?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private let tokenStore: any TokenStore = KeychainTokenStore.helper

    /// At launch: starts only when the switch is on. Never prompts.
    func launch(app: AppEnvironment) {
        guard isEnabled else { return }
        start(app: app)
    }

    /// Turns the switch on or off, starting or stopping the helper.
    func setEnabled(_ on: Bool, app: AppEnvironment) async {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start(app: app) } else { await stop() }
    }

    /// Reads (never requests) the permission status and whether a token is saved: for Settings.
    func refreshInfo() {
        calendars = HelperAuthorization(EKEventStore.authorizationStatus(for: .event))
        reminders = HelperAuthorization(EKEventStore.authorizationStatus(for: .reminder))
        hasToken = (try? tokenStore.read())?.isEmpty == false
    }

    /// Settings' Request Access: shows macOS's prompts (the first time only).
    func requestAccess() async {
        let store = EKEventStore()
        if calendars.canRequest { _ = try? await store.requestFullAccessToEvents() }
        if reminders.canRequest { _ = try? await store.requestFullAccessToReminders() }
        refreshInfo()
    }

    func saveToken(_ token: String) throws {
        try tokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshInfo()
    }

    func forgetToken() throws {
        try tokenStore.delete()
        refreshInfo()
    }

    /// Stops and starts again with the current address, token and Access settings.
    func restart(app: AppEnvironment) async {
        await stop()
        if isEnabled { start(app: app) }
    }

    private func start(app: AppEnvironment) {
        guard daemon == nil else { return }
        guard let token = (try? tokenStore.read())?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            phase = .refused("No helper token. Make one in the web app (Settings → API tokens, scope ingest only) and save it here.")
            return
        }
        var config = HelperConfig()
        config.server = HelperConfig.Server(url: app.server.url.absoluteString, token: token)
        if let access = app.currentAccess().token {
            config.server.cf_access_client_id = access.clientID
            config.server.cf_access_client_secret = access.clientSecret
        }
        if let problem = config.serverURLProblem {
            phase = .refused(problem)
            return
        }
        let daemon = Daemon(config: config, environment: .live(config: config),
                            options: Daemon.Options(stateFiles: .standard, requestAccessOnStart: false))
        do {
            try daemon.start()
        } catch {
            if case HelperStartError.anotherHelperRunning = error {
                phase = .refused("Another helper is running (the LaunchAgent, or another copy of this app). Stop it first: organizer-helper uninstall.")
            } else {
                phase = .refused("\(error)")
            }
            return
        }
        self.daemon = daemon
        phase = .running
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.status = daemon.currentStatus
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stop() async {
        poll?.cancel()
        poll = nil
        if let daemon {
            self.daemon = nil
            await daemon.stop()
        }
        status = nil
        phase = .off
    }

    /// Lets a running helper finish in-flight pushes and release its lock before the app quits.
    var needsStop: Bool { daemon != nil }

    func stopForTermination() async { await stop() }
}
