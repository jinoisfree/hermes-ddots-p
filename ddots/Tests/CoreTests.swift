import Foundation

@main
struct CoreTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed += 1
    }
    static func record(_ type: String, _ payload: [String: Any], at date: Date) -> [String: Any] {
        ["type": type, "timestamp": Dates.fractional.string(from: date), "payload": payload]
    }
    static func line(_ value: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: value); data.append(10); return data
    }
    static func main() throws {
        let now = Date().addingTimeInterval(-20)
        var codex = TranscriptDecoder(provider: .codex, sessionID: "one")
        _ = codex.consume(record("session_meta", ["id": "one", "cwd": "/work/project"], at: now))
        check(codex.consume(record("event_msg", ["type": "task_started", "turn_id": "turn1"], at: now))?.state == .running, "Codex start")
        check(codex.consume(record("event_msg", ["type": "task_complete", "turn_id": "old"], at: now)) == nil, "mismatched completion ignored")
        check(codex.consume(record("response_item", ["type": "function_call", "name": "request_user_input"], at: now))?.state == .waiting, "Codex input")
        check(codex.consume(record("response_item", ["type": "function_call_output"], at: now))?.state == .running, "Codex resumed")
        let completed = codex.consume(record("event_msg", ["type": "task_complete", "turn_id": "turn1", "last_agent_message": "PRIVATE"], at: now))!
        check(completed.state == .responded && completed.project == "project", "completion is response, not success")
        check(codex.consume(record("response_item", ["type": "reasoning"], at: now)) == nil, "finished turn not revived")
        check(codex.consume(record("token_usage_record", ["type": "usage"], at: now)) == nil, "usage is not work")
        _ = codex.consume(record("event_msg", ["type": "task_started", "turn_id": "turn2"], at: now.addingTimeInterval(1)))
        check(codex.consume(record("event_msg", ["type": "turn_aborted", "turn_id": "turn2"], at: now.addingTimeInterval(2)))?.state == .interrupted, "interrupted distinct from completion")
        var child = TranscriptDecoder(provider: .codex, sessionID: "child")
        _ = child.consume(record("session_meta", ["id": "child", "parent_thread_id": "one"], at: now))
        check(child.consume(record("event_msg", ["type": "task_started", "turn_id": "t"], at: now)) == nil, "subagent not counted as separate parent")

        var claude = TranscriptDecoder(provider: .claude, sessionID: "two")
        func claudeRecord(_ type: String, _ message: [String: Any], extra: [String: Any] = [:]) -> [String: Any] {
            var result: [String: Any] = ["type": type, "sessionId": "two", "promptId": "p1", "timestamp": Dates.fractional.string(from: now), "message": message, "cwd": "/work/project"]
            result.merge(extra) { _, new in new }; return result
        }
        check(claude.consume(claudeRecord("user", ["content": "SECRET PROMPT"]))?.state == .running, "Claude prompt")
        check(claude.consume(claudeRecord("assistant", ["content": [["type": "tool_use", "name": "Bash"]], "stop_reason": "tool_use"]))?.state == .running, "tool use not completion")
        check(claude.consume(claudeRecord("assistant", ["content": [["type": "tool_use", "name": "AskUserQuestion"]]]))?.state == .waiting, "Claude input wait")
        check(claude.consume(claudeRecord("user", ["content": [["type": "tool_result"]]]))?.turnID == "p1", "tool result retains turn")
        check(claude.consume(claudeRecord("assistant", ["content": [["type": "thinking"]], "stop_reason": "end_turn"]))?.state == .running, "thinking block not final response")
        check(claude.consume(claudeRecord("assistant", ["content": [["type": "text", "text": "PRIVATE"]], "stop_reason": "end_turn"]))?.state == .responded, "Claude response end")
        check(claude.consume(claudeRecord("assistant", [:], extra: ["isApiErrorMessage": true]))?.state == .failed, "API error distinct")
        check(claude.consume(claudeRecord("user", ["content": "injected"], extra: ["isMeta": true])) == nil, "meta not user work")
        check(claude.consume(claudeRecord("user", ["content": "subagent"], extra: ["isSidechain": true])) == nil, "sidechain ignored")
        check(claude.consume(["type": "cost-state", "totalCostUSD": 10]) == nil, "cost update not work")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("one.jsonl")
        let start = line(record("event_msg", ["type": "task_started", "turn_id": "one"], at: now))
        try start.dropLast(3).write(to: path)
        let tail = TranscriptTail(url: path, provider: .codex)
        check(tail.read().isEmpty, "partial line held")
        let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd(); try handle.write(contentsOf: start.suffix(3)); try handle.close()
        check(tail.read().count == 1, "partial line completed once")
        check(tail.read().isEmpty, "no duplicate on reread")
        try line(record("event_msg", ["type": "task_complete", "turn_id": "one"], at: now)).write(to: path, options: .atomic)
        check(tail.read().last?.state == .responded, "rotation reload")
        try Data("not-json\n".utf8).write(to: path, options: .atomic)
        check(tail.read().isEmpty && tail.lastError == nil, "malformed record skipped")
        try FileManager.default.removeItem(at: path)
        check(tail.read().isEmpty && tail.lastError != nil, "missing file reported")

        var active = completed; active.state = .running
        check(active.effective(at: now.addingTimeInterval(301)).state == .unknown, "stale running not success")
        check(completed.effective(at: now.addingTimeInterval(301)).state == .responded, "terminal preserved")
        let monitor = StatusMonitor(codexRoot: root.appendingPathComponent("absent"), claudeRoot: root.appendingPathComponent("absent2"), eventRoot: root.appendingPathComponent("absent3"))
        monitor.merge(completed)
        var older = completed; older.updatedAt = now.addingTimeInterval(-1); older.state = .running; monitor.merge(older)
        let snapshot = monitor.poll(now: now)
        check(snapshot.tasks.first?.state == .responded, "out of order event rejected")
        check(snapshot.connections.allSatisfy { !$0.available }, "missing connection not zero success")
        // A build being put through its UI checks, like the conversation share, is not a pet in the installed one's way
        check(AppIdentity.isPet(["ddots"]) && !AppIdentity.isPet(["ddots", "--relay", "--relay-port", "47810"]) && !AppIdentity.isPet(["ddots", "--ui-smoke", "/tmp/out", "--ui-smoke-chat"]), "only a real pet counts as another pet")
        // A hook's event file is taken away a day after its last change
        let events = root.appendingPathComponent("hook-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: events.appendingPathComponent("fresh.json")); try Data("{}".utf8).write(to: events.appendingPathComponent("stale.json"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-StatusMonitor.eventLife - 60)], ofItemAtPath: events.appendingPathComponent("stale.json").path)
        _ = StatusMonitor(codexRoot: root.appendingPathComponent("absent"), claudeRoot: root.appendingPathComponent("absent2"), eventRoot: events).poll(now: Date())
        check(FileManager.default.fileExists(atPath: events.appendingPathComponent("fresh.json").path) && !FileManager.default.fileExists(atPath: events.appendingPathComponent("stale.json").path), "a day-old event file is removed, a newer one is kept")
        var other = completed; other.provider = .claude; monitor.merge(other)
        check(monitor.poll(now: now).tasks.count == 2, "provider namespace isolation")
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!
        check(!encoded.contains("PRIVATE") && !encoded.contains("SECRET"), "no transcript body in snapshot")

        let payload: [String: Any] = ["session_id": "hook1", "hook_event_name": "PermissionRequest", "cwd": "/x/project", "tool_input": ["secret": "PRIVATE"]]
        let hook = HookBridge.item(provider: .claude, payload: payload, now: now)!
        check(hook.state == .waiting && hook.source == "공식 훅", "permission hook")
        check(HookBridge.item(provider: .claude, payload: ["session_id": "x", "hook_event_name": "Notification", "notification_type": "auth_success"]) == nil, "irrelevant hook ignored")
        check(HookBridge.item(provider: .claude, payload: ["session_id": "x", "hook_event_name": "Stop", "background_tasks": [["id": "b"]]])?.state == .running, "background work not marked done")
        check(HookBridge.decodeEvent(["version": 99]) == nil, "unknown event version rejected")

        var attention = ComputerUseActivity()
        attention.start(name: "functions.exec", id: "shell", at: now)
        check(attention.expiresAt(now: now) == nil, "terminal is not computer use")
        attention.start(name: "mcp__cua_repl.js", id: "screen", at: now)
        attention.start(name: "computer", id: "screen2", at: now)
        attention.finish(id: "unrelated", at: now)
        check(attention.expiresAt(now: now) != nil, "screen tool pending")
        attention.finish(id: "screen", at: now)
        check(attention.expiresAt(now: now.addingTimeInterval(4)) != nil, "parallel screen call remains active")
        attention.finish(id: "screen2", at: now)
        check(attention.expiresAt(now: now.addingTimeInterval(4)) == nil, "screen activity ends after short grace")
        attention.start(name: "computer", id: "lost", at: now)
        check(attention.expiresAt(now: now.addingTimeInterval(61)) == nil, "missing output expires")
        attention.reset()
        attention.start(name: "computer", id: "old", at: now)
        attention.start(name: "computer", id: "new", at: now.addingTimeInterval(1))
        attention.finish(id: "new", at: now.addingTimeInterval(2), output: "Window: \"New\", App: B.")
        attention.finish(id: "old", at: now.addingTimeInterval(3), output: "Window: \"Old\", App: A.")
        check(attention.target?.appName == "B", "late earlier call cannot replace newer window metadata")
        attention.start(name: "computer", id: "ambiguous", at: now.addingTimeInterval(4))
        attention.finish(id: "ambiguous", at: now.addingTimeInterval(5), output: "Window: \"A\", App: A.\nWindow: \"B\", App: B.")
        check(attention.target == nil, "ambiguous observation clears previous target")

        var screenCodex = TranscriptDecoder(provider: .codex, sessionID: "screen-session")
        let screenCall = record("response_item", ["type": "function_call", "namespace": "mcp__cua_repl", "name": "js", "call_id": "cua1", "arguments": "PRIVATE"], at: now)
        _ = screenCodex.consume(screenCall)
        check(screenCodex.computerUse.expiresAt(now: now) != nil, "Codex screen tool detected")
        _ = screenCodex.consume(record("response_item", ["type": "function_call_output", "call_id": "cua1"], at: now))
        check(screenCodex.computerUse.expiresAt(now: now.addingTimeInterval(4)) == nil, "Codex output closes matching call")
        _ = screenCodex.consume(screenCall)
        _ = screenCodex.consume(record("event_msg", ["type": "task_complete"], at: now))
        check(screenCodex.computerUse.expiresAt(now: now) == nil, "completed task clears screen attention")
        _ = screenCodex.consume(screenCall)
        check(screenCodex.computerUse.expiresAt(now: now) == nil, "completed task ignores late screen calls")

        var screenClaude = TranscriptDecoder(provider: .claude, sessionID: "screen-claude")
        _ = screenClaude.consume(claudeRecord("assistant", ["content": [["type": "tool_use", "name": "computer", "id": "screenC"]]]))
        check(screenClaude.computerUse.expiresAt(now: now) != nil, "Claude computer use detected")
        _ = screenClaude.consume(claudeRecord("user", ["content": [["type": "tool_result", "tool_use_id": "screenC"]]]))
        check(screenClaude.computerUse.expiresAt(now: now.addingTimeInterval(4)) == nil, "Claude tool result closes matching call")

        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try line(screenCall).write(to: sessions.appendingPathComponent("screen-session.jsonl"))
        let screenMonitor = StatusMonitor(codexRoot: root, claudeRoot: root.appendingPathComponent("no-claude"), eventRoot: root.appendingPathComponent("no-hooks"))
        let screenSnapshot = screenMonitor.poll(now: now)
        check(screenSnapshot.screenUseUntil != nil, "screen activity reaches UI snapshot")
        let screenEncoded = String(data: try JSONEncoder().encode(screenSnapshot), encoding: .utf8)!
        check(!screenEncoded.contains("PRIVATE"), "screen arguments not retained")

        var stale = completed; stale.state = .responded; stale.updatedAt = now.addingTimeInterval(-300)
        check(PetTaskSummary.animationState(stale, at: now) == .idle, "selected five-minute response must not keep waving")
        stale.updatedAt = now.addingTimeInterval(-19)
        check(PetTaskSummary.animationState(stale, at: now) == .responded, "fresh selected response waves")
        stale.updatedAt = now.addingTimeInterval(-20)
        check(PetTaskSummary.animationState(stale, at: now) == .idle, "selected response expires at twenty seconds")
        stale.state = .waiting
        check(PetTaskSummary.animationState(stale, at: now) == .waiting, "approval waiting is preserved")
        var runningCodex = completed; runningCodex.state = .running
        var runningClaude = runningCodex; runningClaude.provider = .claude
        check(PetTaskSummary.runningHeadline([runningClaude, runningCodex]) == "Codex · Claude Code · 작업 중", "both AI names shown in bubble")
        check(PetTaskSummary.runningHeadline([runningCodex, runningCodex]) == "Codex · 2개 작업 중", "same provider groups task count")
        check(PetTaskSummary.runningHeadline([runningClaude, completed]) == nil, "finished AI excluded from running summary")
        check(PetTaskSummary.runningDetail([runningClaude, runningCodex]) == "Codex 1 · Claude Code 1", "urgent bubble still lists running AI names")

        let codexDir = root.appendingPathComponent("focus-codex"), claudeDir = root.appendingPathComponent("focus-claude")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let codexPath = codexDir.appendingPathComponent("owner-codex.jsonl"), claudePath = claudeDir.appendingPathComponent("owner-claude.jsonl")
        func append(_ record: [String: Any], to path: URL) throws {
            let file = try FileHandle(forWritingTo: path); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: line(record))
        }
        func cr(_ type: String, _ content: Any, _ date: Date, reason: String? = nil) -> [String: Any] {
            var message: [String: Any] = ["content": content]
            if let reason { message["stop_reason"] = reason }
            return ["type": type, "sessionId": "owner-claude", "uuid": "claude-turn", "timestamp": Dates.fractional.string(from: date), "message": message]
        }
        try line(record("event_msg", ["type": "task_started", "turn_id": "codex-turn"], at: now.addingTimeInterval(-100))).write(to: codexPath)
        try append(screenCall, to: codexPath)
        try append(record("response_item", ["type": "function_call_output", "call_id": "cua1", "output": [["type": "input_text", "text": "Window: \"Work\", App: ddots.\nPRIVATE BODY"]]], at: now), to: codexPath)
        try line(cr("user", "PRIVATE PROMPT", now.addingTimeInterval(-50))).write(to: claudePath)
        try append(cr("assistant", [["type": "tool_use", "name": "computer", "id": "claude-screen"]], now.addingTimeInterval(-1)), to: claudePath)
        let focusMonitor = StatusMonitor(codexRoot: codexDir, claudeRoot: claudeDir, eventRoot: root.appendingPathComponent("no-hooks"))
        let firstFocus = focusMonitor.poll(now: now)
        check(firstFocus.screenFocus?.provider == .codex, "monitor selects older overall task even when Claude began screen use first")
        check(abs(firstFocus.screenFocus!.taskStartedAt!.timeIntervalSince(now.addingTimeInterval(-100))) < 0.01, "task start survives screen output updates")
        check(firstFocus.screenFocus?.target?.appName == "ddots", "matched screen output metadata reaches snapshot")
        let focusEncoded = String(data: try JSONEncoder().encode(firstFocus), encoding: .utf8)!
        check(!focusEncoded.contains("PRIVATE"), "focus metadata excludes prompt and observation body")
        try append(cr("assistant", [["type": "tool_use", "name": "computer", "id": "claude-screen2"]], now.addingTimeInterval(1)), to: claudePath)
        check(focusMonitor.poll(now: now.addingTimeInterval(1)).screenFocus?.provider == .codex, "newer screen events do not steal older task priority")
        try append(record("event_msg", ["type": "task_complete", "turn_id": "codex-turn"], at: now.addingTimeInterval(2)), to: codexPath)
        check(focusMonitor.poll(now: now.addingTimeInterval(2)).screenFocus?.provider == .claude, "completion hands focus to next active AI")
        try append(record("event_msg", ["type": "task_started", "turn_id": "codex-next"], at: now.addingTimeInterval(3)), to: codexPath)
        try append(record("response_item", ["type": "function_call", "name": "computer", "call_id": "new-codex-screen"], at: now.addingTimeInterval(3)), to: codexPath)
        check(focusMonitor.poll(now: now.addingTimeInterval(3)).screenFocus?.provider == .claude, "reused Codex session gets a new task start")
        try append(cr("assistant", [["type": "text", "text": "PRIVATE RESPONSE"]], now.addingTimeInterval(4), reason: "end_turn"), to: claudePath)
        check(focusMonitor.poll(now: now.addingTimeInterval(4)).screenFocus?.provider == .codex, "Claude end_turn releases focus")
        check(focusMonitor.poll(now: now.addingTimeInterval(64)).screenFocus == nil, "lost result expires rather than holding focus forever")
        print("PASS: \(passed) checks")
    }
}
