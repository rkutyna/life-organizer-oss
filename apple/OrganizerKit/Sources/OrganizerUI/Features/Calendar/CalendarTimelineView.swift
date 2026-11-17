import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The day and week views: an all-day strip, then an hour timeline where each timed item sits at its
/// start, overlapping items side by side. One column for a day, seven for a week; on a phone the week
/// scrolls sideways, opening on today, while the hour gutter stays pinned at the left edge.
struct CalendarTimelineView: View {
    let days: [LocalDate]
    let entries: [CalendarEntry]
    let today: LocalDate
    let onOpen: (CalendarEntry) -> Void
    /// Tapping a day's heading opens that day (the week view). Nil where there is only one day.
    let onPickDay: ((LocalDate) -> Void)?

    /// Sideways (the week's columns, on a phone) and down (the hours). The headings stay put while
    /// the hours scroll, because only the timeline scrolls down.
    @State private var across = ScrollPosition()
    @State private var down = ScrollPosition()
    /// How far the columns have scrolled sideways: the gutter moves back by as much, so it stays
    /// at the left edge. Only the pinned gutter reads it, so scrolling redraws the gutter alone.
    @State private var scrolledAcross = CalendarTimelineAcross()

    private static let hourHeight: CGFloat = 56
    /// Space above midnight's line, and above the first hour's line when the view opens.
    private static let timelineTop: CGFloat = 10
    private static let gutter: CGFloat = 46
    private static let headerHeight: CGFloat = 50
    private static let minimumColumn: CGFloat = 104
    private static let chipHeight: CGFloat = 20
    private static let maxChips = 3

