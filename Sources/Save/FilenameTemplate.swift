import Branding
import Foundation

/// Resolves a user-defined clip file-name template into a safe base name.
///
/// Supported tokens are substituted, then the result is sanitized so empty
/// tokens (e.g. an unknown foreground app) can't leave stray or illegal
/// characters in the file name.
public enum FilenameTemplate {
    /// Produces the standard `<AppBranding.name>_<date>_<time>` naming, so
    /// direct builds keep the historical `ReplayMac_` prefix while App Store
    /// builds write `ReplayCap_`.
    public static var `default`: String { "\(AppBranding.name)_{date}_{time}" }

    /// `DateFormatter` pattern used for `{date}` unless the user picks another.
    public static let defaultDateFormat = "yyyy-MM-dd"
    /// `DateFormatter` pattern used for `{time}` unless the user picks another.
    /// Colons are deliberately avoided — macOS remaps `:` in file names.
    public static let defaultTimeFormat = "HH-mm-ss"

    /// Tokens shown in Settings, paired with a short description.
    public static let tokens: [(token: String, description: String)] = [
        ("{app}", "Foreground app name"),
        ("{date}", "Date, in the format chosen below"),
        ("{time}", "Time, in the format chosen below")
    ]

    /// Selectable `{date}` formats. Each stores a `DateFormatter` pattern; the UI
    /// shows a live example so users never have to know pattern syntax.
    public static let dateFormats: [String] = [
        "yyyy-MM-dd",   // 2026-07-21
        "dd.MM.yyyy",   // 21.07.2026
        "dd-MM-yyyy",   // 21-07-2026
        "MM-dd-yyyy",   // 07-21-2026
        "dd MMM yyyy",  // 21 Jul 2026
        "yyyyMMdd"      // 20260721
    ]

    /// Selectable `{time}` formats. Kept colon-free so names stay valid on disk.
    public static let timeFormats: [String] = [
        "HH-mm-ss",     // 14-00-15
        "HH.mm.ss",     // 14.00.15
        "hh.mm.ss a",   // 02.00.15 PM
        "HHmmss"        // 140015
    ]

    /// Renders a human-readable example of a pattern for the Settings pickers,
    /// using a fixed reference moment (21 Jul 2026, 14:00:15).
    public static func example(for pattern: String) -> String {
        formatted(referenceDate, as: pattern)
    }

    public static func resolve(
        template: String,
        appName: String?,
        dateFormat: String = defaultDateFormat,
        timeFormat: String = defaultTimeFormat,
        date: Date = Date()
    ) -> String {
        let dateString = formatted(date, as: dateFormat.isEmpty ? defaultDateFormat : dateFormat)
        let timeString = formatted(date, as: timeFormat.isEmpty ? defaultTimeFormat : timeFormat)

        var result = template
        result = result.replacingOccurrences(of: "{app}", with: appName ?? "")
        result = result.replacingOccurrences(of: "{date}", with: dateString)
        result = result.replacingOccurrences(of: "{time}", with: timeString)

        let sanitized = sanitize(result)
        return sanitized.isEmpty ? defaultBaseName(date: date) : sanitized
    }

    /// 21 Jul 2026, 14:00:15 local time — the sample used for pattern previews.
    private static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 21
        components.hour = 14
        components.minute = 0
        components.second = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: components) ?? Date()
    }()

    private static func formatted(_ date: Date, as format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var cleaned = name.components(separatedBy: illegal).joined(separator: "-")

        // Collapse separator runs left by empty tokens (e.g. "{app}_{date}"
        // with no app → "_2026-…").
        while cleaned.contains("__") {
            cleaned = cleaned.replacingOccurrences(of: "__", with: "_")
        }

        let trimSet = CharacterSet(charactersIn: "_-. ").union(.whitespaces)
        return cleaned.trimmingCharacters(in: trimSet)
    }

    private static func defaultBaseName(date: Date) -> String {
        ClipMetadata.defaultBaseName(date: date)
    }
}
