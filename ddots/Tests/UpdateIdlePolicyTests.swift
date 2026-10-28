import Foundation

@main struct UpdateIdlePolicyTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        typealias P = UpdateIdlePolicy
        let idle = P.Activity(idleSeconds: 300, hasDrafts: false, transferring: false)
        expect(P.decide(idle, elapsed: 0) == .install, "five minute boundary")
        for activity in [P.Activity(idleSeconds: 299.9, hasDrafts: false, transferring: false),
                         .init(idleSeconds: .nan, hasDrafts: false, transferring: false),
                         .init(idleSeconds: .infinity, hasDrafts: false, transferring: false),
                         .init(idleSeconds: 1000, hasDrafts: true, transferring: false),
                         .init(idleSeconds: 1000, hasDrafts: false, transferring: true),
                         .init(idleSeconds: 1000, hasDrafts: false, transferring: false, presenting: true)] {
            expect(P.decide(activity, elapsed: 60) == .wait, "unsafe activity waits")
        }
        expect(P.decide(idle, elapsed: 86399) == .install, "before deadline")
        expect(P.decide(idle, elapsed: 86400) == .expire, "deadline wins even idle")
        for enabled in [false, true] { for manual in [false, true] { for failures in 0...4 {
            expect(P.silent(enabled: enabled, manual: manual, failures: failures) == (enabled && !manual && failures < 3), "mode matrix")
        } } }
        let suite = "UpdateIdleTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SilentUpdateSettings(defaults: defaults)
        expect(settings.enabled, "default on")
        defaults.set(false, forKey: "silentUpdates")
        expect(!settings.enabled, "opt out")
        defaults.set(true, forKey: "silentUpdates")
        expect(settings.enabled, "opt in")
        for i in 1...3 { settings.failed("test error"); expect(settings.failures == i, "consecutive failures") }
        expect(settings.reason == "test error", "fallback explanation")
        settings.preparing(version: "2", build: "20")
        expect(!settings.installed(version: "1", build: "10") && settings.failures == 3, "old app is not success")
        expect(!settings.installed(version: "2", build: "19"), "must match build")
        settings.cancelled()
        expect(!settings.installed(version: "2", build: "20"), "cancel clears pending")
        settings.preparing(version: "2", build: "20")
        expect(settings.installed(version: "2", build: "20"), "actual replacement")
        expect(settings.failures == 0 && settings.reason.isEmpty, "success resets failures")
        expect(!settings.installed(version: "2", build: "20"), "notify exactly once")
        let notices = UpdateNoticeSettings(defaults: defaults)
        expect(notices.enabled, "update notices default on")
        notices.setEnabled(false)
        expect(!UpdateNoticeSettings(defaults: UserDefaults(suiteName: suite)!).enabled, "update notices persist off")
        notices.setEnabled(true)
        expect(notices.enabled, "update notices persist on")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = UpdateReminder(defaults: defaults)
        for enabled in [false, true] { for manual in [false, true] { for hidden in [false, true] { for silent in [false, true] {
            defaults.removeObject(forKey: UpdateReminder.key)
            if hidden { reminder.hideToday(now: now) }
            let allowed = UpdateNoticePolicy.allows(manual: manual, enabled: enabled,
                                                    reminderAllows: reminder.allowsCheck(manual: false, now: now))
            expect(allowed == (manual || (enabled && !hidden)), "notice/manual/today/silent policy matrix")
            let quiet = allowed && UpdateIdlePolicy.silent(enabled: silent, manual: manual, failures: 0)
            expect(quiet == (enabled && !hidden && silent && !manual), "no silent installation with notices off; manual stays explicit")
        } } } }
        print("PASS UpdateIdlePolicyTests: \(checks) checks, 0 failures")
    }
}
