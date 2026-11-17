import Foundation

/// What `organizer-helper run` (the LaunchAgent) runs. A scheduler tick starts each due job
/// (never two copies of the same job at once):
///
/// - `calendar` every `calendar.interval_seconds`: collect, push when changed or when the
///   heartbeat (`heartbeat_seconds`) has passed.
/// - `reminders` every `reminders.ops_poll_seconds`: apply the organizer's queued ops and ack
///   them, then push the snapshot when Reminders changed, ops were applied, or
///   `reminders.snapshot_seconds` passed (still subject to change detection and the heartbeat).
///
/// Both also re-run `calendar.debounce_seconds` after an EventKit change notification.
///
/// Single use: `start()` takes the helper lock (`HelperLock`) and starts the scheduler; `stop()`
/// lets in-flight jobs finish (up to `stopGraceSeconds`), cancels the rest, and releases the lock.
public final class Daemon: @unchecked Sendable {
    public struct Options: Sendable {
        public var stateFiles: HelperStateFiles
        /// Ask for Calendars / Reminders access when the scheduler starts and macOS has not asked
        /// yet (the LaunchAgent's first run). The prompt names the binary's embedded app name.
        public var requestAccessOnStart: Bool
        /// How long `stop()` lets in-flight jobs finish before cancelling them.
        public var stopGraceSeconds: TimeInterval
        /// The server client's retry backoff.
        public var retryDelays: [TimeInterval]
        /// The scheduler's tick.
        public var tickSeconds: TimeInterval

        public init(stateFiles: HelperStateFiles = .standard,
                    requestAccessOnStart: Bool = true,
                    stopGraceSeconds: TimeInterval = 10,
                    retryDelays: [TimeInterval] = ServerClient.standardRetryDelays,
                    tickSeconds: TimeInterval = 1) {
            self.stateFiles = stateFiles
            self.requestAccessOnStart = requestAccessOnStart
            self.stopGraceSeconds = stopGraceSeconds
            self.retryDelays = retryDelays
            self.tickSeconds = tickSeconds
        }
    }

    private enum Phase { case new, running, stopping, stopped }

    private final class Job: @unchecked Sendable {
        let name: String
        let interval: TimeInterval
        var nextRun = Date.distantPast
        var running = false
        var dirtySince: Date?
        let work: @Sendable () async -> Void
        init(name: String, interval: TimeInterval, work: @escaping @Sendable () async -> Void) {
            self.name = name; self.interval = interval; self.work = work
        }
    }

    public let config: HelperConfig
    public let options: Options
    public let runtime: HelperRuntime
    private let gate: StreamGate
    private let lock = NSLock()

    // Everything below is guarded by `lock`.
    private var phase = Phase.new
    private var status: DaemonStatus
    private var fileLock: HelperLock?
    private var scheduler: Task<Void, Never>?
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var jobs: [Job] = []
    private var stopObserving: (() -> Void)?
    private var remindersDirty = true
    private var lastRemindersSnapshot = Date.distantPast

    public init(config: HelperConfig, environment: HelperEnvironment, options: Options = Options()) {
        self.config = config
        self.options = options
        runtime = HelperRuntime(config: config, environment: environment, stateFiles: options.stateFiles, retryDelays: options.retryDelays)
        gate = StreamGate(heartbeat: config.heartbeat_seconds)
        status = DaemonStatus(pid: getpid(), version: HelperVersion.string, started_at: Date(), updated_at: Date(),
                              calendar_authorization: nil, reminders_authorization: nil, streams: [:])
    }

    // MARK: lifecycle

    public var isRunning: Bool { lock.withLock { phase == .running } }

    /// The status as written to `status.json`.
    public var currentStatus: DaemonStatus { lock.withLock { status } }

    /// Takes the helper lock and starts the scheduler; returns at once. Throws
    /// `HelperStartError.anotherHelperRunning` when another helper holds the lock.
    public func start() throws {
        lock.lock()
        guard phase == .new else {
            lock.unlock()
            throw HelperStartError.alreadyStarted
        }
        do {
            fileLock = try HelperLock.acquire(path: options.stateFiles.lock)
        } catch {
            lock.unlock()
            throw error
        }
        phase = .running
        let now = Date()
        status.started_at = now
        status.updated_at = now
        jobs = makeJobs()
        let snapshot = status
        scheduler = Task.detached(priority: .utility) { [self] in await self.schedule() }
        lock.unlock()
        snapshot.save(path: options.stateFiles.status)

        log.info("organizer-helper \(HelperVersion.string) starting (pid \(getpid()), bundle id \(Bundle.main.bundleIdentifier ?? "none: Info.plist not embedded"))")
        log.info("server \(config.serverURL?.absoluteString ?? "(unset)"), host \(runtime.host)")
        if let problem = config.serverURLProblem { log.error("\(problem); pushes will fail") }
        if config.usesInsecureHTTP { log.warn("server.url is plain http to another host (allow_insecure_http); the token travels unencrypted") }
    }

