import Foundation

@main struct UsageTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func snapshot(_ windows: [UsageWindow], age: Double = 0, maxAge: Double = 900) -> ServiceUsage {
            ServiceUsage(observedAt: now.addingTimeInterval(-age), maxAge: maxAge, windows: windows)
        }
        check(UsageText.subtitle(codex: "—", claude: "—") == "Codex — · Claude Code —", "unknown service labels")
        check(UsageText.subtitle(codex: "주 100%", claude: "주 100%") == "Codex 주 100%·Claude Code 주 100%", "longest labels fit by compacting separator")
        let short = UsageWindow(weekly: false, usedPercent: 28)
        let week = UsageWindow(weekly: true, usedPercent: 52)
        check(snapshot([short, week]).label(now: now) == "주 48%", "least remaining weekly window")
        check(snapshot([short]).label(now: now) == "72%", "five hour label")
        check(snapshot([UsageWindow(weekly: false, usedPercent: 28.1)]).label(now: now) == "71%", "round usage upward")
        check(snapshot([short, UsageWindow(weekly: true, usedPercent: 99, resetAt: now)]).label(now: now) == "72%", "expired window excluded")
        check(snapshot([UsageWindow(weekly: true, usedPercent: 99, resetAt: now)]).label(now: now) == "—", "all expired")
        for maxAge in [900.0, 300, 1800, 3600] {
            check(snapshot([short], age: maxAge + 1, maxAge: maxAge).label(now: now) == "—", "stale observation \(maxAge)")
            check(snapshot([short], age: maxAge, maxAge: maxAge).label(now: now) == "72%", "fresh boundary")
        }
        check(snapshot([]).label(now: now) == "—", "no windows")
        check(snapshot([UsageWindow(weekly: false, usedPercent: .nan)]).label(now: now) == "—", "invalid percentage")
        func data(_ text: String) -> Data { Data(text.utf8) }
        check(UsageParser.percent(true) == nil && UsageParser.percent(101) == nil, "reject booleans and out of range")
        func paseoData(windows: [[String: Any]], providerID: String = "codex-paseo", status: String = "available",
                       fetched: String = "2033-05-18T03:33:20Z", type: String = "provider.usage.list.response",
                       additionalProviders: [[String: Any]] = []) -> Data {
            let providers: [[String: Any]] = [
                ["providerId": providerID, "status": status, "windows": windows],
                ["providerId": "claude", "status": status, "windows": windows]] + additionalProviders
            return try! JSONSerialization.data(withJSONObject: ["type": "session", "message": ["type": type, "payload": [
                "fetchedAt": fetched, "requestId": "synthetic", "providers": providers]]])
        }
        let paseoWindows: [[String: Any]] = [
            ["id": "five_hour", "usedPct": 28, "resetsAt": "2033-05-18T19:20:00.246387+00:00"],
            ["id": "weekly", "usedPct": 52, "resetsAt": "2033-05-20T02:00:00+00:00"],
            ["id": "weekly", "usedPct": 51, "resetsAt": "2033-05-20T13:37:57.000Z"],
            ["id": "weekly_model_fable", "usedPct": 99]]
        let paseo = UsageParser.paseo(paseoData(windows: paseoWindows), now: now)
        check(paseo?.codex?.windows.count == 3 && paseo?.claude?.windows.count == 3, "Paseo three ISO formats and ignores model limits")
        check(paseo?.codex?.windows.allSatisfy { $0.resetAt != nil } == true, "Paseo dates parsed")
        check(paseo?.codex?.observedAt == now && paseo?.codex?.maxAge == 3600, "Paseo preserves fetchedAt and sixty minute age")
        check(paseo?.codex?.label(now: now) == "주 48%", "Paseo least remaining supported window")
        check(paseo?.claude?.label(now: now) == "주 48%", "Claude ignores model windows when calculating label")
        let legacy = UsageParser.paseo(paseoData(windows: paseoWindows, providerID: "codex"), now: now)
        check(legacy?.codex?.label(now: now) == "주 48%", "legacy codex provider is supported")
        let preferredProvider: [String: Any] = ["providerId": "codex-paseo", "status": "available",
                                                "windows": [["id": "five_hour", "usedPct": 10]]]
        let both = UsageParser.paseo(paseoData(windows: paseoWindows, providerID: "codex", additionalProviders: [preferredProvider]), now: now)
        check(both?.codex?.label(now: now) == "90%", "codex-paseo takes priority even after legacy codex")
        let legacyProvider: [String: Any] = ["providerId": "codex", "status": "available", "windows": paseoWindows]
        for status in ["unavailable", "error"] {
            let value = UsageParser.paseo(paseoData(windows: [], status: status, additionalProviders: [legacyProvider]), now: now)
            check(value?.codex?.label(now: now) == "주 48%", "unavailable codex-paseo allows legacy codex")
        }
        let modelOnly = UsageParser.paseo(paseoData(windows: [["id": "weekly_model_fable", "usedPct": 99]]), now: now)
        check(modelOnly?.codex?.label(now: now) == "—" && modelOnly?.claude?.label(now: now) == "—", "model windows alone do not provide usage")
        check(paseo?.claude?.label(now: now.addingTimeInterval(3601)) == "—", "Paseo stale cache expires")
        check(UsageParser.paseo(paseoData(windows: paseoWindows, fetched: "bad")) == nil, "Paseo rejects invalid fetchedAt")
        for status in ["unavailable", "error"] {
            let value = UsageParser.paseo(paseoData(windows: paseoWindows, status: status))
            check(value?.codex == nil && value?.claude == nil, "Paseo ignores unavailable provider")
        }
        let invalid: [[String: Any]] = [
            ["id": "five_hour", "usedPct": -1], ["id": "weekly", "usedPct": 101],
            ["id": "weekly", "usedPct": NSNull()], ["id": "weekly", "usedPct": true],
            ["id": "weekly", "usedPct": 22, "resetsAt": "bad"],
            ["id": "weekly", "usedPct": 22, "resetsAt": 123],
            ["id": "balance", "usedPct": 99]]
        check(UsageParser.paseo(paseoData(windows: invalid))?.codex?.windows.isEmpty == true, "Paseo rejects invalid percentages dates and unknown windows")
        for type in ["agent_stream", "server_info", "provider.usage.other"] {
            check(UsageParser.paseo(paseoData(windows: paseoWindows, type: type)) == nil, "Paseo rejects other messages")
        }
        check(UsageParser.paseo(data(#"{"type":"status"}"#)) == nil, "Paseo rejects outer status")
        for listen in ["127.0.0.1:6767", "localhost:6767", "[::1]:6767"] {
            check(UsageSources.paseoURL(listen: listen)?.path == "/ws", "loopback address allowed")
        }
        for listen in ["example.com:6767", "192.168.0.1:6767", "127.0.0.1.example.com:6767", "user@localhost:6767", "localhost:6767/path", "localhost:6767?x=y", "localhost:0", "localhost:99999", "localhost"] {
            check(UsageSources.paseoURL(listen: listen) == nil, "non-loopback or malformed address rejected")
        }
        let retained = ServiceUsage(observedAt: now, maxAge: 3600, windows: [short])
        let replacement = ServiceUsage(observedAt: now.addingTimeInterval(20), maxAge: 3600, windows: [week])
        check(UsageRetention.next(previous: nil, incoming: nil) == nil, "missing observations remain unknown")
        check(UsageRetention.next(previous: nil, incoming: retained)?.label(now: now) == "72%", "first Paseo observation")
        check(UsageRetention.next(previous: retained, incoming: nil)?.observedAt == now, "Paseo failure preserves observation without freshening it")
        check(UsageRetention.next(previous: retained, incoming: replacement)?.label(now: now.addingTimeInterval(20)) == "주 48%", "success replaces previous value")
        check(retained.label(now: now.addingTimeInterval(3600)) == "72%" && retained.label(now: now.addingTimeInterval(3601)) == "—", "retention expires after sixty minutes")
        let resetting = ServiceUsage(observedAt: now, maxAge: 3600, windows: [UsageWindow(weekly: false, usedPercent: 28, resetAt: now.addingTimeInterval(60))])
        check(resetting.label(now: now.addingTimeInterval(60)) == "—", "reset wins over retention")
        let zone = TimeZone(secondsFromGMT: 0)!
        func status(at: Date? = now, ok: Bool = true, codex: String = "—", claude: String = "—", timeZone: TimeZone = zone) -> String {
            UsageText.paseoStatus(at: at, ok: ok, codex: codex, claude: claude, timeZone: timeZone)
        }
        check(status(at: nil, ok: false) == "Paseo 조회 대기 중", "pending Paseo status")
        check(status(codex: "72%", claude: "주 48%") == "Paseo 사용 중 · 마지막 조회 03:33", "both services available status")
        check(status(codex: "72%") == "Paseo 일부만 조회됨 · 마지막 조회 03:33", "only Codex available status")
        check(status(claude: "주 48%") == "Paseo 일부만 조회됨 · 마지막 조회 03:33", "only Claude available status")
        check(status() == "Paseo 사용량 없음 · Paseo 앱 확인", "no usable service status")
        check(status(ok: false) == "Paseo 조회 실패 · 마지막 조회 03:33", "failed without previous values status")
        for labels in [("72%", "—"), ("—", "주 48%"), ("72%", "주 48%")] {
            check(status(ok: false, codex: labels.0, claude: labels.1) == "Paseo 조회 실패 · 마지막 조회 03:33 · 이전 값 표시", "failure takes priority while retaining either service")
        }
        check(status(codex: "72%", claude: "주 48%", timeZone: TimeZone(secondsFromGMT: 9 * 3600)!) == "Paseo 사용 중 · 마지막 조회 12:33", "status respects time zone")
        check(status(ok: false, codex: retained.label(now: now.addingTimeInterval(3601))) == "Paseo 조회 실패 · 마지막 조회 03:33", "expired value is not claimed visible")
        let fixture = UsageMonitor()
        fixture.fixture = true
        fixture.tick(paused: false, smoke: true)
        check(fixture.paseoStatus == "Paseo 사용 중", "fixture Paseo status")
        check(fixture.subtitle == "Codex 72% · Claude Code 주 48%", "fixture subtitle unchanged")
        print("UsageTests: \(failures == 0 ? "PASS" : "FAIL")")
        if failures > 0 { exit(1) }
    }
}
