import Foundation
import OrganizerAPI
import OrganizerCore
import SwiftUI

// The Jobs screen's pure parts: sections, routes, where a deep link points, labels and colors,
// and the edit drafts (what a sheet holds, the PATCH it sends, the record it shows meanwhile).
// No views and no state, so the tests run them directly.

// MARK: - Sections and routes

/// The screen's sections, in the web's tab order (Companies, Import and Settings stay on the web).
nonisolated enum JobsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pipeline, applications, leads, contacts, interviews, events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pipeline: "Pipeline"
        case .applications: "Applications"
        case .leads: "Leads"
        case .contacts: "Contacts"
        case .interviews: "Interviews"
        case .events: "Events"
        }
    }

    var systemImage: String {
        switch self {
        case .pipeline: "chart.bar.xaxis"
        case .applications: "tray.full"
        case .leads: "lightbulb"
        case .contacts: "person.2"
        case .interviews: "person.wave.2"
        case .events: "calendar.badge.clock"
        }
    }

    /// The web app's page, for "Open in Web".
    var webPath: String {
        self == .pipeline ? "/jobs" : "/jobs/\(rawValue)"
    }
}

/// A record pushed onto the Jobs stack, from any section.
nonisolated enum JobsRoute: Hashable, Sendable {
    case application(Int)
    case contact(Int)
    case interview(Int)
    case event(Int)

    /// The web page of the record ("Open in Web").
    var webPath: String {
        switch self {
        case .application(let id): "/jobs/applications/\(id)"
        case .contact(let id): "/jobs/contacts/\(id)"
        case .interview: "/jobs/interviews"
        case .event(let id): "/jobs/events?event=\(id)"
        }
    }
}

/// Where a link into Jobs points: a section, maybe a record, maybe a status filter.
nonisolated struct JobsLocation: Equatable, Sendable {
    var section: JobsSection
    var route: JobsRoute?
    /// `?status=` on the applications list.
    var status: String?

    init(section: JobsSection, route: JobsRoute? = nil, status: String? = nil) {
        self.section = section
        self.route = route
        self.status = status
    }

    /// Reads `lifeorganizer://jobs/<path>?<query>`, the web's paths under `/jobs` (the calendar's
    /// `detail_url`s): `jobs` (the pipeline), `jobs/applications/12`, `jobs/applications?status=screen`,
    /// `jobs/leads`, `jobs/contacts/3`, `jobs/interviews/2`, `jobs/events?event=4`. Nil for a
    /// page this screen does not have (companies, import, settings) or an id that is not a number.
    init?(path: [String], query: [String: String] = [:]) {
        guard let first = path.first else {
            self.init(section: .pipeline)
            return
        }
        let rawID = path.count > 1 ? path[1] : nil
        if let rawID, Int(rawID) == nil { return nil }
        let id = rawID.flatMap { Int($0) }
        switch first {
        case "pipeline", "overview":
            self.init(section: .pipeline)
        case "applications":
            let status = query["status"].flatMap { $0.isEmpty ? nil : $0 }
            self.init(section: .applications, route: id.map(JobsRoute.application), status: id == nil ? status : nil)
        case "leads":
            self.init(section: .leads, route: id.map(JobsRoute.application))
        case "contacts":
            self.init(section: .contacts, route: id.map(JobsRoute.contact))
        case "interviews":
            self.init(section: .interviews, route: id.map(JobsRoute.interview))
        case "events":
            let event = id ?? query["event"].flatMap { Int($0) }
            self.init(section: .events, route: event.map(JobsRoute.event))
        default:
            return nil
        }
    }

    init?(_ link: DeepLink) {
        self.init(path: link.path, query: link.query)
    }
}

// MARK: - Labels and colors

