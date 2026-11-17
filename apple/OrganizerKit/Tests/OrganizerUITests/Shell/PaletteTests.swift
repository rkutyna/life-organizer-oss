import SwiftUI
import Testing

@testable import OrganizerUI

@Suite("Palette")
struct PaletteTests {
    /// A calendar source key is read as its token (web/src/styles/tokens.css), as the web's cssKey().
    @Test func serverSourceKeysReadAsTheirTokens() {
        let tokens = [
            "apple": "apple", "reminders": "reminders", "holidays": "holidays",
            "jobs_interviews": "jobs_interviews", "calendar_ext": "calendar_ext",
        ]
        for (key, token) in tokens {
            #expect(Palette.sourceToken(key) == token, "\(key)")
        }
    }

    /// Normalized as the web's cssKey(): case, and any run of other characters is one separator.
    @Test func tokenNamesNormalizeLikeTheWeb() {
        #expect(Palette.sourceToken("job_events") == "job_events")
        #expect(Palette.sourceToken("job-events") == "job_events")
        #expect(Palette.sourceToken("Next Actions") == "next_actions")
        #expect(Palette.sourceToken("JOBS.Next_Actions") == "jobs_next_actions")
        #expect(Palette.sourceToken("a.-b") == "a_b")
    }

    @Test func unknownSourcesUseTheServersColor() {
        #expect(Palette.source("someone.new", fallback: "#112233") == Palette.hex("#112233"))
        #expect(Palette.source("someone.new") == Palette.sourceDefault)
    }

    /// As the web's itemColor: Apple calendars and reminder lists keep their own colour.
    @Test func appleAndReminderItemsKeepTheirOwnColors() {
        #expect(Palette.ownColorSources == ["apple", "reminders"])
        #expect(Palette.item(source: "apple", color: "#00FF00") == Palette.hex("#00FF00"))
        #expect(Palette.item(source: "reminders", color: "#F19A37") == Palette.hex("#F19A37"))
        #expect(Palette.item(source: "holidays", color: "#4f46e5") != Palette.hex("#4f46e5"))
        #expect(Palette.item(source: "someone.new", color: "#4f46e5") == Palette.hex("#4f46e5"))
    }
}
