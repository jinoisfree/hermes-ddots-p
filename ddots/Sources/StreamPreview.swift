import Foundation

/// Disposable display state, never a Slack message or a persisted conversation.
struct StreamPreview: Codable, Equatable, Identifiable {
    var id: String
    var room: String
    var thread: String
    var since: Double
    var updated: Double
    var expires: Double
    var body: String
    var done: Bool
    var profile: String? = nil
    var status: String? = nil
    var input_id: String? = nil
    var execution: String? = nil
    // Local rendering state only; absent from server snapshots.
    var revealProgress: Double? = nil

    var displayedBody: String {
        let label: String?
        switch status {
        case "waiting": label = "추가 지시 반영 대기"
        case "redirecting", "applying": label = "추가 지시 반영 중"
        default: label = nil
        }
        guard let label, body != label else { return body }
        return label + "\n\n" + body
    }

    func valid(at now: Double) -> Bool {
        !id.isEmpty && !room.isEmpty && !thread.isEmpty && !body.isEmpty && body.utf8.count <= 256_000
            && since.isFinite && updated.isFinite && expires.isFinite
            && since <= updated && updated <= now + 5 && expires > now && expires <= updated + 121
    }

    static func read(home: URL, now: Date = Date()) -> [Self] {
        let files = FileManager.default
        let profiles = home.appendingPathComponent("profiles")
        let names = ((try? files.contentsOfDirectory(atPath: profiles.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "default" }.sorted()
        let roots = [("default", home)] + names.map { ($0, profiles.appendingPathComponent($0)) }
        var result: [Self] = []
        for (profile, root) in roots {
            let folder = root.appendingPathComponent("cache/ddots-streams")
            for file in ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []).prefix(64) where file.pathExtension == "json" {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, (values.fileSize ?? Int.max) <= 300_000,
                      let data = try? Data(contentsOf: file), var preview = try? JSONDecoder().decode(Self.self, from: data),
                      preview.valid(at: now.timeIntervalSince1970) else { continue }
                preview.profile = profile
                result.append(preview)
            }
        }
        return Array(result.sorted { $0.updated > $1.updated }.prefix(16)).sorted { $0.id < $1.id }
    }
}

/// Opt-in, bounded local diagnostics. Contains counts and timing, never conversation text.
enum StreamPreviewDiagnostics {
    private static var sections: [String: [String: String]] = [:]
    static func record(_ section: String, _ values: [String: String]) {
        guard UserDefaults.standard.bool(forKey: "streamPreviewDiagnostics"), sections[section] != values else { return }
        sections[section] = values
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ddots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshot: [String: Any] = ["updated": Date().timeIntervalSince1970, "sections": sections]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("stream-diagnostics.json"), options: .atomic)
        }
    }
}

/// A short, bounded reveal of bytes already received; never invents text or changes the authoritative Slack message.
struct StreamReveal {
    private struct State {
        var target: StreamPreview
        var characters: [Character]
        var count: Int
        var startCount: Int
        var started: TimeInterval
        var duration: TimeInterval
    }
    private var states: [String: State] = [:]
    private var order: [String] = []
    private func key(_ p: StreamPreview) -> String { (p.profile ?? "") + ":" + p.id }

    mutating func receive(_ previews: [StreamPreview], now: TimeInterval) {
        let incoming = previews.map(key)
        // Finish a bounded local reveal even if the server removes its preview.
        let retained = order.filter { id in
            guard !incoming.contains(id), let state = states[id] else { return false }
            return state.count < state.characters.count && now - state.started < state.duration
                && state.target.status != "working"
                && !previews.contains { $0.room == state.target.room && $0.thread == state.target.thread && $0.profile == state.target.profile }
        }
        order = incoming + retained
        states = states.filter { order.contains($0.key) }
        for preview in previews {
            let id = key(preview)
            if let state = states[id], preview.updated < state.target.updated { continue }
            if var state = states[id], state.target.body == preview.body {
                state.target = preview; states[id] = state; continue
            }
            let characters = Array(preview.body)
            let old = states[id]
            // Filtering an unfinished marker or replacing final formatting can
            // change the suffix. Never erase the entire revealed body to replay
            // it from character one; update the visible prefix in place.
            let count = preview.status == "working" ? characters.count : min(old?.target.status == "working" ? 1 : (old?.count ?? 1), characters.count)
            let remaining = characters.count - count
            states[id] = State(target: preview, characters: characters, count: count, startCount: count,
                               started: now, duration: min(3.0, max(0.12, Double(remaining) / 150)))
        }
    }
    mutating func frame(now: TimeInterval, immediately: Bool = false) -> [StreamPreview] {
        order.compactMap { id in
            guard var state = states[id] else { return nil }
            let fraction = immediately ? 1 : min(1, max(0, (now - state.started) / state.duration))
            state.count = max(state.count, state.startCount + Int(ceil(Double(state.characters.count - state.startCount) * fraction)))
            states[id] = state
            var preview = state.target
            preview.revealProgress = state.count < state.characters.count ? Double(state.count) / Double(max(1, state.characters.count)) : nil
            preview.body = Self.visiblePrefix(String(state.characters.prefix(state.count)))
            return preview
        }
    }
    static func visiblePrefix(_ body: String) -> String {
        // Do not briefly draw a half-received rich-text tag as a long line and
        // then remove it when '>' arrives. Completed tags use the normal renderer.
        guard let start = body.lastIndex(of: "<"), !body[start...].contains(">") else { return body }
        let tail = body[start...].lowercased()
        let tags = ["<span", "</span", "<b", "</b", "<strong", "</strong", "<i", "</i", "<em", "</em", "<u", "</u", "<s", "</s", "<del", "</del"]
        if tags.contains(where: { $0.hasPrefix(tail) || tail == $0 || tail.hasPrefix($0 + " ") }) {
            return String(body[..<start])
        }
        return body
    }
    var pending: Bool { states.values.contains { $0.count < $0.characters.count } }
}
