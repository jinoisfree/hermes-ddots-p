import Foundation

struct FileDropAssignment: Codable, Identifiable {
    var id = UUID().uuidString
    var at = Date().timeIntervalSince1970
    var room: String
    var ts: String?
    var files: Set<String>
    var profile: String
    var label: String
    var event: String? = nil
    var seen: Set<String> = []
    var outcome: String?
}

/// Immutable card IDs avoid lost increments when offline Macs merge. Changes to the
/// same card, expiry tombstones and clear markers use the existing SettingsSync clock.
/// This is a separate document; screen settings never contain drop history.
final class FileDropHistory {
    struct Habit: Codable {
        var at: Double
        var feature: String
        var engine: String
        var shown: [String]
        var first: String?
        var chosen: String?
        var opinion: String?
        var profile: String
        var result: String?
        var elapsed: Double?
        var failed = false
        var closed = false
    }
    struct Recent: Codable {
        var at: Double
        var feature: String
        var names: [String]
        var summary: String
        var action: String?
        var opinion: String?
        var profile: String
        var result: String?
        var works: [String] = []
    }
    struct Custom: Codable {
        var feature: String
        var instruction: String
        var profile: String
    }
    struct Comparison {
        var engine: String
        var cards = 0, first = 0, other = 0, auto = 0, opinion = 0, custom = 0, closed = 0, failures = 0
        var latencies: [Double] = []
        var median: Double? {
            let sorted = latencies.sorted(); guard !sorted.isEmpty else { return nil }
            let mid = sorted.count / 2
            return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }
    }
    let store: SettingsStore
    let device: String
    var onChange: (() -> Void)?
    var send: ((String, [String: SyncEntry]) -> Void)?
    var current: String?
    init(store: SettingsStore, device: String) { self.store = store; self.device = device; _ = store.refresh() }
    static func folder(home: URL) -> URL { home.appendingPathComponent("state/ddots-file-drop", isDirectory: true) }
    var cutoff: Double { store.entries["clear"]?.at ?? 0 }
    private func decode<T: Decodable>(_ entry: SyncEntry?, as type: T.Type) -> T? {
        guard let value = entry?.v else { return nil }; return try? JSONDecoder().decode(type, from: Data(value.utf8))
    }
    func rows<T: Decodable>(_ prefix: String, as type: T.Type) -> [(String, T)] {
        store.entries.compactMap { key, entry in key.hasPrefix(prefix) ? decode(entry, as: type).map { (key, $0) } : nil }
    }
    private func encoded<T: Encodable>(_ row: T) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(row)).flatMap { String(data: $0, encoding: .utf8) }
    }
    private func put<T: Encodable>(_ key: String, _ row: T, now: Double) {
        guard let value = encoded(row), store.entries[key]?.v != value else { return }
        let stamp = max(now, (store.entries[key]?.at ?? 0) + 0.000001)
        publish([key: SyncEntry(v: value, at: stamp, by: device)])
    }
    private func publish(_ entries: [String: SyncEntry]) {
        let changed = store.merge(entries); if !changed.isEmpty { send?(store.user, changed); onChange?() }
    }
    func refresh(now: Double = Date().timeIntervalSince1970) {
        if !store.refresh().isEmpty { onChange?() }; expire(now: now)
    }
    func receive(_ entries: [String: SyncEntry], now: Double = Date().timeIntervalSince1970) {
        let changed = store.merge(Self.valid(entries)); if !changed.isEmpty { onChange?() }; expire(now: now)
    }
    func sendAll() { _ = store.refresh(); send?(store.user, store.entries) }
    /// Only the declared data shapes cross the relay. Unknown keys and oversized values are refused.
    static func valid(_ entries: [String: SyncEntry]) -> [String: SyncEntry] {
        entries.filter { key, entry in
            guard SettingsSync.valid(key), entry.at.isFinite, entry.by.utf8.count <= 100 else { return false }
            let prefixes = ["h:", "short:", "a:", "seen:", "c:"]
            guard key == "clear" || prefixes.contains(where: key.hasPrefix), (entry.v?.utf8.count ?? 0) <= 32 * 1024 else { return false }
            if key == "clear" { return entry.v == "1" }
            guard let value = entry.v else { return true }
            if key.hasPrefix("seen:") { return value == "1" }
            let data = Data(value.utf8), decoder = JSONDecoder()
            func declared<T: Codable>(_ type: T.Type) -> T? {
                guard let row = try? decoder.decode(type, from: data), let canonical = try? JSONEncoder().encode(row),
                      let original = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let encoded = (try? JSONSerialization.jsonObject(with: canonical)) as? [String: Any],
                      Set(original.keys) == Set(encoded.keys) else { return nil }
                return row
            }
            if key.hasPrefix("h:") { return declared(Habit.self).map { $0.feature.utf8.count <= 1000 && $0.shown.count <= 16 && ($0.opinion?.count ?? 0) <= 100 } ?? false }
            if key.hasPrefix("short:") { return declared(Recent.self).map { $0.names.count <= 10 && $0.summary.count <= 60 && ($0.opinion?.count ?? 0) <= 100 } ?? false }
            if key.hasPrefix("a:") { return declared(FileDropAssignment.self).map { $0.seen.isEmpty && $0.label.count <= 100 } ?? false }
            return declared(Custom.self).map { $0.instruction.count <= 100 && $0.feature.utf8.count <= 1000 } ?? false
        }
    }
    func begin(id: String, feature: String, engine: String, names: [String], shown: [String], profile: String, now: Double = Date().timeIntervalSince1970) {
        if let current, current != id { close(now: now) }
        current = id
        var row = decode(store.entries["h:" + id], as: Habit.self) ?? Habit(at: now, feature: feature, engine: engine, shown: [], profile: profile)
        row.feature = feature; row.profile = profile; row.first = shown.first; row.shown = Array(Set(row.shown + shown)).sorted()
        put("h:" + id, row, now: now)
        var recent = decode(store.entries["short:" + id], as: Recent.self) ?? Recent(at: now, feature: feature, names: [], summary: "", profile: profile)
        recent.names = Array(names.prefix(10)); recent.feature = feature; recent.profile = profile
        put("short:" + id, recent, now: now)
    }
    func answer(summary: String, shown: [String], elapsed: Double, failed: Bool, works: [String], now: Double = Date().timeIntervalSince1970) {
        guard let id = current, var row = decode(store.entries["h:" + id], as: Habit.self) else { return }
        row.first = shown.first; row.shown = Array(Set(row.shown + shown)).sorted(); row.elapsed = elapsed; row.failed = failed
        put("h:" + id, row, now: now)
        if var recent = decode(store.entries["short:" + id], as: Recent.self) {
            recent.summary = String(summary.prefix(60)); recent.works = Array(works.prefix(5)); put("short:" + id, recent, now: now)
        }
    }
    func select(_ action: String, opinion: String? = nil, profile: String, now: Double = Date().timeIntervalSince1970) {
        guard let id = current, var row = decode(store.entries["h:" + id], as: Habit.self) else { return }
        row.chosen = action; row.opinion = opinion.map { String($0.prefix(100)) }; if profile != "app" { row.profile = profile }; row.closed = false
        put("h:" + id, row, now: now)
        if var recent = decode(store.entries["short:" + id], as: Recent.self) {
            recent.action = action; recent.opinion = row.opinion; if profile != "app" { recent.profile = profile }; put("short:" + id, recent, now: now)
        }
    }
    func close(now: Double = Date().timeIntervalSince1970) {
        guard let id = current else { return }; current = nil
        if var row = decode(store.entries["h:" + id], as: Habit.self), row.chosen == nil { row.closed = true; put("h:" + id, row, now: now) }
    }
    func recent(now: Double = Date().timeIntervalSince1970) -> [Recent] {
        rows("short:", as: Recent.self).map(\.1).filter { now - $0.at <= 48 * 3600 && $0.at <= now }.sorted { $0.at > $1.at }.prefix(20).map { $0 }
    }
    struct Counts { var seen = 0, chosen = 0, ignored = 0, corrected = 0 }
    func counters(feature: String) -> [String: Counts] {
        var values: [String: Counts] = [:]
        for (_, row) in rows("h:", as: Habit.self) where row.at > cutoff && row.feature == feature {
            for action in row.shown {
                values[action, default: Counts()].seen += 1
                if row.chosen == action { values[action, default: Counts()].chosen += 1 }
                else if row.chosen != nil || row.closed { values[action, default: Counts()].ignored += 1 }
            }
            if let result = row.result, !["closed", "asking"].contains(result), result != row.chosen { values[result, default: Counts()].corrected += 1 }
        }
        return values
    }
    func habits(feature: String) -> [String: Int] { counters(feature: feature).mapValues(\.chosen) }
    func customs(feature: String) -> [String] {
        rows("c:", as: Custom.self).filter { store.entries[$0.0]!.at > cutoff && $0.1.feature == feature }.map { $0.1.instruction }
    }
    func comparisons() -> [Comparison] {
        ["claude"].map { engine in
            var result = Comparison(engine: engine)
            for (_, row) in rows("h:", as: Habit.self) where row.at > cutoff && row.engine == engine {
                result.cards += 1; if row.closed { result.closed += 1 }; if row.failed { result.failures += 1 }
                if let elapsed = row.elapsed, elapsed.isFinite { result.latencies.append(elapsed) }
                switch row.chosen {
                case "auto": result.auto += 1
                case "opinion": result.opinion += 1
                case "custom_instruction": result.custom += 1
                case nil: break
                default:
                    // Display order is kept separately from the set used by learning counters.
                    if row.chosen == row.first { result.first += 1 } else { result.other += 1 }
                }
            }
            return result
        }
    }
    func saveAssignments(_ assignments: [FileDropAssignment], now: Double = Date().timeIntervalSince1970) {
        for var row in assignments {
            for seen in row.seen {
                let key = "seen:" + row.id + ":" + seen
                if store.entries[key]?.v != "1" { publish([key: SyncEntry(v: "1", at: now, by: device)]) }
            }
            if let event = row.event, let result = row.outcome { outcome(event: event, result: result, now: now) }
            row.seen = []; row.label = String(row.label.prefix(100)); put("a:" + row.id, row, now: now)
        }
        expire(now: now)
    }
    func outcome(event: String, result: String, now: Double = Date().timeIntervalSince1970) {
        if var row = decode(store.entries["h:" + event], as: Habit.self), row.result == nil || ["closed", "asking"].contains(row.result!) || !["closed", "asking"].contains(result) {
            row.result = result; put("h:" + event, row, now: now)
        }
        if var row = decode(store.entries["short:" + event], as: Recent.self), row.result == nil || ["closed", "asking"].contains(row.result!) || !["closed", "asking"].contains(result) {
            row.result = result; put("short:" + event, row, now: now)
        }
    }
    func assignments(now: Double = Date().timeIntervalSince1970) -> [FileDropAssignment] {
        rows("a:", as: FileDropAssignment.self).compactMap { _, value in
            guard now - value.at <= 48 * 3600 else { return nil }; var value = value
            let prefix = "seen:" + value.id + ":"
            value.seen = Set(store.entries.keys.filter { $0.hasPrefix(prefix) && store.entries[$0]?.v != nil }.map { String($0.dropFirst(prefix.count)) })
            return value
        }
    }
    func clear(now: Double = Date().timeIntervalSince1970) {
        publish(["clear": SyncEntry(v: "1", at: now, by: device)]); expire(now: now)
    }
    func expire(now: Double) {
        var removed: [String: SyncEntry] = [:]
        for (key, row) in rows("h:", as: Habit.self) {
            if row.at <= cutoff { removed[key] = SyncEntry(v: nil, at: now, by: device) }
            else if now - row.at > 90 * 86400 && row.opinion != nil { var row = row; row.opinion = nil; put(key, row, now: now) }
        }
        for (key, row) in rows("short:", as: Recent.self) where now - row.at > 7 * 86400 { removed[key] = SyncEntry(v: nil, at: now, by: device) }
        for (key, row) in rows("a:", as: FileDropAssignment.self) where now - row.at > 48 * 3600 {
            removed[key] = SyncEntry(v: nil, at: now, by: device)
            for name in store.entries.keys where name.hasPrefix("seen:" + row.id + ":") { removed[name] = SyncEntry(v: nil, at: now, by: device) }
        }
        for (key, _) in rows("c:", as: Custom.self) where store.entries[key]!.at <= cutoff { removed[key] = SyncEntry(v: nil, at: now, by: device) }
        if !removed.isEmpty { publish(removed) }
    }
}
