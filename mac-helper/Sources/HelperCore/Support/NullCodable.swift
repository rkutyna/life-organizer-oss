import Foundation

/// An optional that is always present on the wire: `nil` encodes as JSON `null` instead of
/// dropping the key (Swift's synthesized `Encodable` omits nil optionals). The ingest contract
/// sends every optional field as an explicit `null`, so every optional payload field uses this.
@propertyWrapper
public struct NullCodable<T: Codable & Equatable>: Codable, Equatable {
    public var wrappedValue: T?

    public init(wrappedValue: T?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try c.decode(T.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
    }
}

extension NullCodable: Sendable where T: Sendable {}

extension KeyedDecodingContainer {
    /// Lets synthesized decoding accept a missing key for a `@NullCodable` property.
    public func decode<T>(_ type: NullCodable<T>.Type, forKey key: Key) throws -> NullCodable<T> {
        try decodeIfPresent(type, forKey: key) ?? NullCodable(wrappedValue: nil)
    }
}