nonisolated enum JobsFormat {
    static var calendar: Calendar { .current }

    /// "Today", "Tomorrow", "Oct 24" (the year when not this year); "" for none.
    static func day(_ day: LocalDate?, now: Date = Date()) -> String {
        guard let day else { return "" }
        return DayLabels.day(day, now: now, calendar: calendar)
    }

    /// "Tue, Nov 18", with the year when it is not this year.
    static func longDay(_ day: LocalDate, now: Date = Date()) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if day.year != LocalDate.today(calendar: calendar, now: now).year { style = style.year() }
        style.timeZone = calendar.timeZone
        return day.date(in: calendar).formatted(style)
    }

    static func time(_ time: LocalTime) -> String {
        DayLabels.time(time, calendar: calendar)
    }

    /// "Tue, Nov 18 · 2:00 PM · 90 min", or "Not scheduled".
    static func interviewWhen(_ interview: InterviewOut, now: Date = Date()) -> String {
        guard let day = interview.onDate else { return "Not scheduled" }
        var parts = [longDay(day, now: now)]
        if let start = interview.startTime { parts.append(time(start)) }
        if let minutes = interview.durationMinutes { parts.append("\(minutes) min") }
        return parts.joined(separator: " · ")
    }

    /// "5:00 PM – 7:30 PM", "5:00 PM", or "" for an event with no time.
    static func eventTimes(_ event: JobEventOut) -> String {
        guard let start = event.startTime else { return "" }
        guard let end = event.endTime else { return time(start) }
        return "\(time(start)) – \(time(end))"
    }

    /// "Tue, Nov 19 · 5:00 PM – 7:30 PM".
    static func eventWhen(_ event: JobEventOut, now: Date = Date()) -> String {
        let times = eventTimes(event)
        return times.isEmpty ? longDay(event.onDate, now: now) : "\(longDay(event.onDate, now: now)) · \(times)"
    }

    /// A next action with its due day: "Follow up · Tomorrow". "" when there is neither.
    static func nextAction(_ action: String, due: LocalDate?, now: Date = Date()) -> String {
        let dueText = day(due, now: now)
        switch (action.isEmpty, dueText.isEmpty) {
        case (true, true): return ""
        case (false, true): return action
        case (true, false): return "Due \(dueText)"
        case (false, false): return "\(action) · \(dueText)"
        }
    }

    /// Whether a due day has passed, is today, or is ahead (nil: no due day).
    enum Due: Sendable { case overdue, today, later }

    static func due(_ day: LocalDate?, today: LocalDate = LocalDate.today()) -> Due? {
        guard let day else { return nil }
        if day < today { return .overdue }
        return day == today ? .today : .later
    }

    /// An event's attendance: "Went", "Missed", "" when not recorded.
    static func attended(_ attended: Bool?) -> String {
        switch attended {
        case true?: "Went"
        case false?: "Missed"
        case nil: ""
        }
    }

    /// "a, b" for tags.
    static func tags(_ tags: [String]) -> String { tags.joined(separator: ", ") }

    /// "a, b ,, c" -> ["a", "b", "c"].
    static func splitTags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A web link the person typed or the server holds, if it is one.
    static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://"),
              let url = URL(string: trimmed), url.host() != nil else { return nil }
        return url
    }
}

/// Status colors by kind, as the web's `kindTone`: a lead is "today" blue, an active stage
/// "ok" green, a closed one muted, a dropped lead faded.
nonisolated enum JobsTone {
    static func kind(_ kind: JobStatusOut.Kind?) -> Color {
        switch kind {
        case .lead?: Palette.status(.today)
        case .active?: Palette.status(.ok)
        case .closed?: Palette.status(.open)
        case .dropped?: Palette.status(.done)
        default: Palette.status(.open)
        }
    }

    static func kind(raw: String) -> Color {
        kind(JobStatusOut.Kind(rawValue: raw))
    }

    static func due(_ due: JobsFormat.Due?) -> Color {
        switch due {
        case .overdue?: Palette.status(.overdue)
        case .today?: Palette.status(.today)
        default: Color.secondary
        }
    }
}

