import Foundation

extension OrganizerClient {
    /// Liveness and freshness: `/api/status`.
    public var status: StatusAPI { StatusAPI(client: self) }
}

public struct StatusAPI: Sendable {
    let client: OrganizerClient

    /// `GET /api/status`: the server is up, its time zone and its modules. Settings' "Test
    /// connection" calls this.
    public func check() async throws -> StatusOut {
        try await client.send(API.Status.status())
    }

    /// Each mirrored source's freshness (ok, stale, error, never).
    public func sources() async throws -> [SourceStatusOut] {
        try await client.send(API.Status.listSourceStatus())
    }
}
