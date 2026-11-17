import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
    public var out: String { String(decoding: stdout, as: UTF8.self) }
    public var err: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ShellError: Error, CustomStringConvertible {
    case launch(String, Error)

    public var description: String {
        switch self {
        case .launch(let tool, let e): return "failed to launch \(tool): \(e)"
        }
    }
}

/// Runs a child process without a shell (arguments are passed verbatim, never interpolated).
/// Only `launchctl` (install, uninstall, status) and `codesign -dv` (doctor) are run.
public enum Shell {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { throw ShellError.launch(executable, error) }

        // Drain both pipes concurrently so a large stdout cannot fill the pipe buffer.
        let outData = Captured(), errData = Captured()
        let outReader = outPipe.fileHandleForReading, errReader = errPipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData.data = outReader.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData.data = errReader.readDataToEndOfFile()
            group.leave()
        }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = group.wait(timeout: .now() + 5)
        }
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus, stdout: outData.data, stderr: errData.data, timedOut: timedOut)
    }

    /// One pipe's output, written by its reader block before `group.leave()` and read after
    /// `group.wait()`, which orders the two.
    private final class Captured: @unchecked Sendable {
        var data = Data()
    }
}