// MARK: - Drafts

private extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The main fields of an application, as the edit sheet holds them. The status is not here: it
/// changes through a status change, Apply or Drop.
nonisolated struct JobsApplicationDraft: Equatable, Sendable {
    var title = ""
    var companyID: Int?
    /// For a new application: the company by name (a new name creates it).
    var companyName = ""
    var dateApplied: LocalDate?
    var location = ""
    var postingURL = ""
    var source = ""
    var nextAction = ""
    var nextActionDue: LocalDate?
    var notes = ""
    var tags = ""
    /// For a new application: its first status (nil: the server's default, applied).
    var status: String?

    init() {}

    init(_ application: ApplicationOut) {
        title = application.title
        companyID = application.companyId
        companyName = application.company
        dateApplied = application.dateApplied
        location = application.location
        postingURL = application.postingUrl
        source = application.source
        nextAction = application.nextAction
        nextActionDue = application.nextActionDue
        notes = application.notes
        tags = JobsFormat.tags(application.tags)
    }

    var canSaveEdit: Bool { !title.trimmed.isEmpty && companyID != nil }
    var canCreate: Bool { !title.trimmed.isEmpty && (companyID != nil || !companyName.trimmed.isEmpty) }

    /// Only what changed. (The sheet keeps a lead's date applied empty: Apply sets it.)
    func update(from original: ApplicationOut) -> ApplicationUpdate {
        var update = ApplicationUpdate()
        if title.trimmed != original.title { update.title = .value(title.trimmed) }
        if let companyID, companyID != original.companyId { update.companyId = .value(companyID) }
        if dateApplied != original.dateApplied { update.dateApplied = .orNull(dateApplied) }
        if location.trimmed != original.location { update.location = .value(location.trimmed) }
        if postingURL.trimmed != original.postingUrl { update.postingUrl = .value(postingURL.trimmed) }
        if source.trimmed != original.source { update.source = .value(source.trimmed) }
        if nextAction.trimmed != original.nextAction { update.nextAction = .value(nextAction.trimmed) }
        if nextActionDue != original.nextActionDue { update.nextActionDue = .orNull(nextActionDue) }
        if notes != original.notes { update.notes = .value(notes) }
        let tagList = JobsFormat.splitTags(tags)
        if tagList != original.tags { update.tags = .value(tagList) }
        return update
    }

    /// The record as it will read once saved, shown while the request runs.
    func applied(to original: ApplicationOut, companyName: String?) -> ApplicationOut {
        var copy = original
        copy.title = title.trimmed
        if let companyID, companyID != original.companyId {
            copy.companyId = companyID
            copy.company = companyName ?? original.company
        }
        copy.dateApplied = dateApplied
        copy.location = location.trimmed
        copy.postingUrl = postingURL.trimmed
        copy.source = source.trimmed
        copy.nextAction = nextAction.trimmed
        copy.nextActionDue = nextActionDue
        copy.notes = notes
        copy.tags = JobsFormat.splitTags(tags)
        return copy
    }

    /// The create body: the company by id when picked, else by name.
    func create() -> ApplicationCreate {
        ApplicationCreate(
            title: title.trimmed,
            companyId: .ifPresent(companyID),
            company: companyID == nil ? .value(companyName.trimmed) : .omitted,
            location: location.trimmed.isEmpty ? nil : location.trimmed,
            postingUrl: postingURL.trimmed.isEmpty ? nil : postingURL.trimmed,
            source: source.trimmed.isEmpty ? nil : source.trimmed,
            nextAction: nextAction.trimmed.isEmpty ? nil : nextAction.trimmed,
            nextActionDue: .ifPresent(nextActionDue),
            notes: notes.trimmed.isEmpty ? nil : notes,
            tags: JobsFormat.splitTags(tags).isEmpty ? nil : JobsFormat.splitTags(tags),
            status: .ifPresent(status),
            dateApplied: .ifPresent(dateApplied)
        )
    }
}

