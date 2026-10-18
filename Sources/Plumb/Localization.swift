import Foundation

/// Interface language: American English or German. Follows the macOS language
/// (including the per-app setting) unless overridden in plumb's settings.
/// Dates and numbers use the matching locale: en_US or de_DE.
enum AppLanguage: String, CaseIterable {
    case en, de

    /// Set once at launch from the settings ("system", "en" or "de").
    nonisolated(unsafe) static var preference = "system"

    /// Scoped override, e.g. for tests: `AppLanguage.$override.withValue(.de) { ... }`.
    @TaskLocal static var override: AppLanguage?

    static var current: AppLanguage {
        if let override { return override }
        if let forced = AppLanguage(rawValue: preference) { return forced }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("de") ? .de : .en
    }

    static var locale: Locale { Locale(identifier: current == .de ? "de_DE" : "en_US") }

    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar
    }
}

/// Translates an English interface text. English is the key; missing German
/// entries fall back to English (a test keeps that from happening silently).
func L(_ english: String) -> String {
    guard AppLanguage.current == .de else { return english }
    return Translations.de[english] ?? english
}

/// Translates and fills `%@` placeholders in order.
func L(_ english: String, _ args: CVarArg...) -> String {
    String(format: L(english), locale: AppLanguage.locale, arguments: args)
}

extension Date {
    /// Formats in the interface language's locale.
    func text(_ style: Date.FormatStyle) -> String { formatted(style.locale(AppLanguage.locale)) }

    /// "14:30" / "2:30 PM"
    var timeText: String { text(Date.FormatStyle(date: .omitted, time: .shortened)) }
    /// "18. Okt." / "Oct 18"
    var dayMonthText: String { text(.dateTime.day().month(.abbreviated)) }
    /// "18.10.2026, 14:30" / "10/18/2026, 2:30 PM"
    var dateTimeText: String { text(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()) }
}

/// "1.4" / "1,4"
func numberText(_ value: Double, digits: Int = 1) -> String {
    value.formatted(.number.precision(.fractionLength(digits)).locale(AppLanguage.locale))
}

/// "18 minutes, 40 seconds" / "18 Minuten, 40 Sekunden", for VoiceOver.
func spokenDuration(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.calendar = AppLanguage.calendar
    return formatter.string(from: max(0, seconds.rounded())) ?? ""
}