    /// Stops scheduling, lets in-flight jobs finish for up to `stopGraceSeconds`, then cancels
    /// what is left (a cancelled push is never sent) and releases the lock. Safe to call more
    /// than once.
    public func stop() async {
        await Task.detached { await self.stopNow() }.value
    }

    private func stopNow() async {
        let begun = lock.withLock { () -> Task<Void, Never>?? in
            guard phase == .running else { return nil }
            phase = .stopping
            let s = scheduler
            scheduler = nil
            return .some(s)
        }
        guard let sched = begun else { return }
        log.info("stopping")
        sched?.cancel()
        if !(await waitForJobs(seconds: options.stopGraceSeconds)) {
            lock.withLock { for task in inFlight.values { task.cancel() } }
            _ = await waitForJobs(seconds: 5)
        }
        let (stopObs, held, remaining) = lock.withLock { () -> ((() -> Void)?, HelperLock?, [Task<Void, Never>]) in
            let o = stopObserving
            stopObserving = nil
            let f = fileLock
            fileLock = nil
            phase = .stopped
            return (o, f, Array(inFlight.values))
        }
        stopObs?()
        if remaining.isEmpty {
            held?.release()
        } else {
            // A job that ignores cancellation keeps the lock until it ends.
            Task.detached {
                for task in remaining { await task.value }
                held?.release()
            }
        }
        log.info("stopped")
    }

