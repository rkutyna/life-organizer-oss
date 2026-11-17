import Foundation

/// Size-capped file logger. Rotates to `.1` when the file passes `maxBytes` (so at most about
/// 2 x maxBytes on disk). Mirrors to stderr when stderr is a terminal, so launchd's own stderr
/// capture does not duplicate every line. Never log the ingest token.
public final class Log: @unchecked Sendable {
    public enum Level: String, Sendable { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    public static let shared = Log()

    private let lock = NSLock()
    private var handle: FileHandle?
    private var path: String?
    private var bytesWritten: UInt64 = 0
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private var toStderr = isatty(STDERR_FILENO) == 1
    private var verbose = false

    // Not Sendable; only used under `lock`.
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Sets the file (nil: no file) and verbosity. Safe to call again.
    public func configure(path: String?, verbose: Bool = false, stderr: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.path = path
        self.verbose = verbose
        if let stderr { toStderr = stderr }
        try? handle?.close()
        handle = nil
    }

    public func debug(_ msg: @autoclosure () -> String) {
        if lock.withLock({ verbose }) { write(.debug, msg()) }
    }
    public func info(_ msg: @autoclosure () -> String) { write(.info, msg()) }
    public func warn(_ msg: @autoclosure () -> String) { write(.warn, msg()) }
    public func error(_ msg: @autoclosure () -> String) { write(.error, msg()) }

    private func write(_ level: Level, _ msg: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) \(level.rawValue) \(msg)\n"
        let data = Data(line.utf8)
        if toStderr { FileHandle.standardError.write(data) }
        guard let path else { return }
        if handle == nil { open(path) }
        guard let handle else { return }
        handle.write(data)
        bytesWritten += UInt64(data.count)
        if bytesWritten > maxBytes { rotate(path) }
    }

    private func open(_ path: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        handle = FileHandle(forWritingAtPath: path)
        bytesWritten = (try? handle?.seekToEnd()) ?? 0
        if bytesWritten > maxBytes { rotate(path) }
    }

    private func rotate(_ path: String) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let old = path + ".1"
        try? fm.removeItem(atPath: old)
        try? fm.moveItem(atPath: path, toPath: old)
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = FileHandle(forWritingAtPath: path)
        bytesWritten = 0
    }
}

public let log = Log.shared
