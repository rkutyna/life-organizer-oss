import Foundation
import Testing

@testable import OrganizerUI

@Suite("Deep links")
struct DeepLinkTests {
    @Test func readsModulePathAndQuery() throws {
        let link = try #require(DeepLink(URL(string: "lifeorganizer://jobs/applications/12?tab=notes")!))
        #expect(link.module == .jobs)
        #expect(link.path == ["applications", "12"])
        #expect(link.query == ["tab": "notes"])
        #expect(DeepLink(URL(string: "lifeorganizer://reminders?reminder=5")!)?.query == ["reminder": "5"])
        #expect(DeepLink(URL(string: "lifeorganizer://Mail/a%20b")!)?.path == ["a b"])
    }

    @Test func buildsURLsThatReadBack() throws {
        #expect(DeepLink(module: .jobs).url?.absoluteString == "lifeorganizer://jobs")
        #expect(DeepLink(module: .reminders, query: ["reminder": "3"]).url?.absoluteString == "lifeorganizer://reminders?reminder=3")
        let url = try #require(DeepLink(module: .jobs, path: ["applications", "a/b c"], query: ["tab": "notes", "add": "x y"]).url)
        #expect(url.absoluteString == "lifeorganizer://jobs/applications/a%2Fb%20c?add=x%20y&tab=notes")
        #expect(DeepLink(url)?.path == ["applications", "a/b c"])
    }

    @Test func refusesOtherSchemesAndUnknownModules() {
        #expect(DeepLink(URL(string: "organizer://jobs")!) == nil)
        #expect(DeepLink(URL(string: "https://jobs/applications/1")!) == nil)
        #expect(DeepLink(URL(string: "lifeorganizer://nowhere")!) == nil)
    }
}
