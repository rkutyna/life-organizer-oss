import CryptoKit
import Foundation

public enum JSONCoding {
    /// Deterministic encoder: sorted keys, ISO-8601 dates with the given zone's offset.
    public static func encoder(pretty: Bool = false, timeZone: TimeZone = .current) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISODate.string(date, timeZone: timeZone))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = ISODate.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 date: \(s)")
        }
        return d
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The two snapshot streams the helper pushes.
public enum IngestStream: String, CaseIterable, Sendable, Codable {
    case calendar, reminders

    public var path: String { "/api/ingest/\(rawValue)" }
}

/// One stream's payload, ready to push. The body hash drives change detection and deliberately
/// excludes `collected_at` (which changes every run).
public struct EncodedPayload: Sendable {
    public let stream: IngestStream
    public let bodyHash: String
    public let json: Data
    public let summary: String

    public var key: String { stream.rawValue }
    public var bytes: Int { json.count }
}

public enum PayloadEncoder {
    /// Encodes `{collected_at, host, ...body}`. The hash covers only the body's canonical
    /// (sorted-key) JSON, so an unchanged snapshot hashes the same on every poll.
    public static func encode<Body: Encodable>(
        stream: IngestStream,
        body: Body,
        host: String?,
        collectedAt: Date = Date(),
        summary: String = "",
        timeZone: TimeZone = .current
    ) throws -> EncodedPayload {
        let bodyData = try JSONCoding.encoder(timeZone: timeZone).encode(body)
        let hash = JSONCoding.sha256Hex(bodyData)
        guard var object = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            throw EncodingError.invalidValue(body, .init(codingPath: [], debugDescription: "payload body must be an object"))
        }
        object["collected_at"] = ISODate.string(collectedAt, timeZone: timeZone)
        object["host"] = host ?? NSNull()
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return EncodedPayload(stream: stream, bodyHash: hash, json: json, summary: summary)
    }

    public static func bodyHash<Body: Encodable>(_ body: Body) throws -> String {
        JSONCoding.sha256Hex(try JSONCoding.encoder().encode(body))
    }
}
