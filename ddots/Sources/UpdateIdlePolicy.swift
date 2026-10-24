import Foundation

/// Pure scheduling policy. No clocks, preferences, UI, network or installer side effects.
enum UpdateIdlePolicy {
    struct Activity: Equatable {
        var idleSeconds: TimeInterval
        var hasDrafts: Bool
        var transferring: Bool
        var presenting: Bool = false
    }
    enum Decision: Equatable { case wait, install, expire }
    static func decide(_ activity: Activity, elapsed: TimeInterval) -> Decision {
        if elapsed >= 24 * 60 * 60 { return .expire }
        guard activity.idleSeconds.isFinite, activity.idleSeconds >= 300,
              !activity.hasDrafts, !activity.transferring, !activity.presenting else { return .wait }
        return .install
    }
    static func silent(enabled: Bool, manual: Bool, failures: Int) -> Bool {
        enabled && !manual && failures < 3
    }
}

struct SilentUpdateSettings {
    var defaults: UserDefaults = .standard
    var enabled: Bool { defaults.object(forKey: "silentUpdates") as? Bool ?? true }
    var failures: Int { defaults.integer(forKey: "silentUpdateFailures") }
    var reason: String { defaults.string(forKey: "silentUpdateFailureReason") ?? "" }
    func failed(_ reason: String) {
        defaults.set(min(failures + 1, 3), forKey: "silentUpdateFailures")
        defaults.set(reason, forKey: "silentUpdateFailureReason")
    }
    func preparing(version: String, build: String) {
        defaults.set(version, forKey: "silentUpdatePendingVersion")
        defaults.set(build, forKey: "silentUpdatePendingBuild")
    }
    func cancelled() {
        defaults.removeObject(forKey: "silentUpdatePendingVersion")
        defaults.removeObject(forKey: "silentUpdatePendingBuild")
    }
    /// A download alone is not success. Only launching the expected installed build is.
    func installed(version: String, build: String) -> Bool {
        guard defaults.string(forKey: "silentUpdatePendingVersion") == version,
              defaults.string(forKey: "silentUpdatePendingBuild") == build else { return false }
        defaults.set(0, forKey: "silentUpdateFailures")
        defaults.removeObject(forKey: "silentUpdateFailureReason")
        cancelled()
        return true
    }
}
