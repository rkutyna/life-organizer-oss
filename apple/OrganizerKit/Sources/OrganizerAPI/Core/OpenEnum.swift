import Foundation

/// A string enum from the API that tolerates values this build does not know.
///
/// Every enum the generator writes conforms: its known cases, plus `unknown(String)` for a
/// value a newer server sends. Decoding never fails on a new value, so an installed app keeps
/// working when the server grows a state; switch over the known cases and handle `.unknown`
/// with a neutral fallback.
///
///     switch reminder.sync.state {
///     case .synced: ...
///     case .syncing, .waitingForMac, .failed: ...
///     case .unknown: EmptyView()
///     }
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable, CaseIterable, QueryValue,
    QueryParameter
where RawValue == String, AllCases == [Self] {
    init(rawValue: String)
}

extension OpenEnum {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var queryValue: String { rawValue }
}
