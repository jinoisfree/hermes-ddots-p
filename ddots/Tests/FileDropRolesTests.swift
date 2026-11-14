import Foundation

@main struct FileDropRolesTests {
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FAIL \(name)\n", stderr); exit(1) }; print("PASS \(name)")
    }
    static func main() {
        // AC-55(2): the roles heard once survive a restart, so the first card already knows who can take a drop.
        let suite = "drop-roles-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FileDropSettings(defaults: defaults)
        check(first.roles.isEmpty, "AC-55 nothing stored before the first context answer")
        first.learn(roles: ["work-x": ["work"], "home-y": ["personal", "mail"], "doc-z": ["doctor"]])
        check(first.roles == ["work-x": ["work"], "home-y": ["personal"]], "AC-55 only work and personal roles are kept")
        let restarted = FileDropSettings(defaults: defaults)
        check(restarted.roles == first.roles, "AC-55 a restarted app reads the stored roles")
        restarted.learn(roles: [:])
        check(FileDropSettings(defaults: defaults).roles == first.roles, "AC-55 an empty answer never erases stored roles")

        first.engine = .init(model: "haiku", effort: nil, seconds: 15, revision: "synthetic", choices: [.init(model: "haiku", efforts: [nil])])
        first.model = "haiku"; first.effort = "high"
        var saves = 0
        first.saveEngine = { _, _ in saves += 1; throw FileDropServiceError.unavailable }
        first.save()
        check(first.efforts == [nil] && saves == 0, "T-08f unsupported effort is absent and never submitted")
        check(FileDropSettings(defaults: defaults).engine == nil, "T-08f engine selection is not copied to UserDefaults")

        // The cast: stored roles ∩ ddots members, the default recipient or the first agent when nothing is stored.
        let none = FileDropCast(members: ["lead-q", "other-r"], roles: [:], fallback: "other-r")
        check(none.candidates == ["other-r"] && none.profile(role: "personal") == "other-r", "AC-55 no stored roles: the default recipient leads")
        let missing = FileDropCast(members: ["lead-q", "other-r"], roles: [:], fallback: "absent-s")
        check(missing.candidates == ["lead-q"] && missing.lead == "lead-q", "AC-55 default recipient outside the cast: the first agent leads")
        let cast = FileDropCast(members: ["lead-q", "home-y", "work-x", "doc-z"], roles: first.roles.merging(["doc-z": ["doctor"]]) { $1 }, fallback: "lead-q")
        check(cast.candidates == ["home-y", "work-x"] && cast.profile(role: "work") == "work-x" && cast.profile(role: "personal") == "home-y", "AC-55 candidates are role holders in the cast; a role resolves to its holder")
        let narrow = FileDropCast(members: ["home-y"], roles: first.roles, fallback: "home-y")
        check(narrow.candidates == ["home-y"] && narrow.profile(role: "work") == "home-y", "AC-55 a role nobody in the cast holds falls back to a holder, never to a stranger")
    }
}
