import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Display helpers. Timestamps arrive as ISO-8601 strings from PostgREST
/// (see Models.swift) and are parsed lazily here for display only.
enum Formatting {
    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Postgres `timestamptz` often serializes with a space and no `T`
    /// (e.g. "2026-07-29 18:04:05.123+00"). Try the strict ISO parsers first,
    /// then fall back to a lenient formatter.
    private static let fallback: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"
        return f
    }()

    static func date(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = isoWithFractional.date(from: raw) { return d }
        if let d = iso.date(from: raw) { return d }
        // Normalize the Postgres space-separated form to a `T` and retry.
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        if let d = isoWithFractional.date(from: normalized) { return d }
        if let d = iso.date(from: normalized) { return d }
        return fallback.date(from: raw)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Compact relative time for lists ("3h ago"). Falls back to "—".
    static func relativeTime(_ raw: String?) -> String {
        guard let d = date(from: raw) else { return "—" }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    /// Compact relative time from a parsed `Date` ("3h ago"). "—" for nil.
    static func relativeTime(from date: Date?) -> String {
        guard let date else { return "—" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// Full local date+time for detail screens. Falls back to "—".
    static func absoluteTime(_ raw: String?) -> String {
        guard let d = date(from: raw) else { return "—" }
        return absolute.string(from: d)
    }

    /// Copy a value (typically an IP) to the pasteboard. No-op off-device.
    static func copyToClipboard(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
    }
}