/// A contact's fields, as the edit and add sheets hold them.
nonisolated struct JobsContactDraft: Equatable, Sendable {
    var name = ""
    var companyID: Int?
    /// For a new contact: the company by name (optional; a new name creates it).
    var companyName = ""
    var role = ""
    var email = ""
    var profileURL = ""
    var contactedOn: LocalDate?
    var repliedOn: LocalDate?
    var nextAction = ""
    var nextActionDue: LocalDate?
    var notes = ""
    var tags = ""

    init() {}

    init(_ contact: ContactOut) {
        name = contact.name
        companyID = contact.companyId
        companyName = contact.company ?? ""
        role = contact.role
        email = contact.email
        profileURL = contact.profileUrl
        contactedOn = contact.contactedOn
        repliedOn = contact.repliedOn
        nextAction = contact.nextAction
        nextActionDue = contact.nextActionDue
        notes = contact.notes
        tags = JobsFormat.tags(contact.tags)
    }

    var canSave: Bool { !name.trimmed.isEmpty }

    func update(from original: ContactOut) -> ContactUpdate {
        var update = ContactUpdate()
        if name.trimmed != original.name { update.name = .value(name.trimmed) }
        if companyID != original.companyId { update.companyId = .orNull(companyID) }
        if role.trimmed != original.role { update.role = .value(role.trimmed) }
        if email.trimmed != original.email { update.email = .value(email.trimmed) }
        if profileURL.trimmed != original.profileUrl { update.profileUrl = .value(profileURL.trimmed) }
        if contactedOn != original.contactedOn { update.contactedOn = .orNull(contactedOn) }
        if repliedOn != original.repliedOn { update.repliedOn = .orNull(repliedOn) }
        if nextAction.trimmed != original.nextAction { update.nextAction = .value(nextAction.trimmed) }
        if nextActionDue != original.nextActionDue { update.nextActionDue = .orNull(nextActionDue) }
        if notes != original.notes { update.notes = .value(notes) }
        let tagList = JobsFormat.splitTags(tags)
        if tagList != original.tags { update.tags = .value(tagList) }
        return update
    }

    func applied(to original: ContactOut, companyName: String?) -> ContactOut {
        var copy = original
        copy.name = name.trimmed
        if companyID != original.companyId {
            copy.companyId = companyID
            copy.company = companyID == nil ? nil : (companyName ?? original.company)
        }
        copy.role = role.trimmed
        copy.email = email.trimmed
        copy.profileUrl = profileURL.trimmed
        copy.contactedOn = contactedOn
        copy.repliedOn = repliedOn
        copy.nextAction = nextAction.trimmed
        copy.nextActionDue = nextActionDue
        copy.notes = notes
        copy.tags = JobsFormat.splitTags(tags)
        return copy
    }

    func create() -> ContactCreate {
        let company = companyName.trimmed
        return ContactCreate(
            name: name.trimmed,
            companyId: .ifPresent(companyID),
            company: companyID == nil && !company.isEmpty ? .value(company) : .omitted,
            role: role.trimmed.isEmpty ? nil : role.trimmed,
            email: email.trimmed.isEmpty ? nil : email.trimmed,
            profileUrl: profileURL.trimmed.isEmpty ? nil : profileURL.trimmed,
            contactedOn: .ifPresent(contactedOn),
            repliedOn: .ifPresent(repliedOn),
            nextAction: nextAction.trimmed.isEmpty ? nil : nextAction.trimmed,
            nextActionDue: .ifPresent(nextActionDue),
            notes: notes.trimmed.isEmpty ? nil : notes,
            tags: JobsFormat.splitTags(tags).isEmpty ? nil : JobsFormat.splitTags(tags)
        )
    }
}

