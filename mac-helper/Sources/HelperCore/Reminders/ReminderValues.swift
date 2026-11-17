import Foundation

/// A field the sync compares and writes. `due` is due_date and due_time together.
public enum ReminderField: String, Codable, CaseIterable, Sendable, Comparable {
    case title, notes, due, priority, completed, list

    public static func < (a: ReminderField, b: ReminderField) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// A reminder's user-facing fields in the organizer's comparable form: notes "" when none,
/// due_date `YYYY-MM-DD`, due_time `HH:MM` (local wall clock, minute precision), priority on the
/// organizer's 1 (high) / 2 (medium) / 3 (low) scale. Both directions of the sync compare these,
/// never raw EventKit values, so a round trip through Reminders reads back equal.
public struct ReminderValues: Codable, Equatable, Sendable {
    public var title: String
    public var notes: String
    @NullCodable public var due_date: String?
    @NullCodable public var due_time: String?
    @NullCodable public var priority: Int?
    public var completed: Bool

    public init(title: String, notes: String = "", due_date: String? = nil, due_time: String? = nil,
                priority: Int? = nil, completed: Bool = false) {
        self.title = title; self.notes = notes; self.due_date = due_date
        self.due_time = due_date == nil ? nil : due_time.map(ReminderMapping.minuteTime)
        self.priority = priority; self.completed = completed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        due_date = try c.decodeIfPresent(String.self, forKey: .due_date)
        due_time = try c.decodeIfPresent(String.self, forKey: .due_time).map(ReminderMapping.minuteTime)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        if due_date == nil { due_time = nil }
    }

    /// Whether two value sets agree on one field (`list` is not a value field: always equal).
    public func same(_ field: ReminderField, as other: ReminderValues) -> Bool {
        switch field {
        case .title: return title == other.title
        case .notes: return notes == other.notes
        case .due: return due_date == other.due_date && due_time == other.due_time
        case .priority: return priority == other.priority
        case .completed: return completed == other.completed
        case .list: return true
        }
    }

    /// `self` with one field taken from `other`.
    public func with(_ field: ReminderField, from other: ReminderValues) -> ReminderValues {
        var v = self
        switch field {
        case .title: v.title = other.title
        case .notes: v.notes = other.notes
        case .due: v.due_date = other.due_date; v.due_time = other.due_time
        case .priority: v.priority = other.priority
        case .completed: v.completed = other.completed
        case .list: break
        }
        return v
    }

    /// A field's value as text, for conflict reports.
    public func display(_ field: ReminderField) -> String? {
        switch field {
        case .title: return title
        case .notes: return notes
        case .due: return due_date.map { d in due_time.map { "\(d) \($0)" } ?? d }
        case .priority: return priority.map(String.init)
        case .completed: return String(completed)
        case .list: return nil
        }
    }
}

/// EventKit <-> organizer conversions.
public enum ReminderMapping {
    /// EventKit priority (0 none, 1-4 high, 5 medium, 6-9 low) -> 1 / 2 / 3 / nil.
    public static func organizerPriority(_ ek: Int) -> Int? {
        switch ek {
        case 1...4: return 1
        case 5: return 2
        case 6...9: return 3
        default: return nil
        }
    }

    /// 1 / 2 / 3 / nil -> the values Reminders.app itself uses (1, 5, 9, 0).
    public static func eventKitPriority(_ organizer: Int?) -> Int {
        switch organizer {
        case 1: return 1
        case 2: return 5
        case 3: return 9
        default: return 0
        }
    }

    /// `HH:MM` from `HH:MM` or `HH:MM:SS`.
    public static func minuteTime(_ s: String) -> String {
        let parts = s.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return s }
        return String(format: "%02d:%02d", h, m)
    }

    /// A reminder's due date components as (YYYY-MM-DD, HH:MM?) on the local wall clock. A timed
    /// due date pinned to another zone is converted to `zone`; a floating one is read as is.
    public static func due(from comps: DateComponents?, zone: TimeZone = .current) -> (date: String?, time: String?) {
        guard let comps, let y = comps.year, let mo = comps.month, let d = comps.day else { return (nil, nil) }
        guard let hour = comps.hour else { return (String(format: "%04d-%02d-%02d", y, mo, d), nil) }
        let minute = comps.minute ?? 0
        if let tz = comps.timeZone, tz.secondsFromGMT() != zone.secondsFromGMT() || tz.identifier != zone.identifier {
            var source = Calendar(identifier: .gregorian)
            source.timeZone = tz
            var plain = DateComponents(year: y, month: mo, day: d, hour: hour, minute: minute)
            plain.timeZone = tz
            if let instant = source.date(from: plain) {
                var local = Calendar(identifier: .gregorian)
                local.timeZone = zone
                let l = local.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
                return (String(format: "%04d-%02d-%02d", l.year!, l.month!, l.day!), String(format: "%02d:%02d", l.hour!, l.minute!))
            }
        }
        return (String(format: "%04d-%02d-%02d", y, mo, d), String(format: "%02d:%02d", hour, minute))
    }

    /// Due date components to write: a date alone is an all-day (floating) due date; with a time
    /// it is pinned to `zone`, as Reminders.app does.
    public static func components(date: String?, time: String?, zone: TimeZone = .current) -> DateComponents? {
        guard let date else { return nil }
        let d = date.split(separator: "-").compactMap { Int($0) }
        guard d.count == 3 else { return nil }
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.year = d[0]; comps.month = d[1]; comps.day = d[2]
        if let time {
            let t = minuteTime(time).split(separator: ":").compactMap { Int($0) }
            guard t.count == 2 else { return comps }
            comps.hour = t[0]; comps.minute = t[1]
            comps.timeZone = zone
            comps.calendar?.timeZone = zone
        }
        return comps
    }

    /// The instant of a timed due date (nil for all-day or none), for the due-time alarm.
    public static func instant(of comps: DateComponents?, zone: TimeZone = .current) -> Date? {
        guard let comps, comps.hour != nil else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = comps.timeZone ?? zone
        var plain = DateComponents(year: comps.year, month: comps.month, day: comps.day, hour: comps.hour, minute: comps.minute ?? 0)
        plain.timeZone = cal.timeZone
        return cal.date(from: plain)
    }
}
