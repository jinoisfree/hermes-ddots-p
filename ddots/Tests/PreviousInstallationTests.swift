import Foundation

@main struct PreviousInstallationTests {
    static func main() {
        let current = "com.example.transition." + UUID().uuidString
        let old = "com.example.previous." + UUID().uuidString
        let defaults = UserDefaults(suiteName: current)!
        defer {
            defaults.removePersistentDomain(forName: current)
            defaults.removePersistentDomain(forName: old)
        }
        defaults.setPersistentDomain(["existing": "old", "oldOnly": 42], forName: old)
        defaults.setPersistentDomain(["existing": "new"], forName: current)
        let before = defaults.persistentDomain(forName: old)! as NSDictionary
        AppIdentity.inheritPreferences(defaults, previous: [old])
        precondition(defaults.string(forKey: "existing") == "new", "current settings win")
        precondition(defaults.integer(forKey: "oldOnly") == 42, "previous settings remain readable")
        defaults.set(99, forKey: "oldOnly")
        precondition(defaults.integer(forKey: "oldOnly") == 99, "new writes belong to current settings")
        precondition((defaults.persistentDomain(forName: old)! as NSDictionary) == before,
                     "previous preferences remain unchanged for rollback")
        let policy: [String: Any] = ["DDotsPreviousBundleIdentifiers":
            [old, old, current, "../bad", "bad\nvalue"]]
        precondition(AppIdentity.previousIdentifiers(policy, current: current) == [old])
        precondition(AppIdentity.previousIdentifiers([:], current: current).isEmpty)
        print("Previous installation: identity validation, preference fallback, write isolation passed")
    }
}
