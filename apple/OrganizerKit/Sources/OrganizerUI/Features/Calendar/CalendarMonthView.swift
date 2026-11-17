import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The month view: a grid of six Monday-first weeks, a colored dot per source on each day. Tapping a
/// day opens it in the day view.
struct CalendarMonthView: View {
    /// Any day in the month shown.
    let month: LocalDate
    let entries: [CalendarEntry]
    let today: LocalDate
    let onPickDay: (LocalDate) -> Void


    var body: some View {
        let window = CalendarWindow.month(containing: month)
        let summaries = CalendarSummaries.byDay(entries, in: window)
        let cellHeight: CGFloat = 84
        ScrollView {
            VStack(spacing: 6) {
                weekdayHeader
                ForEach(0..<6, id: \.self) { week in
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { column in
                            let day = window.start.adding(days: week * 7 + column, calendar: CalendarMath.calendar)
                            dayCell(day, inMonth: day.month == month.month, summary: summaries[day], height: cellHeight)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("calendar.month")
    }

    private var weekdayHeader: some View {
        let symbols = CalendarMath.calendar.shortWeekdaySymbols
        // Calendar's symbols start on Sunday; the grid starts on Monday.
        let ordered = Array(symbols.dropFirst()) + [symbols[0]]
        return HStack(spacing: 6) {
            ForEach(ordered, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: LocalDate, inMonth: Bool, summary: DaySummary?, height: CGFloat) -> some View {
        let isToday = day == today
        let count = summary?.count ?? 0
        let label = count == 0
            ? CalendarLabels.shortDay(day)
            : "\(CalendarLabels.shortDay(day)), \(count) item\(count == 1 ? "" : "s"): \((summary?.titles ?? []).joined(separator: ", "))"
        return Button {
            onPickDay(day)
        } label: {
            VStack(spacing: 4) {
                Text("\(day.day)")
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isToday ? Palette.primary : Color.clear))
                HStack(spacing: 3) {
                    ForEach((summary?.dots ?? []).prefix(3)) { dot in
                        Circle()
                            .fill(dot.color)
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
            .padding(.top, 3)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6), lineWidth: 0.5))
            .opacity(inMonth ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("calendar.day.\(day.string)")
    }
}

/// The year view: twelve mini months, each day tinted by how busy it is and dotted by source. Tapping
/// a day opens it; tapping a month's name opens the month.
struct CalendarYearView: View {
    let year: Int
    let entries: [CalendarEntry]
    let today: LocalDate
    let onPickDay: (LocalDate) -> Void
    let onPickMonth: (LocalDate) -> Void

    var body: some View {
        let summaries = CalendarSummaries.byDay(entries, in: CalendarWindow.year(year))
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 22)], alignment: .leading, spacing: 22) {
                ForEach(1...12, id: \.self) { month in
                    miniMonth(LocalDate(year: year, month: month, day: 1), summaries: summaries)
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("calendar.year")
    }

    private func miniMonth(_ first: LocalDate, summaries: [LocalDate: DaySummary]) -> some View {
        let window = CalendarWindow.month(containing: first)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                onPickMonth(first)
            } label: {
                Text(first.date(in: CalendarMath.calendar).formatted(.dateTime.month(.wide)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            VStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { week in
                    HStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { column in
                            let day = window.start.adding(days: week * 7 + column, calendar: CalendarMath.calendar)
                            tile(day, inMonth: day.month == first.month, summary: summaries[day])
                        }
                    }
                }
            }
        }
    }

    private func tile(_ day: LocalDate, inMonth: Bool, summary: DaySummary?) -> some View {
        let level = CalendarSummaries.densityLevel(summary?.count ?? 0)
        let percent = [0, 7, 13, 20, 28][level]
        let isToday = day == today
        return Button {
            onPickDay(day)
        } label: {
            VStack(spacing: 1) {
                Text("\(day.day)")
                    .font(.system(size: 9.5, weight: isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Palette.primary : Color.primary)
                HStack(spacing: 1.5) {
                    ForEach((summary?.dots ?? []).prefix(3)) { dot in
                        Circle()
                            .fill(dot.color)
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Palette.primary.opacity(Double(percent) / 100))
            )
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 4).stroke(Palette.primary, lineWidth: 1)
                }
            }
            .opacity(inMonth ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CalendarLabels.shortDay(day))
    }
}
