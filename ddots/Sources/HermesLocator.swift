import Foundation

/// Discovers roots from metadata and file existence only, without opening databases or secret files.
final class HermesLocator {
    static let shared = HermesLocator()
    static let homeKey = "hermesHome"
    struct Files {
        var exists: (URL) -> Bool
        var children: (URL) -> [URL]
        var data: (URL) -> Data?
        var canonical: (URL) -> URL
        static let live = Files(
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            children: { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] },
            data: { try? Data(contentsOf: $0) },
            canonical: { $0.standardizedFileURL.resolvingSymlinksInPath() })
    }
    private let environment: () -> [String: String]
    private let defaults: UserDefaults
    private let userHome: URL
    private let files: Files
    private let isSmoke: Bool
    private let lock = NSLock()
    private var cached: URL?
    private var expires = Date.distantPast

    init(environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         defaults: UserDefaults = .standard, userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         files: Files = .live, isSmoke: Bool = CommandLine.arguments.contains("--ui-smoke")) {
        self.environment = environment; self.defaults = defaults; self.userHome = userHome
        self.files = files; self.isSmoke = isSmoke
    }

    func normalize(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = trimmed == "~" ? userHome.path : trimmed.hasPrefix("~/") ? userHome.appendingPathComponent(String(trimmed.dropFirst(2))).path : trimmed
        guard expanded.hasPrefix("/") else { return nil }
        var root = files.canonical(URL(fileURLWithPath: expanded))
        if root.deletingLastPathComponent().lastPathComponent == "profiles" { root.deleteLastPathComponent(); root.deleteLastPathComponent() }
        return root
    }
    func containsRecords(_ root: URL) -> Bool {
        files.exists(root.appendingPathComponent("state.db")) || files.children(root.appendingPathComponent("profiles"))
            .contains { !$0.lastPathComponent.hasPrefix(".") && files.exists($0.appendingPathComponent("state.db")) }
    }
    var fallbackHome: URL {
        normalize(environment()["HERMES_HOME"] ?? "") ?? (isSmoke
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ddots-no-hermes")
            : userHome.appendingPathComponent(".hermes"))
    }
    func invalidate() { lock.lock(); expires = .distantPast; lock.unlock() }

    func locate(now: Date = Date()) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if now < expires { return cached }
        var candidates = [environment()["HERMES_HOME"]].compactMap { $0 }
        if !isSmoke {
            if let saved = defaults.string(forKey: Self.homeKey) { candidates.append(saved) }
        }
        cached = candidates.compactMap(normalize).first(where: containsRecords)
        if cached == nil, !isSmoke {
            let agents = files.children(userHome.appendingPathComponent("Library/LaunchAgents"))
                .filter { $0.pathExtension == "plist" }
                .compactMap { agent -> (URL, [String: Any])? in
                    guard let data = files.data(agent),
                          let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
                    return (agent, plist)
                }
                .sorted { lhs, rhs in
                    let a = lhs.0.lastPathComponent == "ai.hermes.gateway.plist" || lhs.1["Label"] as? String == "ai.hermes.gateway"
                    let b = rhs.0.lastPathComponent == "ai.hermes.gateway.plist" || rhs.1["Label"] as? String == "ai.hermes.gateway"
                    return a != b ? a : lhs.0.lastPathComponent < rhs.0.lastPathComponent
                }
            for (agent, plist) in agents {
                let args = plist["ProgramArguments"] as? [String] ?? []
                let related = ([agent.lastPathComponent, plist["Label"] as? String ?? ""] + args)
                    .contains { $0.localizedCaseInsensitiveContains("hermes") }
                guard related else { continue }
                if let path = (plist["EnvironmentVariables"] as? [String: String])?["HERMES_HOME"] { candidates.append(path) }
                if let index = args.firstIndex(of: "--home"), args.indices.contains(index + 1) { candidates.append(args[index + 1]) }
            }
            candidates.append(userHome.appendingPathComponent(".hermes").path)
        }
        if cached == nil { cached = candidates.compactMap(normalize).first(where: containsRecords) }
        expires = now.addingTimeInterval(cached == nil ? 60 : 300)
        if let cached, !isSmoke { defaults.set(cached.path, forKey: Self.homeKey) }
        return cached
    }
}