    /// True when every job ended within `seconds`.
    private func waitForJobs(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, seconds))
        while true {
            if lock.withLock({ inFlight.isEmpty }) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: scheduling

    private var remindersInterval: TimeInterval {
        let r = config.reminders
        return max(10, r.apply_ops ? r.ops_poll_seconds : r.snapshot_seconds)
    }

    private func makeJobs() -> [Job] {
        var jobs: [Job] = []
        if config.calendar.enabled {
            jobs.append(Job(name: IngestStream.calendar.rawValue, interval: max(5, config.calendar.interval_seconds)) { [weak self] in
                await self?.runCalendar()
            })
        }
        if config.reminders.enabled {
            jobs.append(Job(name: IngestStream.reminders.rawValue, interval: remindersInterval) { [weak self] in
                await self?.runReminders()
            })
        }
        return jobs
    }

    /// Permissions first (no job runs while a prompt is up), then the tick.
    private func schedule() async {
        var observe = false
        if config.calendar.enabled { observe = await prepare(.calendar) || observe }
        if config.reminders.enabled { observe = await prepare(.reminders) || observe }
        guard !Task.isCancelled, isRunning else { return }
        if observe { installObserver() }
        let names = lock.withLock { jobs.map { "\($0.name)/\(Int($0.interval))s" } }
        log.info("jobs: " + (names.isEmpty ? "none (calendar and reminders are both off)" : names.joined(separator: ", ")))

        while !Task.isCancelled {
            guard tick(now: Date()) else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, options.tickSeconds) * 1_000_000_000))
        }
    }

    /// Starts each due job. False once the daemon is stopping.
    private func tick(now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .running else { return false }
        for job in jobs where !job.running {
            let debounced = job.dirtySince.map { now.timeIntervalSince($0) >= config.calendar.debounce_seconds } ?? false
            guard now >= job.nextRun || debounced else { continue }
            job.running = true
            job.dirtySince = nil
            inFlight[job.name] = Task.detached(priority: .utility) { [self] in
                await job.work()
                self.finish(job)
            }
        }
        return true
    }

    private func finish(_ job: Job) {
        lock.lock(); defer { lock.unlock() }
        job.running = false
        job.nextRun = Date().addingTimeInterval(job.interval)
        inFlight.removeValue(forKey: job.name)
    }

    private func installObserver() {
        let already = lock.withLock { stopObserving != nil || phase != .running }
        guard !already else { return }
        let stop = runtime.environment.observeChanges { [weak self] in self?.markStoreDirty() }
        lock.withLock { stopObserving = stop }
    }

    /// Asks for access on first run (when `requestAccessOnStart`). True when granted.
    private func prepare(_ stream: IngestStream) async -> Bool {
        let permissions = runtime.environment.permissions
        let read = { stream == .calendar ? permissions.calendars() : permissions.reminders() }
        var s = read()
        log.info("\(stream.rawValue): authorization \(s.rawValue)")
        if s.canRequest, options.requestAccessOnStart, !Task.isCancelled {
            log.info("\(stream.rawValue): requesting full access (macOS shows a prompt for \(HelperRuntime.appName))")
            let granted = stream == .calendar ? await permissions.requestCalendars() : await permissions.requestReminders()
            s = read()
            log.info("\(stream.rawValue): request \(granted ? "granted" : "not granted"); now \(s.rawValue)")
        }
        setAuthorization(stream, s)
        return s == .fullAccess
    }

    /// An EventKit change covers events and reminders alike (one store): re-run both soon.
    private func markStoreDirty() {
        lock.lock(); defer { lock.unlock() }
        remindersDirty = true
        for job in jobs where job.dirtySince == nil { job.dirtySince = Date() }
    }

    private func takeRemindersDirty() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let dirty = remindersDirty
        remindersDirty = false
        return dirty
    }

    // MARK: jobs

    private func runCalendar() async {
        let s = runtime.environment.permissions.calendars()
        setAuthorization(.calendar, s)
        guard s == .fullAccess else {
            fail("calendar", "skipped: calendar access is \(s.rawValue)")
            return
        }
        record("calendar", await runtime.runStream(.calendar, gate: gate))
    }

    private func runReminders() async {
        let s = runtime.environment.permissions.reminders()
        setAuthorization(.reminders, s)
        guard s == .fullAccess else {
            fail("reminders", "skipped: reminders access is \(s.rawValue)")
            return
        }
        var changed = false
        var parts: [String] = []
        var failures: [String] = []
        if config.reminders.apply_ops {
            let at = Date()
            let r = await runtime.reminders.applyOps(server: runtime.server, now: at)
            if r.changed || r.failed { log.info("reminders: \(r.summary)") }
            changed = r.changed
            update("reminders.ops") { st in
                st.last_attempt = at
                st.last_result = r.summary
                if r.failed { st.last_error = r.summary; st.last_error_at = at } else { st.last_success = at }
            }
            parts.append("ops: \(r.summary)")
            if r.failed { failures.append("ops: \(r.summary)") }
        }
        var cancelled = Task.isCancelled
        if !cancelled {
            let now = Date()
            let due = now.timeIntervalSince(lastRemindersSnapshot) >= config.reminders.snapshot_seconds
            // Ops just written: push a fresh snapshot now so the organizer mirrors the result.
            if takeRemindersDirty() || changed || due {
                lastRemindersSnapshot = now
                let outcome = await runtime.runStream(.reminders, gate: gate)
                record("reminders.snapshot", outcome)
                switch outcome {
                case .delivered(let p): parts.append("snapshot: pushed: \(p.summary)")
                case .unchanged(let p): parts.append("snapshot: unchanged: \(p.summary)")
                case .failed(let why):
                    parts.append("snapshot: error: \(why)")
                    failures.append("snapshot: \(why)")
                case .cancelled: cancelled = true
                }
            }
        }
        let at = Date()
        update("reminders") { st in
            st.last_attempt = at
            st.last_result = (parts + (cancelled ? ["cancelled"] : [])).joined(separator: "; ")
            if !failures.isEmpty {
                st.last_error = failures.joined(separator: "; ")
                st.last_error_at = at
            } else if !cancelled {
                st.last_success = at
            }
        }
    }

    // MARK: status

    private func record(_ name: String, _ outcome: HelperRuntime.StreamOutcome) {
        let at = Date()
        update(name) { s in
            s.last_attempt = at
            switch outcome {
            case .delivered(let p): s.last_success = at; s.last_result = "pushed: \(p.summary)"
            case .unchanged(let p): s.last_success = at; s.last_result = "unchanged: \(p.summary)"
            case .failed(let why): s.last_result = "error: \(why)"; s.last_error = why; s.last_error_at = at
            case .cancelled: s.last_result = "cancelled"
            }
        }
    }

    private func fail(_ name: String, _ why: String) {
        let at = Date()
        update(name) { s in
            s.last_attempt = at
            s.last_result = why
            s.last_error = why
            s.last_error_at = at
        }
    }

    private func setAuthorization(_ stream: IngestStream, _ s: HelperAuthorization) {
        lock.lock()
        if stream == .calendar { status.calendar_authorization = s.rawValue } else { status.reminders_authorization = s.rawValue }
        status.updated_at = Date()
        let snapshot = status
        lock.unlock()
        snapshot.save(path: options.stateFiles.status)
    }

    private func update(_ name: String, _ mutate: (inout DaemonStatus.Stream) -> Void) {
        lock.lock()
        var s = status.streams[name] ?? DaemonStatus.Stream()
        mutate(&s)
        status.streams[name] = s
        status.updated_at = Date()
        let snapshot = status
        lock.unlock()
        snapshot.save(path: options.stateFiles.status)
    }
}