    private var calendar: Calendar { CalendarMath.calendar }

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = max(Self.minimumColumn, (proxy.size.width - Self.gutter) / CGFloat(max(days.count, 1)))
            let bottomBar = proxy.safeAreaInsets.bottom
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    header(columnWidth: columnWidth)
                    allDayStrip(columnWidth: columnWidth)
                    ScrollView(.vertical) {
                        // Room for the first hour's label, which sits half above its line.
                        timeline(columnWidth: columnWidth)
                            .padding(.top, Self.timelineTop)
                    }
                    .contentMargins(.bottom, bottomBar, for: .scrollContent)
                    .scrollPosition($down)
                }
                .frame(width: Self.gutter + columnWidth * CGFloat(days.count), alignment: .topLeading)
                .frame(height: proxy.size.height + bottomBar, alignment: .top)
                .padding(.top, proxy.safeAreaInsets.top)
            }
            // The margins are laid out by hand. Left to itself this scroll view can take the safe area
            // as content insets on top of sitting inside it when it is re-created by a switch from
            // another view, opening the whole timeline that far too low (11/01: Month or Day, then
            // Week: top inset 191, offset -191, on a frame that had not moved).
            .ignoresSafeArea(.container, edges: .vertical)
            .scrollPosition($across)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.x + geometry.contentInsets.leading)
            } action: { _, x in
                scrolledAcross.x = x
            }
            .onAppear { open(columnWidth: columnWidth, viewport: proxy.size.width) }
            // Another week or day opens the way this one did, not on the columns left behind.
            .onChange(of: days) { open(columnWidth: columnWidth, viewport: proxy.size.width) }
        }
        .accessibilityIdentifier("calendar.timeline")
    }

    // MARK: Geometry

    /// The top of the hour rows the view opens on: 7 AM, or an earlier item.
    private var firstHour: Int {
        let earliest = days.flatMap { day in
            DayTimeline.blocks(entries, on: day, calendar: calendar).map { Int($0.startMinute) / 60 }
        }.min() ?? 7
        return max(0, min(7, earliest - 1))
    }

    private var allDayCount: Int {
        days.map { DayTimeline.allDay(entries, on: $0).count }.max() ?? 0
    }

    private var allDayHeight: CGFloat {
        guard allDayCount > 0 else { return 0 }
        let rows = min(allDayCount, Self.maxChips) + (allDayCount > Self.maxChips ? 1 : 0)
        return CGFloat(rows) * (Self.chipHeight + 3) + 10
    }

    private func open(columnWidth: CGFloat, viewport: CGFloat) {
        let start = initialOffset(columnWidth: columnWidth, viewport: viewport)
        across.scrollTo(x: start.x)
        down.scrollTo(y: start.y)
    }

    /// Opens at the first hour, and on a week at today's column when it is in the week.
    private func initialOffset(columnWidth: CGFloat, viewport: CGFloat) -> CGPoint {
        let y = CGFloat(firstHour) * Self.hourHeight
        var x: CGFloat = 0
        if days.count > 1, let index = days.firstIndex(of: today) {
            x = max(0, Self.gutter + CGFloat(index) * columnWidth - 16)
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: Header

    private func header(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter)
            ForEach(days, id: \.self) { day in
                dayHeading(day)
                    .frame(width: columnWidth, height: Self.headerHeight)
            }
        }
        .frame(height: Self.headerHeight)
        .overlay(alignment: .leading) {
            CalendarPinnedGutter(across: scrolledAcross) {
                Color.clear.frame(width: Self.gutter)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func dayHeading(_ day: LocalDate) -> some View {
        let isToday = day == today
        let number = Text("\(day.day)")
            .font(.headline)
            .monospacedDigit()
            .foregroundStyle(isToday ? Color.white : Color.primary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(isToday ? Palette.primary : Color.clear))
        let weekday = Text(weekdayName(day))
            .font(.caption2)
            .foregroundStyle(.secondary)
        if let onPickDay {
            Button {
                onPickDay(day)
            } label: {
                VStack(spacing: 1) {
                    weekday
                    number
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CalendarLabels.shortDay(day))
            .accessibilityHint("Opens this day")
        } else {
            VStack(spacing: 1) {
                weekday
                number
            }
        }
    }

    private func weekdayName(_ day: LocalDate) -> String {
        day.date(in: calendar).formatted(.dateTime.weekday(.abbreviated))
    }

    // MARK: All day

    @ViewBuilder
    private func allDayStrip(columnWidth: CGFloat) -> some View {
        if allDayCount > 0 {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: Self.gutter)
                ForEach(days, id: \.self) { day in
                    let items = DayTimeline.allDay(entries, on: day)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(items.prefix(Self.maxChips)) { entry in
                            chip(entry)
                        }
                        if items.count > Self.maxChips {
                            Text("+\(items.count - Self.maxChips) more")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(height: Self.chipHeight)
                        }
                    }
                    .padding(.horizontal, 3)
                    .frame(width: columnWidth, alignment: .topLeading)
                }
            }
            .padding(.vertical, 5)
            .frame(height: allDayHeight)
            .overlay(alignment: .topLeading) {
                CalendarPinnedGutter(across: scrolledAcross) {
                    Text("all day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.gutter - 6, alignment: .trailing)
                        .padding(.top, 9)
                        .frame(width: Self.gutter, height: allDayHeight, alignment: .topLeading)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 0.5)
            }
        }
    }

    private func chip(_ entry: CalendarEntry) -> some View {
        let color = Palette.item(source: entry.item.source, color: entry.item.color)
        return Button {
            onOpen(entry)
        } label: {
            Text(entry.item.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.leading, 7)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.chipHeight)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.22)))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Timeline

    private func timeline(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    hourRow(hour)
                        .frame(height: Self.hourHeight)
                        .id("hour-\(hour)")
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gutter)
                ForEach(days, id: \.self) { day in
                    column(day, width: columnWidth)
                        .frame(width: columnWidth, height: Self.hourHeight * 24, alignment: .topLeading)
                }
            }
        }
        .frame(height: Self.hourHeight * 24)
        // Above the columns, so the items scroll beneath the hours.
        .overlay(alignment: .topLeading) {
            CalendarPinnedGutter(across: scrolledAcross) { hourGutter }
        }
    }

    /// An hour's line, from the gutter's edge across the columns.
    private func hourRow(_ hour: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: Self.gutter - 6)
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)
        }
    }

    /// The hour labels, each with the start of its line, on the background: the pinned gutter.
    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(hourLabel(hour))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: Self.gutter - 6, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 6, height: 0.5)
                }
                .frame(height: Self.hourHeight, alignment: .top)
            }
        }
        .frame(width: Self.gutter)
    }

    /// "9 AM", in the device's locale.
    private func hourLabel(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today.date(in: calendar)) ?? today.date(in: calendar)
        return date.formatted(.dateTime.hour())
    }

    private func column(_ day: LocalDate, width: CGFloat) -> some View {
        let blocks = DayTimeline.blocks(entries, on: day, calendar: calendar)
        return ZStack(alignment: .topLeading) {
            ForEach(blocks) { block in
                blockView(block, width: width)
            }
            if day == today {
                nowLine(width: width)
            }
        }
    }

    private func blockView(_ block: TimelineBlock, width: CGFloat) -> some View {
        let color = Palette.item(source: block.entry.item.source, color: block.entry.item.color)
        let slot = (width - 6) / CGFloat(block.columns)
        let top = CGFloat(block.startMinute) / 60 * Self.hourHeight
        let height = max(20, CGFloat(block.endMinute - block.startMinute) / 60 * Self.hourHeight - 2)
        let isDone = block.entry.item.status == "done"
        return Button {
            onOpen(block.entry)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(block.entry.item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(height > 40 ? 3 : 1)
                if height > 40, let start = block.entry.start {
                    Text(CalendarLabels.time(start))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.leading, 7)
            .padding(.trailing, 4)
            .padding(.vertical, 3)
            .frame(width: slot - 2, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.22)))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isDone ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .offset(x: 3 + CGFloat(block.column) * slot, y: top + 1)
        .accessibilityLabel(block.entry.item.title)
    }

    /// The current time, on today's column.
    private func nowLine(width: CGFloat) -> some View {
        TimelineView(.everyMinute) { context in
            let minute = CGFloat(DayTimeline.minute(of: context.date, calendar: calendar))
            HStack(spacing: 0) {
                Circle()
                    .fill(Palette.status(.overdue))
                    .frame(width: 7, height: 7)
                Rectangle()
                    .fill(Palette.status(.overdue))
                    .frame(height: 1.5)
            }
            .frame(width: width)
            .offset(x: -3.5, y: minute / 60 * Self.hourHeight - 3.5)
            .allowsHitTesting(false)
        }
    }
}

/// How far the timeline's columns have scrolled sideways (see `CalendarPinnedGutter`).
@Observable
final class CalendarTimelineAcross {
    var x: CGFloat = 0
}

/// A part of the timeline's left gutter, kept at the visible left edge while the columns scroll
/// sideways beneath it, on the screen's background so they do not show through.
private struct CalendarPinnedGutter<Content: View>: View {
    let across: CalendarTimelineAcross
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(.background)
            .offset(x: across.x)
    }
}
