import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The agenda, the default on iPhone: a scrolling list grouped by day. It opens on today, loads
/// more days as either end comes into view (or on Earlier / Later), and puts each day's all-day
/// items first.
struct CalendarAgendaView: View {
    let days: [AgendaDay]
    let today: LocalDate
    /// The day at the top of the list. The list scrolls to it, and it moves as the person scrolls.
    @Binding var top: String?
    let canExtendEarlier: Bool
    let canExtendLater: Bool
    let onExtend: (_ earlier: Bool) -> Void
    let onOpen: (CalendarEntry) -> Void
    /// Set once today's row has been shown. The edges load more days only after that, so opening the
    /// agenda (which starts on today, not at the top) does not load the past.
    @State private var settled = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    edge(earlier: true)
                    ForEach(days) { day in
                        dayView(day)
                            .id(day.id)
                            .onAppear {
                                if day.day == today { settled = true }
                            }
                    }
                    edge(earlier: false)
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $top, anchor: .top)
            .onAppear {
                proxy.scrollTo(today.string, anchor: .top)
            }
        }
        .accessibilityIdentifier("calendar.agenda")
    }

    private func dayView(_ day: AgendaDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            dayHeader(day.day)
            if day.entries.isEmpty {
                Text("Nothing scheduled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            ForEach(day.entries) { entry in
                row(entry)
                Divider()
                    .padding(.leading, 96)
            }
        }
    }

    /// Where more days are loaded: a row at either end that loads them as it appears, and a button.
    @ViewBuilder
    private func edge(earlier: Bool) -> some View {
        if earlier ? canExtendEarlier : canExtendLater {
            Button {
                onExtend(earlier)
            } label: {
                Label(earlier ? "Earlier days" : "Later days", systemImage: earlier ? "chevron.up" : "chevron.down")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .onAppear {
                if settled { onExtend(earlier) }
            }
        }
    }

    private func dayHeader(_ day: LocalDate) -> some View {
        let relative = DayLabels.day(day)
        let isRelative = ["Today", "Tomorrow", "Yesterday"].contains(relative)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(isRelative ? relative : CalendarLabels.day(day))
                .font(.headline)
                .foregroundStyle(day == today ? Palette.primary : Color.primary)
            if isRelative {
                Text(CalendarLabels.shortDay(day))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ entry: CalendarEntry) -> some View {
        let color = Palette.item(source: entry.item.source, color: entry.item.color)
        return Button {
            onOpen(entry)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                timeLabel(entry)
                    .frame(width: 64, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.item.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        ColorDot(color, size: 7)
                        Text(entry.item.sourceLabel)
                        if let status = CalendarLabels.status(entry.item.status) {
                            Text("·")
                            Text(status)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar.row.\(entry.id)")
    }

    @ViewBuilder
    private func timeLabel(_ entry: CalendarEntry) -> some View {
        if let start = entry.start, let end = entry.end {
            VStack(alignment: .trailing, spacing: 2) {
                Text(CalendarLabels.time(start))
                Text(CalendarLabels.time(end))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .monospacedDigit()
        } else {
            Text("All day")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
