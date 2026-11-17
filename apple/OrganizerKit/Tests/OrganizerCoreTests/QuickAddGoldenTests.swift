import Foundation
import OrganizerAPI
import OrganizerCore
import Testing



/// The native quick-add parser must agree with the web's (chrono-node, forwardDate) on every
/// golden case. The cases come from apple/scripts/quickadd-golden.mjs, which runs the web's
/// parser at fixed reference times. To add a case: add the input there, run the script, run
/// `swift test`.
struct GoldenFile: Decodable {
    let time_zone: String
    let cases: [GoldenCase]
}

struct GoldenCase: Decodable, Sendable, CustomTestStringConvertible {
    let now: String
    let input: String
    let expected: Expected

    struct Expected: Decodable, Equatable, Sendable {
        let title: String
        let due_date: String?
        let due_time: String?
        let priority: Int?
        let date_text: String?
    }

    var testDescription: String { "\(input) @ \(now)" }
}

enum Golden {
    static let file: GoldenFile = {
        let url = Bundle.module.url(forResource: "quickadd-golden", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
    }()

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: file.time_zone)!
        return calendar
    }

    /// "2026-10-23T10:30" as a local time in the golden time zone.
    static func date(_ local: String) -> Date {
        let parts = local.split(separator: "T")
        return LocalTime(String(parts[1]))!.date(on: LocalDate(String(parts[0]))!, calendar: calendar)
    }
}

@Suite("Quick-add parser")
struct QuickAddParserTests {
    @Test("matches the web parser", arguments: Golden.file.cases)
    func matchesWebParser(_ golden: GoldenCase) {
        let result = QuickAddParser.parse(golden.input, now: Golden.date(golden.now), calendar: Golden.calendar)
        let actual = GoldenCase.Expected(
            title: result.title,
            due_date: result.dueDate?.string,
            due_time: result.dueTime?.string,
            priority: result.priority,
            date_text: result.dateText
        )
        #expect(actual == golden.expected)
    }

    @Test func goldenFileCoversBothReferenceTimes() {
        #expect(Golden.file.cases.count >= 60)
        #expect(Set(Golden.file.cases.map(\.now)).count == 2)
    }
}
