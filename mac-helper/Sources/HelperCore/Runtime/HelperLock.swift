import Foundation

/// Never two helpers: an exclusive advisory lock (`flock`) on `<state dir>/helper.lock`, held for
/// the life of `organizer-helper run`. Two helpers would each apply the organizer's Reminders ops.
///
/// - `flock` locks belong to the open file description, so a second `acquire` fails even in the
///   same process; the kernel drops the lock when the holder exits, however it exits, so a crash
///   never leaves a stale lock.
/// - The holder writes who it is into the file (pid, version), so a refused start can name it.
///   The file is never deleted (that would race with a new holder); it is emptied on release.
/// - Read-only commands (`doctor`, `status`) never take it.
public final class HelperLock: @unchecked Sendable {
    public struct Holder: Codable, Sendable, Equatable, CustomStringConvertible {
        public var pid: Int32
        public var version: String
        public var started_at: Date
        public var executable: String?

        public var description: String {
            "organizer-helper run, pid \(pid), version \(version), since \(ISODate.string(started_at))"
        }
    }

    public let path: String
    public let holder: Holder
    private let lock = NSLock()
    private var fd: Int32

    private init(path: String, fd: Int32, holder: Holder) {
        self.path = path
        self.fd = fd
        self.holder = holder
    }

    deinit { release() }

    /// Takes the lock without waiting. Throws `HelperStartError.anotherHelperRunning` (naming the
    /// holder when its file is readable) when another helper has it.
    public static func acquire(path: String) throws -> HelperLock {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw HelperStartError.lockFile("cannot create \(dir): \(error.localizedDescription)")
        }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw HelperStartError.lockFile("cannot open \(path): \(Self.errorText(errno))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(fd)
            if e == EWOULDBLOCK { throw HelperStartError.anotherHelperRunning(readHolder(path: path), lockPath: path) }
            throw HelperStartError.lockFile("cannot lock \(path): \(Self.errorText(e))")
        }
        // Whole seconds, as the file stores them, so `holder` equals what readers decode.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let me = Holder(pid: getpid(), version: HelperVersion.string, started_at: now, executable: Bundle.main.executablePath)
        if let data = try? JSONCoding.encoder().encode(me) {
            _ = ftruncate(fd, 0)
            _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
        return HelperLock(path: path, fd: fd, holder: me)
    }

    public var isHeld: Bool { lock.withLock { fd >= 0 } }

    /// Empties the file and drops the lock. Idempotent; also done on deinit.
    public func release() {
        lock.withLock {
            guard fd >= 0 else { return }
            _ = ftruncate(fd, 0)
            _ = flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// Read-only: the holder named in the file when that process is alive.
    public static func currentHolder(path: String) -> Holder? {
        guard let h = readHolder(path: path) else { return nil }
        return kill(h.pid, 0) == 0 || errno == EPERM ? h : nil
    }

    static func readHolder(path: String) -> Holder? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        return try? JSONCoding.decoder().decode(Holder.self, from: data)
    }

    private static func errorText(_ e: Int32) -> String { String(cString: strerror(e)) }
}

/// Why a start was refused.
public enum HelperStartError: Error, CustomStringConvertible, Sendable, Equatable {
    /// This daemon is already started; a daemon is single-use.
    case alreadyStarted
    /// Another helper holds the lock (nil: the lock file could not be read).
    case anotherHelperRunning(HelperLock.Holder?, lockPath: String)
    case lockFile(String)

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "the helper is already running in this process"
        case .anotherHelperRunning(let holder, let path):
            guard let holder else { return "another helper holds \(path); stop it first" }
            return "another helper is running: \(holder); stop it first (lock \(path))"
        case .lockFile(let why):
            return "helper lock: \(why)"
        }
    }
}
