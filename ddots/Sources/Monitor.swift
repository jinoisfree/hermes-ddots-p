import Foundation

final class StatusMonitor {
    let codexRoot: URL
    let claudeRoot: URL
    let eventRoot: URL
    /// How long a hook's event counts, and how long its file is kept.
    static let eventLife: TimeInterval = 86_400
    private var tails: [String: TranscriptTail] = [:]
    private var records: [String: WorkItem] = [:]
    private var lastDiscovery = Date.distantPast
    private var counts: [Provider: Int] = [:]
    private var discoveryErrors = Set<Provider>()
    private var capped = false
    private var receivedHooks = Set<Provider>()

    init(codexRoot: URL? = nil, claudeRoot: URL? = nil, eventRoot: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        self.codexRoot = codexRoot ?? URL(fileURLWithPath: env["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path).appendingPathComponent("sessions")
        self.claudeRoot = claudeRoot ?? URL(fileURLWithPath: env["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path).appendingPathComponent("projects")
        self.eventRoot = eventRoot ?? home.appendingPathComponent(AppIdentity.supportFolder + "/events")
    }

    func poll(now: Date = Date(), forceDiscovery: Bool = false) -> Snapshot {
        if forceDiscovery || now.timeIntervalSince(lastDiscovery) >= 15 {
            discover(now: now); lastDiscovery = now
        }
        for tail in tails.values {
            for item in tail.read() { merge(item) }
        }
        readHookEvents(now: now)
        records = records.filter { now.timeIntervalSince($0.value.updatedAt) <= 86400 }
        let tasks = records.values.map { $0.effective(at: now) }.sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank > $1.state.rank }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        let connections = [Provider.codex, .claude].map { provider in
            let root = provider == .codex ? codexRoot : claudeRoot
            let readable = FileManager.default.isReadableFile(atPath: root.path) && !discoveryErrors.contains(provider)
            let errors = tails.values.filter { $0.decoder.provider == provider && $0.lastError != nil }.count
            let count = counts[provider] ?? 0
            let hookStatus = receivedHooks.contains(provider) ? "공식 훅 수신 확인" : "승인 알림: 훅 확인 필요"
            return ConnectionInfo(provider: provider, available: readable && errors == 0, fileCount: count,
                                  detail: !readable ? "기록 폴더에 접근할 수 없음" : errors > 0 ? "일부 기록 읽기 실패" : "최근 기록 \(count)개 · \(hookStatus)")
        }
        let warning = capped || tasks.count > 200 ? "최근 세션이 많아 최대 200개까지 표시합니다." : nil
        let candidates = tails.values.compactMap { tail -> ScreenFocus? in
            guard tail.lastError == nil, let item = tail.decoder.last,
                  let current = records[item.id]?.effective(at: now), current.state == .running,
                  current.turnID.isEmpty || current.turnID == item.turnID else { return nil }
            return tail.decoder.screenFocus(now: now)
        }
        let focus = ScreenFocus.select(candidates, now: now)
        return Snapshot(observedAt: now, tasks: Array(tasks.prefix(200)), connections: connections,
                        warning: warning, screenUseUntil: focus?.expiresAt, screenFocus: focus)
    }

    func merge(_ item: WorkItem) {
        guard !item.sessionID.isEmpty else { return }
        if let previous = records[item.id] {
            guard item.updatedAt >= previous.updatedAt else { return }
            if previous.source == "공식 훅", item.source != "공식 훅", previous.state == .waiting,
               item.event == "activity" || item.event == "assistant_activity" { return }
        }
        records[item.id] = item
    }

    private func discover(now: Date) {
        discoveryErrors.removeAll(); capped = false
        var activePaths = Set<String>()
        for provider in [Provider.codex, .claude] {
            let root = provider == .codex ? codexRoot : claudeRoot
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
            var candidates: [(URL, Date)] = []
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { [weak self] _, _ in self?.discoveryErrors.insert(provider); return true }) else {
                discoveryErrors.insert(provider); counts[provider] = 0; continue
            }
            for case let url as URL in enumerator {
                if url.lastPathComponent == "subagents" { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let date = values.contentModificationDate, now.timeIntervalSince(date) < 86400 else { continue }
                candidates.append((url, date))
            }
            candidates.sort { $0.1 > $1.1 }
            if candidates.count > 200 { capped = true }
            counts[provider] = min(candidates.count, 200)
            for (url, _) in candidates.prefix(200) {
                activePaths.insert(url.path)
                if tails[url.path] == nil { tails[url.path] = TranscriptTail(url: url, provider: provider) }
            }
        }
        tails = tails.filter { activePaths.contains($0.key) }
    }

    private func readHookEvents(now: Date) {
        receivedHooks.removeAll()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: eventRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]) else { return }
        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey]), values.isSymbolicLink != true else { continue }
            // One file is written for each session and nothing else takes them away. A day after its last change
            // it says nothing any more, and reading every one of them on each pass would only get slower.
            if let changed = values.contentModificationDate, now.timeIntervalSince(changed) >= Self.eventLife { try? FileManager.default.removeItem(at: url); continue }
            guard (values.fileSize ?? 0) <= 8192,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let item = HookBridge.decodeEvent(object), now.timeIntervalSince(item.updatedAt) < Self.eventLife else { continue }
            receivedHooks.insert(item.provider)
            merge(item)
        }
    }
}
