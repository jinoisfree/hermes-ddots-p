import Foundation

@main struct HermesLocatorTests {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-locator-" + UUID().uuidString)
        let suite = "ddots-locator-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: home); defaults.removePersistentDomain(forName: suite) }
        func root(_ name: String, profile: Bool = false) throws -> URL {
            let url = home.appendingPathComponent(name)
            let store = profile ? url.appendingPathComponent("profiles/test") : url
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try Data().write(to: store.appendingPathComponent("state.db"))
            return url.resolvingSymlinksInPath()
        }
        let env = try root("environment"), saved = try root("saved"), standard = try root(".hermes"), agentRoot = try root("agent", profile: true)
        let argsRoot = try root("arguments")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        func plist(_ name: String, _ value: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: agents.appendingPathComponent(name))
        }
        try plist("zzz-gateway.plist", ["Label": "ai.hermes.gateway", "EnvironmentVariables": ["HERMES_HOME": agentRoot.path]])
        try plist("aaa-hermes.plist", ["ProgramArguments": ["hermes", "--home", argsRoot.path]])
        defaults.set(saved.path, forKey: HermesLocator.homeKey)
        func locator(_ environment: [String: String] = [:], files: HermesLocator.Files = .live, smoke: Bool = false) -> HermesLocator {
            HermesLocator(environment: { environment }, defaults: defaults, userHome: home, files: files, isSmoke: smoke)
        }
        precondition(locator(["HERMES_HOME": env.path]).locate() == env)
        defaults.set(saved.path, forKey: HermesLocator.homeKey)
        precondition(locator(["HERMES_HOME": home.appendingPathComponent("missing").path]).locate() == saved)
        defaults.removeObject(forKey: HermesLocator.homeKey)
        precondition(locator().locate() == agentRoot)
        defaults.removeObject(forKey: HermesLocator.homeKey)
        try FileManager.default.removeItem(at: agents.appendingPathComponent("zzz-gateway.plist"))
        precondition(locator().locate() == argsRoot)
        defaults.removeObject(forKey: HermesLocator.homeKey)
        try FileManager.default.removeItem(at: agents.appendingPathComponent("aaa-hermes.plist"))
        try plist("unrelated.plist", ["ProgramArguments": ["other", "--home", env.path]])
        precondition(locator().locate() == standard)
        precondition(locator().normalize("~/agent/profiles/test") == agentRoot)
        let link = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: agentRoot)
        precondition(locator().normalize(link.appendingPathComponent("profiles/test").path) == agentRoot)
        let noHome = home.appendingPathComponent("cache-user")
        var requested = home.appendingPathComponent("later")
        let cached = HermesLocator(environment: { ["HERMES_HOME": requested.path] }, defaults: defaults,
                                   userHome: noHome, isSmoke: true)
        let now = Date(timeIntervalSince1970: 1_000)
        precondition(cached.locate(now: now) == nil)
        _ = try root("later")
        precondition(cached.locate(now: now.addingTimeInterval(59)) == nil)
        precondition(cached.locate(now: now.addingTimeInterval(60)) == requested.resolvingSymlinksInPath())
        requested = env
        precondition(cached.locate(now: now.addingTimeInterval(359)) != env)
        precondition(cached.locate(now: now.addingTimeInterval(360)) == env)
        let clickedRoot = home.appendingPathComponent("clicked")
        let clicked = HermesLocator(environment: { ["HERMES_HOME": clickedRoot.path] }, defaults: defaults, userHome: noHome, isSmoke: true)
        precondition(clicked.locate(now: now) == nil)
        _ = try root("clicked")
        clicked.invalidate()
        precondition(clicked.locate(now: now.addingTimeInterval(1)) == clickedRoot.resolvingSymlinksInPath())
        var reads = 0
        var files = HermesLocator.Files.live
        files.data = { _ in reads += 1; return nil }
        precondition(locator(["HERMES_HOME": env.path], files: files, smoke: true).locate() == env)
        precondition(reads == 0)
        precondition(locator(["HERMES_HOME": home.appendingPathComponent("absent").path], files: files, smoke: true).locate() == nil)
        precondition(reads == 0)
        print("HermesLocatorTests passed: precedence, saved root, plist environment/arguments, gateway priority, default, normalization, symlinks, validation, caches, smoke isolation")
    }
}
