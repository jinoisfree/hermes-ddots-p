import Foundation

@main struct UpdateReminderTests {
    static func main() {
        let suite = "ddots-update-reminder-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let late = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 23, minute: 59, second: 59))!
        let policy = UpdateReminder(defaults: defaults, calendar: calendar)
        precondition(policy.allowsCheck(manual: false, now: late))
        policy.hideToday(now: late)
        precondition(!policy.allowsCheck(manual: false, now: late))
        precondition(policy.allowsCheck(manual: true, now: late))
        let restarted = UpdateReminder(defaults: UserDefaults(suiteName: suite)!, calendar: calendar)
        precondition(!restarted.allowsCheck(manual: false, now: late))
        precondition(restarted.allowsCheck(manual: false, now: late.addingTimeInterval(1)))
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let dst = UpdateReminder(defaults: defaults, calendar: calendar)
        dst.hideToday(now: spring)
        precondition(!dst.allowsCheck(manual: false, now: spring.addingTimeInterval(23 * 3600 - 1)))
        precondition(dst.allowsCheck(manual: false, now: spring.addingTimeInterval(23 * 3600)))
        print("UpdateReminderTests passed: default, day suppression, manual bypass, restart, midnight, DST")
    }
}
