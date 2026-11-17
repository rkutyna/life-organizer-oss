import Foundation
import OrganizerAPI

// Each sub-parser finds its own kind of phrase and returns candidates with their ranges.
// QuickAddMatching picks the earliest and merges an adjacent hour or day into it.

/// "today", "tonight", "tomorrow", "the day after tomorrow"; "morning" and the other times of day;
/// "noon" and "midnight".
nonisolated enum QuickAddCasualParser {
    static func days(in text: String, reference: QuickAddReference) -> [QuickAddCandidate] {
        QuickAddPattern(#"\b(the\s+day\s+after\s+tomorrow|tomorrow|tonight|today)\b"#).matches(in: text).compactMap { match in
            guard let word = match.group(1) else { return nil }
            let normalized = word.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            let offset = switch normalized {
            case "tomorrow": 1
            case "the day after tomorrow": 2
            default: 0
            }
            return QuickAddCandidate(range: match.range, date: reference.shifted(by: offset, .day), time: nil, hourIsCertain: false)
        }
    }

    static func times(in text: String, reference: QuickAddReference) -> [QuickAddCandidate] {
        var found: [QuickAddCandidate] = []
        // "morning", "this afternoon". The hour is implied; "this" also names today.
        for match in QuickAddPattern(#"\b(this\s+)?(morning|afternoon|evening|night)\b"#).matches(in: text) {
            guard let part = match.group(2)?.lowercased() else { continue }
            let hour = switch part {
            case "morning": 6
            case "afternoon": 15
            default: 20
            }
            let day: LocalDate? = match.group(1) == nil ? nil : reference.today
            found.append(QuickAddCandidate(range: match.range, date: day, time: LocalTime(hour: hour, minute: 0), hourIsCertain: false))
        }
        // "noon" and "midnight" are certain.
        for match in QuickAddPattern(#"\b(noon|midnight)\b"#).matches(in: text) {
            let hour = match.group(1)?.lowercased() == "noon" ? 12 : 0
            found.append(QuickAddCandidate(range: match.range, date: nil, time: LocalTime(hour: hour, minute: 0), hourIsCertain: true))
        }
        return found
    }
}

/// A weekday, optionally after "on", "this" or "next". Calendar weekdays are 1 (Sunday) to 7.
nonisolated enum QuickAddWeekdayParser {
    static func candidates(in text: String, reference: QuickAddReference) -> [QuickAddCandidate] {
        let pattern = #"\b(on\s+)?(this\s+|next\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday|tues|thurs|thur|sun|mon|tue|wed|thu|fri|sat)\b"#
        let todayWeekday = reference.calendar.component(.weekday, from: reference.today.date(in: reference.calendar))
        return QuickAddPattern(pattern).matches(in: text).compactMap { match in
            guard let name = match.group(3), let target = weekdayNumber(name) else { return nil }
            var offset = (target - todayWeekday + 7) % 7
            let isNext = match.group(2)?.lowercased().hasPrefix("next") ?? false
            if isNext && offset == 0 { offset = 7 }  // "next friday" on a Friday is a week on
            return QuickAddCandidate(range: match.range, date: reference.shifted(by: offset, .day), time: nil, hourIsCertain: false)
        }
    }

    private static func weekdayNumber(_ name: String) -> Int? {
        switch String(name.lowercased().prefix(3)) {
        case "sun": 1
        case "mon": 2
        case "tue": 3
        case "wed": 4
        case "thu": 5
        case "fri": 6
        case "sat": 7
        default: nil
        }
    }
}

/// "in 2 weeks", "in 30 minutes", "in 2 hours", "next week", "next month", "next year".
nonisolated enum QuickAddRelativeParser {
    static func candidates(in text: String, reference: QuickAddReference) -> [QuickAddCandidate] {
        var found: [QuickAddCandidate] = []
        for match in QuickAddPattern(#"\bin\s+(\d{1,3})\s+(minutes?|mins?|hours?|hrs?|days?|weeks?|months?|years?)\b"#).matches(in: text) {
            guard let amount = match.group(1).flatMap({ Int($0) }), let unit = match.group(2),
                  let candidate = moved(amount, unit: unit, range: match.range, reference: reference)
            else { continue }
            found.append(candidate)
        }
        for match in QuickAddPattern(#"\bnext\s+(week|month|year)\b"#).matches(in: text) {
            guard let unit = match.group(1),
                  let candidate = moved(1, unit: unit, range: match.range, reference: reference)
            else { continue }
            found.append(candidate)
        }
        return found
    }

    /// Minutes and hours move from now (so they carry a certain hour). Days, weeks, months and years
    /// move from today (so they name a day only).
    private static func moved(_ amount: Int, unit: String, range: Range<String.Index>, reference: QuickAddReference) -> QuickAddCandidate? {
        guard let parts = unitComponent(unit) else { return nil }
        let (component, factor) = parts
        let value = amount * factor
        switch component {
        case .minute, .hour:
            guard let moment = reference.calendar.date(byAdding: component, value: value, to: reference.now) else { return nil }
            return QuickAddCandidate(
                range: range,
                date: LocalDate(moment, calendar: reference.calendar),
                time: LocalTime(moment, calendar: reference.calendar),
                hourIsCertain: true
            )
        default:
            return QuickAddCandidate(range: range, date: reference.shifted(by: value, component), time: nil, hourIsCertain: false)
        }
    }

    /// A unit word as a calendar component, and how many of it make one (a week is seven days).
    private static func unitComponent(_ word: String) -> (Calendar.Component, Int)? {
        let unit = word.lowercased()
        if unit.hasPrefix("min") { return (.minute, 1) }
        if unit.hasPrefix("h") { return (.hour, 1) }
        if unit.hasPrefix("d") { return (.day, 1) }
        if unit.hasPrefix("w") { return (.day, 7) }
        if unit.hasPrefix("mo") { return (.month, 1) }
        if unit.hasPrefix("y") { return (.year, 1) }
        return nil
    }
}

