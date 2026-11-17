import AppKit
import SwiftUI

/// The organizer's colors, taken from web/src/styles/tokens.css (the one place colors are
/// defined), in light and dark. Keep the two in step: a token added there gets a line here.
///
/// Native first: use system colors and materials for surfaces and text (`.primary`,
/// `.secondary`), and these tokens for meaning: a calendar source, a status.
///
///     Palette.source("reminders")          // a calendar source key, as the server sends it
///     Palette.item(source: item.source, color: item.color)   // one calendar item (the web's itemColor)
///     Palette.status(.overdue)
///     Palette.hex(list.color)              // a color the server sent ("#F19A37")
nonisolated public enum Palette {
    // MARK: Surfaces (the web's; prefer native backgrounds)

    public static let primary = Color(light: 0x3563D1, dark: 0x7398F2)
    public static let destructive = Color(light: 0xCF3F3F, dark: 0xE5605F)
    public static let mutedForeground = Color(light: 0x6B6B70, dark: 0x9A9AA3)
    public static let selection = Color(light: 0xE6EDFB, dark: 0x1F2A44)

    // MARK: Calendar sources (--source-<key>)

    private static let sources: [String: Color] = [
        "holidays": Color(light: 0xA0782C, dark: 0xD4AB58),
        "apple": Color(light: 0x64748B, dark: 0x94A3B8),
        "interviews": Color(light: 0xD0476B, dark: 0xEF7896),
        "job_events": Color(light: 0x1F8FA8, dark: 0x4FBCD4),
        "next_actions": Color(light: 0xD0682A, dark: 0xEC9358),
        "reminders": Color(light: 0xF19A37, dark: 0xF5AD5A),
    ]
    public static let sourceDefault = Color(light: 0x7A7A85, dark: 0x9A9AA3)

    /// The color of a calendar source key, else `fallback` (a hex the server sent), else the
    /// default. Takes the key as the server sends it (`reminders`, `jobs_interviews`) or as the
    /// token is named (`job-events`).
    public static func source(_ key: String, fallback: String? = nil) -> Color {
        sources[sourceToken(key)] ?? hex(fallback) ?? sourceDefault
    }

    /// The token name a source key is drawn in. The key is normalized as the web's `cssKey()`
    /// does (lowercase; each run of characters other than letters and digits is one separator,
    /// `_` here, `-` in CSS): `job-events` -> `job_events`.
    static func sourceToken(_ key: String) -> String {
        var normalized = ""
        var separated = false
        for character in key.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                normalized.append(character)
                separated = false
            } else if !separated {
                normalized.append("_")
                separated = true
            }
        }
        return normalized
    }

    /// Sources whose items keep their own color (each Apple calendar its Calendar.app color,
    /// each reminder its list's), as the web's `OWN_COLOR_SOURCES`.
    public static let ownColorSources: Set<String> = ["apple", "reminders"]

    /// One calendar item's color, as the web's `itemColor`: its own for an Apple calendar or a
    /// reminder list, else its source's token, else the color the server sent.
    public static func item(source: String, color: String?) -> Color {
        if ownColorSources.contains(source), let own = hex(color) { return own }
        return self.source(source, fallback: color)
    }

    // MARK: Statuses (--status-<key>)

    public enum Status: String, CaseIterable, Sendable {
        case open, done, overdue, today, ok, stale, error, never
    }

    public static func status(_ status: Status) -> Color {
        switch status {
        case .open: Color(light: 0x6B6B70, dark: 0x9A9AA3)
        case .done: Color(light: 0x9A9AA0, dark: 0x6E6E76)
        case .overdue: Color(light: 0xCF3F3F, dark: 0xEF6B6B)
        case .today: Color(light: 0x3563D1, dark: 0x7398F2)
        case .ok: Color(light: 0x2F9A6A, dark: 0x5CC596)
        case .stale: Color(light: 0xC2840F, dark: 0xE0A83A)
        case .error: Color(light: 0xCF3F3F, dark: 0xEF6B6B)
        case .never: Color(light: 0x9A9AA0, dark: 0x6E6E76)
        }
    }

    /// A status by its API string ("ok", "stale", ...); unknown ones read as `open`.
    public static func status(_ key: String) -> Color {
        status(Status(rawValue: key.lowercased()) ?? .open)
    }

    // MARK: Server-sent colors

    /// "#F19A37", "F19A37" or "#F19A37FF" as a Color; nil when absent or malformed.
    public static func hex(_ string: String?) -> Color? {
        guard var text = string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let rgb = text.count == 8 ? UInt32(value >> 8) : UInt32(value)
        let alpha = text.count == 8 ? Double(value & 0xFF) / 255 : 1
        return Color(rgb: rgb).opacity(alpha)
    }
}

extension Color {
    /// A color from 0xRRGGBB.
    nonisolated public init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// A color that follows the light/dark appearance.
    ///
    /// Nonisolated on purpose: AppKit calls the provider on SwiftUI's render thread, and a
    /// main-actor closure there traps (this module defaults to the main actor).
    nonisolated public init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(rgb: isDark ? dark : light))
        })
    }
}
