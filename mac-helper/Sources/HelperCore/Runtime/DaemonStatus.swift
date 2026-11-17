import Foundation

/// What the daemon last did (`<state dir>/status.json`), for `status` and `doctor`, which may run
/// in a terminal whose permission view differs from the daemon's.
public struct DaemonStatus: Codable, Sendable, Equatable {
    public struct Stream: Codable, Sendable, Equatable {
        public var last_attempt: Date?
        public var last_success: Date?
        public var last_result: String?
        public var last_error: String?
        public var last_error_at: Date?

        public init() {}
    }

    public var pid: Int32
    public var version: String
    public var started_at: Date
    public var updated_at: Date
    public var calendar_authorization: String?
    public var reminders_authorization: String?
    /// Keyed `calendar`, `reminders`, and the reminders steps `reminders.ops` and `reminders.snapshot`.
    public var streams: [String: Stream]

    public static func load(path: String) -> DaemonStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONCoding.decoder().decode(DaemonStatus.self, from: data)
    }

    func save(path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONCoding.encoder(pretty: true).encode(self) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
