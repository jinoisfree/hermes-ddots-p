import Foundation

@main struct FileDropHistoryTests {
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FAIL \(name)\n", stderr); exit(1) }; print("PASS \(name)")
    }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("drop-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        func history(_ folder: String, _ device: String) -> FileDropHistory {
            FileDropHistory(store: SettingsStore(user: "SYNTHETIC", folder: base.appendingPathComponent(folder))!, device: device)
        }
        let a = history("a", "A"), b = history("b", "B"), mini = history("mini", "mini")
        let feature = "pdf|synthetic.app|~/Downloads|example.invalid"
        for index in 0..<3 {
            a.begin(id: "a\(index)", feature: feature, engine: "mac", names: ["SYNTHETIC_FILENAME.pdf"], shown: ["summarize", "compare", "explain"], profile: "work-assistant", now: 100 + Double(index))
            a.select("summarize", profile: "work-assistant", now: 100 + Double(index)); a.close(now: 100 + Double(index))
        }
        b.begin(id: "b", feature: feature, engine: "claude", names: ["B.pdf"], shown: ["summarize", "compare", "explain"], profile: "work-assistant", now: 110)
        b.select("compare", profile: "work-assistant", now: 110)
        mini.receive(a.store.entries, now: 200); mini.receive(b.store.entries, now: 200)
        a.receive(mini.store.entries, now: 200); b.receive(mini.store.entries, now: 200)
        check(a.habits(feature: feature) == ["summarize": 3, "compare": 1, "explain": 0] && b.habits(feature: feature) == a.habits(feature: feature), "AC-20 offline changes merge without lost increments on all Macs")
        check(a.counters(feature: feature)["summarize"]?.seen == 4 && a.counters(feature: feature)["summarize"]?.ignored == 1 && a.counters(feature: feature)["compare"]?.ignored == 3, "AC-26 chosen/unchosen/shown counters are independent")
        let table = history("table", "table")
        for engine in ["mac", "claude"] {
            for index in 0..<4 {
                table.begin(id: engine + String(index), feature: feature, engine: engine, names: [], shown: ["summarize", "compare", "explain"], profile: "work-assistant", now: 300 + Double(index))
                table.answer(summary: "SYNTHETIC_SUMMARY", shown: ["summarize", "compare", "explain"], elapsed: Double(index * 2 + 1), failed: index == 3, works: [], now: 300 + Double(index))
                if index < 3 { table.select(["summarize", "compare", "auto"][index], profile: "work-assistant", now: 300 + Double(index)) }
                table.close(now: 300 + Double(index))
            }
        }
        for row in table.comparisons() {
            check(row.cards == 4 && row.first == 1 && row.other == 1 && row.auto == 1 && row.closed == 1 && row.failures == 1 && row.median == 4, "AC-21 literal engine counts and even-sample median")
        }
        check(a.recent(now: 700).first?.names == ["B.pdf"] && a.recent(now: 49 * 3600).isEmpty, "AC-37 recent names are supplied only within 48 hours")
        let hText = a.store.entries.filter { $0.key.hasPrefix("h:") }.values.compactMap(\.v).joined()
        check(!hText.contains("SYNTHETIC_FILENAME") && !hText.contains("SYNTHETIC_SUMMARY"), "AC-19 names and summary are absent from long-term habits")
        var injected = try JSONSerialization.jsonObject(with: Data(a.store.entries["h:a0"]!.v!.utf8)) as! [String: Any]
        injected["content"] = "SYNTHETIC_RAW_DOCUMENT"
        let unknown = String(data: try JSONSerialization.data(withJSONObject: injected), encoding: .utf8)!
        check(FileDropHistory.valid(["h:injected": SyncEntry(v: unknown, at: 500, by: "A")]).isEmpty, "AC-19 relay refuses undeclared raw-content fields")
        var assignment = FileDropAssignment(id: "ASSIGNMENT", at: 100, room: "ROOM", ts: "1", files: [], profile: "work-assistant", label: "세 줄 요약")
        assignment.seen = ["A:closed"]; a.saveAssignments([assignment], now: 200)
        b.receive(a.store.entries, now: 200); assignment = b.assignments(now: 200)[0]; assignment.seen.insert("B:closed"); b.saveAssignments([assignment], now: 201)
        a.receive(b.store.entries, now: 202)
        let reopened = history("a", "A")
        check(reopened.assignments(now: 203).first?.seen == ["A:closed", "B:closed"], "AC-42/44 per-Mac seen states survive restart and merge independently")
        a.expire(now: 8 * 86400)
        check(a.recent(now: 8 * 86400).isEmpty && a.assignments(now: 8 * 86400).isEmpty && a.store.entries["short:a0"]?.v == nil, "48-hour watch and seven-day emergency expiry remove short-term records")
        let stale = b.store.entries
        b.clear(now: 1000); a.receive(b.store.entries, now: 1001); b.receive(stale, now: 1002)
        check(a.habits(feature: feature).isEmpty && b.habits(feature: feature).isEmpty, "clear tombstones prevent stale offline habits from returning")
    }
}
