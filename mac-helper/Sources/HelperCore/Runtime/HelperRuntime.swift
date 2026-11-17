import Foundation

/// Wires the collectors to the server: what each daemon job calls.
public final class HelperRuntime: @unchecked Sendable {
    public let config: HelperConfig
    public let environment: HelperEnvironment
    public let stateFiles: HelperStateFiles
    public let host: String
    public let tokens: TokenProvider
    public let server: ServerClient
    private let lock = NSLock()
    private var _calendarSource: CalendarSource?
    private var _reminders: RemindersSync?

    public init(config: HelperConfig, environment: HelperEnvironment, stateFiles: HelperStateFiles = .standard,
                retryDelays: [TimeInterval] = ServerClient.standardRetryDelays) {
        self.config = config
        self.environment = environment
        self.stateFiles = stateFiles
        host = config.hostName
        tokens = TokenProvider(config: config, keychain: environment.keychain)
        server = ServerClient(baseURL: config.serverURL, tokens: tokens, transport: environment.transport, retryDelays: retryDelays,
                              access: AccessProvider(config: config, keychain: environment.keychain))
    }

    /// Created on first use, so a disabled stream never touches EventKit.
    var calendarSource: CalendarSource {
        lock.withLock {
            if let s = _calendarSource { return s }
            let s = environment.makeCalendarSource()
            _calendarSource = s
            return s
        }
    }

    public var reminders: RemindersSync {
        lock.withLock {
            if let r = _reminders { return r }
            let r = RemindersSync(store: environment.makeReminderStore(config.reminders.alarm_at_due_time),
                                  completedDays: config.reminders.completed_days, statePath: stateFiles.reminders)
            _reminders = r
            return r
        }
    }

    public enum StreamOutcome: Sendable {
        case delivered(EncodedPayload)
        case unchanged(EncodedPayload)
        case failed(String)
        /// The task was cancelled (the helper is stopping); nothing was pushed.
        case cancelled
    }

    /// Collects one stream into its payload. Throws when access is missing.
    public func collect(_ stream: IngestStream, now: Date = Date()) async throws -> EncodedPayload {
        let zone = environment.calendar.timeZone
        switch stream {
        case .calendar:
            let status = environment.permissions.calendars()
            guard status == .fullAccess else { throw CalendarError.notAuthorized(status.rawValue) }
            let body = CalendarCollector(source: calendarSource, config: config.calendar, calendar: environment.calendar).collect(now: now)
            return try PayloadEncoder.encode(stream: .calendar, body: body, host: host, collectedAt: now,
                                             summary: "calendars=\(body.calendars.count) events=\(body.events.count)", timeZone: zone)
        case .reminders:
            let status = environment.permissions.reminders()
            guard status == .fullAccess else { throw ReminderStoreError.notAuthorized(status.rawValue) }
            let body = try await reminders.collect(now: now)
            return try PayloadEncoder.encode(stream: .reminders, body: body, host: host, collectedAt: now,
                                             summary: "lists=\(body.lists.count) reminders=\(body.reminders.count)", timeZone: zone)
        }
    }

    /// Collect + deliver one stream, honoring change detection when a gate is given.
    public func runStream(_ stream: IngestStream, gate: StreamGate?, now: Date = Date()) async -> StreamOutcome {
        let label = stream.rawValue
        let started = Date()
        do {
            let payload = try await collect(stream, now: now)
            // A stopping helper never pushes a snapshot it may have cut short (replace semantics).
            if Task.isCancelled { return cancelled(label) }
            if let gate, !gate.shouldPush(stream, hash: payload.bodyHash, now: now) {
                log.debug("\(label): unchanged (\(payload.summary))")
                return .unchanged(payload)
            }
            try await server.deliver(payload)
            gate?.markPushed(stream, hash: payload.bodyHash, at: now)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log.info("\(label): delivered \(payload.bytes) bytes in \(ms) ms (\(payload.summary))")
            return .delivered(payload)
        } catch {
            if error is CancellationError || Task.isCancelled { return cancelled(label) }
            log.error("\(label): \(error)")
            return .failed("\(error)")
        }
    }

    private func cancelled(_ label: String) -> StreamOutcome {
        log.info("\(label): cancelled (helper stopping)")
        return .cancelled
    }

    /// The name macOS shows in permission prompts: the embedded Info.plist's.
    public static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Life Organizer Helper"
    }
}
