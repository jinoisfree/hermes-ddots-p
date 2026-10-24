import Foundation

/// A calendar-day pause for automatic notices, never a skipped release or installation consent.
struct UpdateReminder {
    static let key = "updateReminderHiddenUntil"
    var defaults: UserDefaults = .standard
    var calendar: Calendar = .current

    func allowsCheck(manual: Bool, now: Date = Date()) -> Bool {
        manual || now >= (defaults.object(forKey: Self.key) as? Date ?? .distantPast)
    }
    func hideToday(now: Date = Date()) {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        defaults.set(nextDay, forKey: Self.key)
    }
}