/// An interview's fields. A start time needs a day, so clearing the day clears the time.
nonisolated struct JobsInterviewDraft: Equatable, Sendable {
    var stage = ""
    var onDate: LocalDate?
    var startTime: LocalTime?
    var durationMinutes: Int?
    var location = ""
    var interviewer = ""
    var notes = ""

    init(_ interview: InterviewOut) {
        stage = interview.stage
        onDate = interview.onDate
        startTime = interview.startTime
        durationMinutes = interview.durationMinutes
        location = interview.location
        interviewer = interview.interviewer
        notes = interview.notes
    }

    /// The server takes 5 minutes to a day.
    var canSave: Bool {
        guard let durationMinutes else { return true }
        return (5...1440).contains(durationMinutes)
    }

    private var time: LocalTime? { onDate == nil ? nil : startTime }

    func update(from original: InterviewOut) -> InterviewUpdate {
        var update = InterviewUpdate()
        if stage.trimmed != original.stage { update.stage = .value(stage.trimmed) }
        if onDate != original.onDate { update.onDate = .orNull(onDate) }
        if time != original.startTime { update.startTime = .orNull(time) }
        if durationMinutes != original.durationMinutes { update.durationMinutes = .orNull(durationMinutes) }
        if location.trimmed != original.location { update.location = .value(location.trimmed) }
        if interviewer.trimmed != original.interviewer { update.interviewer = .value(interviewer.trimmed) }
        if notes != original.notes { update.notes = .value(notes) }
        return update
    }

    func applied(to original: InterviewOut) -> InterviewOut {
        var copy = original
        copy.stage = stage.trimmed
        copy.onDate = onDate
        copy.startTime = time
        copy.durationMinutes = durationMinutes
        copy.location = location.trimmed
        copy.interviewer = interviewer.trimmed
        copy.notes = notes
        return copy
    }
}

/// A job event's fields. An end time needs a start time.
nonisolated struct JobsEventDraft: Equatable, Sendable {
    var name = ""
    var kind = ""
    var onDate: LocalDate
    var startTime: LocalTime?
    var endTime: LocalTime?
    var location = ""
    var url = ""
    var attended: Bool?
    var notes = ""
    var tags = ""

    init(_ event: JobEventOut) {
        name = event.name
        kind = event.kind
        onDate = event.onDate
        startTime = event.startTime
        endTime = event.endTime
        location = event.location
        url = event.url
        attended = event.attended
        notes = event.notes
        tags = JobsFormat.tags(event.tags)
    }

    private var end: LocalTime? { startTime == nil ? nil : endTime }

    var canSave: Bool {
        guard !name.trimmed.isEmpty else { return false }
        if let startTime, let end { return end >= startTime }
        return true
    }

    func update(from original: JobEventOut) -> JobEventUpdate {
        var update = JobEventUpdate()
        if name.trimmed != original.name { update.name = .value(name.trimmed) }
        if kind.trimmed != original.kind { update.kind = .value(kind.trimmed) }
        if onDate != original.onDate { update.onDate = .value(onDate) }
        if startTime != original.startTime { update.startTime = .orNull(startTime) }
        if end != original.endTime { update.endTime = .orNull(end) }
        if location.trimmed != original.location { update.location = .value(location.trimmed) }
        if url.trimmed != original.url { update.url = .value(url.trimmed) }
        if attended != original.attended { update.attended = .orNull(attended) }
        if notes != original.notes { update.notes = .value(notes) }
        let tagList = JobsFormat.splitTags(tags)
        if tagList != original.tags { update.tags = .value(tagList) }
        return update
    }

    func applied(to original: JobEventOut) -> JobEventOut {
        var copy = original
        copy.name = name.trimmed
        copy.kind = kind.trimmed
        copy.onDate = onDate
        copy.startTime = startTime
        copy.endTime = end
        copy.location = location.trimmed
        copy.url = url.trimmed
        copy.attended = attended
        copy.notes = notes
        copy.tags = JobsFormat.splitTags(tags)
        return copy
    }
}
