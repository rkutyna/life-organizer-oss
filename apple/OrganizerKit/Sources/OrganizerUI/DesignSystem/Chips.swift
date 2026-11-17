import SwiftUI

/// A small colored dot: a calendar source, a Reminders list, a project.
public struct ColorDot: View {
    let color: Color
    let size: CGFloat

    public init(_ color: Color, size: CGFloat = 8) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A source or list label with its color dot: "● Groceries". On a phone in a tight row pass
/// `compact: true` to show only the dot (the name stays for VoiceOver).
///
///     SourceChip("Reminders", color: Palette.source("reminders"))
///     SourceChip(reminder.listTitle ?? "Reminders", color: Palette.hex(reminder.listColor) ?? Palette.source("reminders"))
public struct SourceChip: View {
    let title: String
    let color: Color
    let compact: Bool

    public init(_ title: String, color: Color, compact: Bool = false) {
        self.title = title
        self.color = color
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 4) {
            ColorDot(color, size: 7)
            if !compact {
                Text(title)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, compact ? 0 : 6)
        .padding(.vertical, 2)
        .background {
            if !compact {
                Capsule().strokeBorder(.separator, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
