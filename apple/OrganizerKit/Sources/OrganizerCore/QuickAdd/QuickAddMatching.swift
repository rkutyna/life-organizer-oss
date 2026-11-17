import Foundation
import OrganizerAPI

/// "Now", as the wall clock in the calendar's time zone. Every date and hour is worked out from this.
nonisolated struct QuickAddReference {
    let now: Date
    let calendar: Calendar
    let today: LocalDate
    let time: LocalTime

    init(now: Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
        today = LocalDate(now, calendar: calendar)
        time = LocalTime(now, calendar: calendar)
    }

    /// Today moved by `value` of `component` (days, months, years).
    func shifted(by value: Int, _ component: Calendar.Component) -> LocalDate {
        LocalDate(calendar.date(byAdding: component, value: value, to: today.date(in: calendar))!, calendar: calendar)
    }

    /// The day with these parts, or nil when the calendar has no such day (February 30).
    func makeDay(year: Int, month: Int, day: Int) -> LocalDate? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let result = LocalDate(date, calendar: calendar)
        return result == LocalDate(year: year, month: month, day: day) ? result : nil
    }

    /// The next time this month and day come round, counting today: this year if it is not yet past.
    func nextOccurrence(month: Int, day: Int) -> LocalDate? {
        for year in today.year...(today.year + 8) {
            if let candidate = makeDay(year: year, month: month, day: day), !(candidate < today) {
                return candidate
            }
        }
        return nil
    }
}

/// One phrase a sub-parser found. It names a day, an hour, or both. The merge step joins a day
/// phrase and an hour phrase that sit next to each other.
nonisolated struct QuickAddCandidate {
    /// The matched text, as typed.
    let range: Range<String.Index>
    /// The day the phrase names. Nil for a bare hour, which is today, or tomorrow once it has passed.
    let date: LocalDate?
    /// The hour the phrase names. Nil for a day-only phrase.
    let time: LocalTime?
    /// False for morning, afternoon, evening and night: their hour only orders the forward check.
    let hourIsCertain: Bool
}

/// The first phrase in the text, resolved to what quick-add reports.
nonisolated struct QuickAddMatch {
    let range: Range<String.Index>
    let day: LocalDate
    /// Nil unless the hour is certain ("3pm", "at 9:30", "noon", "in 2 hours", but not "morning").
    let time: LocalTime?
}

/// Picks the first phrase and resolves it. The sub-parsers each find their own candidates; this
/// file decides which one wins and how it is merged and dated.
nonisolated enum QuickAddMatching {
    static func firstMatch(in text: String, reference: QuickAddReference) -> QuickAddMatch? {
        let candidates = nonOverlapping(allCandidates(in: text, reference: reference))
        guard let first = candidates.first else { return nil }
        let phrase = candidates.count > 1 ? (merge(first, candidates[1], in: text) ?? first) : first
        return resolve(phrase, reference: reference)
    }

    private static func allCandidates(in text: String, reference: QuickAddReference) -> [QuickAddCandidate] {
        var found: [QuickAddCandidate] = []
        found += QuickAddCasualParser.days(in: text, reference: reference)
        found += QuickAddCasualParser.times(in: text, reference: reference)
        found += QuickAddWeekdayParser.candidates(in: text, reference: reference)
        found += QuickAddRelativeParser.candidates(in: text, reference: reference)
        found += QuickAddMonthNameParser.candidates(in: text, reference: reference)
        found += QuickAddNumericDateParser.candidates(in: text, reference: reference)
        found += QuickAddClockParser.candidates(in: text)
        return found
    }

    /// Earliest first. Where two candidates start together the longer one wins ("at 3pm" over "at 3").
    private static func nonOverlapping(_ candidates: [QuickAddCandidate]) -> [QuickAddCandidate] {
        let sorted = candidates.sorted { a, b in
            if a.range.lowerBound != b.range.lowerBound { return a.range.lowerBound < b.range.lowerBound }
            return a.range.upperBound > b.range.upperBound
        }
        var kept: [QuickAddCandidate] = []
        for candidate in sorted where kept.last.map({ candidate.range.lowerBound >= $0.range.upperBound }) ?? true {
            kept.append(candidate)
        }
        return kept
    }

    /// A day phrase and an hour phrase, one after the other, with at most "at", "on" or a comma
    /// between them, become one phrase. Works both ways: "tomorrow 3pm" and "at 3pm tomorrow".
    private static func merge(_ first: QuickAddCandidate, _ second: QuickAddCandidate, in text: String) -> QuickAddCandidate? {
        let gap = String(text[first.range.upperBound..<second.range.lowerBound])
        guard !QuickAddPattern(#"^\s*(?:at|on|,)?\s*$"#).matches(in: gap).isEmpty else { return nil }
        let span = first.range.lowerBound..<second.range.upperBound
        if let date = first.date, first.time == nil, let time = second.time, second.date == nil {
            return QuickAddCandidate(range: span, date: date, time: time, hourIsCertain: second.hourIsCertain)
        }
        if let time = first.time, first.date == nil, let date = second.date, second.time == nil {
            return QuickAddCandidate(range: span, date: date, time: time, hourIsCertain: first.hourIsCertain)
        }
        return nil
    }

    private static func resolve(_ phrase: QuickAddCandidate, reference: QuickAddReference) -> QuickAddMatch {
        let day: LocalDate
        if let date = phrase.date {
            day = date
        } else if let time = phrase.time, time < reference.time {
            day = reference.shifted(by: 1, .day)  // the hour has passed today: forwardDate moves it on
        } else {
            day = reference.today
        }
        return QuickAddMatch(range: phrase.range, day: day, time: phrase.hourIsCertain ? phrase.time : nil)
    }
}

/// A case-insensitive regular expression and the matches it finds. Built per call: a quick-add line is short.
nonisolated struct QuickAddPattern {
    private let regex: NSRegularExpression

    init(_ source: String) {
        regex = try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    /// Every match in `text`, leftmost first.
    func matches(in text: String) -> [QuickAddPatternMatch] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let groups = (0..<result.numberOfRanges).map { index in
                Range(result.range(at: index), in: text).map { String(text[$0]) }
            }
            return QuickAddPatternMatch(range: range, groups: groups)
        }
    }
}

nonisolated struct QuickAddPatternMatch {
    /// The whole match.
    let range: Range<String.Index>
    /// Capture groups; index 0 is the whole match. Nil for a group that did not take part.
    let groups: [String?]

    func group(_ index: Int) -> String? {
        groups.indices.contains(index) ? groups[index] : nil
    }
}