/// "Oct 30", "Oct 30th", "Oct 30 2027", "30 oct", "24 October". A day without a year is the next
/// time that date comes round.
nonisolated enum QuickAddMonthNameParser {
    private static let months = #"(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)"#

    static func candidates(in text: String, reference: QuickAddReference) -> [QuickAddCandidate] {
        var found: [QuickAddCandidate] = []
        // Month first: groups are month, day, year.
        for match in QuickAddPattern(#"\b"# + months + #"\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4})\b)?"#).matches(in: text) {
            guard let monthWord = match.group(1), let dayText = match.group(2), let day = Int(dayText),
                  let date = resolveDate(month: monthWord, day: day, yearText: match.group(3), reference: reference)
            else { continue }
            found.append(QuickAddCandidate(range: match.range, date: date, time: nil, hourIsCertain: false))
        }
        // Day first: groups are day, month, year.
        for match in QuickAddPattern(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + months + #"\b(?:,?\s+(\d{4})\b)?"#).matches(in: text) {
            guard let dayText = match.group(1), let day = Int(dayText), let monthWord = match.group(2),
                  let date = resolveDate(month: monthWord, day: day, yearText: match.group(3), reference: reference)
            else { continue }
            found.append(QuickAddCandidate(range: match.range, date: date, time: nil, hourIsCertain: false))
        }
        return found
    }

    private static func resolveDate(month word: String, day: Int, yearText: String?, reference: QuickAddReference) -> LocalDate? {
        guard let month = monthNumber(word) else { return nil }
        if let yearText, let year = Int(yearText) {
            return reference.makeDay(year: year, month: month, day: day)
        }
        return reference.nextOccurrence(month: month, day: day)
    }

    private static func monthNumber(_ word: String) -> Int? {
        let abbreviations = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = abbreviations.firstIndex(of: String(word.lowercased().prefix(3))) else { return nil }
        return index + 1
    }
}

/// ISO "2026-12-20", and month/day with slashes: "10/28", "12/5/2027". A slash date without a year
/// is the next time it comes round.
nonisolated enum QuickAddNumericDateParser {
    static func candidates(in text: String, reference: QuickAddReference) -> [QuickAddCandidate] {
        var found: [QuickAddCandidate] = []
        for match in QuickAddPattern(#"(?<!\d)(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)"#).matches(in: text) {
            guard let year = Int(match.group(1) ?? ""), let month = Int(match.group(2) ?? ""),
                  let day = Int(match.group(3) ?? ""),
                  let date = reference.makeDay(year: year, month: month, day: day)
            else { continue }
            found.append(QuickAddCandidate(range: match.range, date: date, time: nil, hourIsCertain: false))
        }
        for match in QuickAddPattern(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?(?![\d/])"#).matches(in: text) {
            guard let month = Int(match.group(1) ?? ""), let day = Int(match.group(2) ?? "") else { continue }
            let date: LocalDate?
            if let yearText = match.group(3), let year = Int(yearText) {
                date = reference.makeDay(year: yearText.count == 2 ? 2000 + year : year, month: month, day: day)
            } else {
                date = reference.nextOccurrence(month: month, day: day)
            }
            guard let date else { continue }
            found.append(QuickAddCandidate(range: match.range, date: date, time: nil, hourIsCertain: false))
        }
        return found
    }
}

/// Clock times with a certain hour: "3pm", "8 pm", "3:30pm", "14:00", and "at 9:30" / "at 1",
/// where "at" is part of the phrase.
nonisolated enum QuickAddClockParser {
    static func candidates(in text: String) -> [QuickAddCandidate] {
        var found: [QuickAddCandidate] = []
        // 12-hour: 3pm, 8 pm, 3:30 p.m.
        for match in QuickAddPattern(#"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?(?![a-z])"#).matches(in: text) {
            guard let hour12 = Int(match.group(1) ?? ""), (1...12).contains(hour12),
                  let minute = parsedMinutes(match.group(2)), let meridiem = match.group(3)?.lowercased()
            else { continue }
            let hour = hour12 % 12 + (meridiem == "p" ? 12 : 0)
            found.append(certain(hour, minute, match.range))
        }
        // 24-hour colon form, with or without "at": 14:00, at 9:30. A 12-hour form ("3:30pm") does not
        // match here because no word boundary follows "30".
        for match in QuickAddPattern(#"\b(?:at\s+)?(\d{1,2}):(\d{2})\b"#).matches(in: text) {
            guard let hour = Int(match.group(1) ?? ""), (0...23).contains(hour),
                  let minute = parsedMinutes(match.group(2))
            else { continue }
            found.append(certain(hour, minute, match.range))
        }
        // "at 1": a bare hour after "at". Not when a colon or slash follows (the forms above and the dates own those).
        for match in QuickAddPattern(#"\bat\s+(\d{1,2})\b(?![:/])"#).matches(in: text) {
            guard let hour = Int(match.group(1) ?? ""), (0...23).contains(hour) else { continue }
            found.append(certain(hour, 0, match.range))
        }
        return found
    }

    private static func certain(_ hour: Int, _ minute: Int, _ range: Range<String.Index>) -> QuickAddCandidate {
        QuickAddCandidate(range: range, date: nil, time: LocalTime(hour: hour, minute: minute), hourIsCertain: true)
    }

    /// Missing minutes are zero; present minutes must be 00 to 59.
    private static func parsedMinutes(_ text: String?) -> Int? {
        guard let text else { return 0 }
        guard let value = Int(text), (0...59).contains(value) else { return nil }
        return value
    }
}
