import Foundation

/// A request-body field that can be left out, sent as null, or sent with a value.
///
/// PATCH bodies change only the fields they carry, and null clears a field. A plain Optional
/// cannot say "clear it", so every optional, nullable field of a request body is an
/// `Omittable` (the generator decides; see apple/README.md "API types"):
///
///     TaskUpdate(title: .value("Call the plumber"))   // change the title only
///     TaskUpdate(dueDate: .null)                      // clear the due date (and its time)
///     TaskUpdate(priority: .orNull(newPriority))      // an Int? -> value or null
public enum Omittable<Wrapped> {
    /// Left out of the body: the server keeps the current value (or its default).
    case omitted
    /// Sent as JSON null: the server clears the field.
    case null
    /// Sent with this value.
    case value(Wrapped)

    /// `.value(x)` for a value, `.null` for nil. Use it to send an Optional as it is.
    public static func orNull(_ optional: Wrapped?) -> Omittable {
        optional.map(Omittable.value) ?? .null
    }

    /// `.value(x)` for a value, `.omitted` for nil.
    public static func ifPresent(_ optional: Wrapped?) -> Omittable {
        optional.map(Omittable.value) ?? .omitted
    }

    public var isOmitted: Bool {
        if case .omitted = self { return true }
        return false
    }

    /// The value, nil for `.omitted` and `.null`.
    public var value: Wrapped? {
        if case .value(let value) = self { return value }
        return nil
    }
}

extension Omittable: Equatable where Wrapped: Equatable {}
extension Omittable: Hashable where Wrapped: Hashable {}
extension Omittable: Sendable where Wrapped: Sendable {}

extension KeyedEncodingContainer {
    /// Writes nothing for `.omitted`, null for `.null`, the value for `.value`.
    public mutating func encodeOmittable<T: Encodable>(_ field: Omittable<T>, forKey key: Key) throws {
        switch field {
        case .omitted: break
        case .null: try encodeNil(forKey: key)
        case .value(let value): try encode(value, forKey: key)
        }
    }
}

extension KeyedDecodingContainer {
    /// A missing key is `.omitted`, null is `.null`.
    public func decodeOmittable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> Omittable<T> {
        guard contains(key) else { return .omitted }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(T.self, forKey: key))
    }
}

/// A coding key made from any string, for generated types with no properties.
public struct AnyCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?
    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
