import Foundation

/// What the Reminders sync remembers between runs (`<state dir>/reminders.json`):
/// `created_ops`, op id -> the reminder a create op made, so a create whose ack was lost is
/// acked again instead of creating a duplicate.
public struct RemindersState: Codable, Equatable, Sendable {
    public struct Created: Codable, Equatable, Sendable {
        public var local_id: String
        @NullCodable public var external_id: String?
        public var at: Date

        public init(local_id: String, external_id: String?, at: Date) {
            self.local_id = local_id; self.external_id = external_id; self.at = at
        }
    }

    public var created_ops: [String: Created] = [:]

    public init(created_ops: [Int: Created] = [:]) {
        self.created_ops = Dictionary(uniqueKeysWithValues: created_ops.map { (String($0.key), $0.value) })
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created_ops = try c.decodeIfPresent([String: Created].self, forKey: .created_ops) ?? [:]
    }

    public func created(op: Int) -> Created? { created_ops[String(op)] }

    public mutating func recordCreated(op: Int, _ entry: Created) { created_ops[String(op)] = entry }

    /// Forget creates older than a week (their acks have long been delivered).
    public mutating func prune(now: Date) {
        created_ops = created_ops.filter { now.timeIntervalSince($0.value.at) < 7 * 86_400 }
    }

    public static func load(path: String) -> RemindersState {
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? JSONCoding.decoder().decode(RemindersState.self, from: data) else { return RemindersState() }
        return state
    }

    public func save(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONCoding.encoder(pretty: true).encode(self) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
