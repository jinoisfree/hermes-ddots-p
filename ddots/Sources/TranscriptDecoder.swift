import Foundation

/// Only state metadata is extracted. Prompts, assistant text and tool arguments are not retained.
struct TranscriptDecoder {
    let provider: Provider
    var sessionID: String
    var project = ""
    var turnID = ""
    var excluded = false
    var last: WorkItem?
    var computerUse = ComputerUseActivity()
    private(set) var taskStartedAt: Date?
    private(set) var firstObservedAt: Date?

    func screenFocus(now: Date) -> ScreenFocus? {
        guard let last, last.state == .running, let firstObservedAt,
              let expiry = computerUse.expiresAt(now: now) else { return nil }
        return ScreenFocus(taskID: last.id, turnID: turnID, provider: provider,
                           taskStartedAt: taskStartedAt, firstObservedAt: firstObservedAt,
                           expiresAt: expiry, target: computerUse.target)
    }

    mutating func consume(_ object: [String: Any]) -> WorkItem? {
        if provider == .codex { return codex(object) }
        if provider == .claude { return claude(object) }
        return nil
    }

    private mutating func emit(_ state: WorkState, at date: Date, event: String) -> WorkItem? {
        guard !excluded, !sessionID.isEmpty, date.timeIntervalSinceNow < 60 else { return nil }
        if let last, date < last.updatedAt { return nil }
        if firstObservedAt == nil { firstObservedAt = date }
        if state != .running { computerUse.reset() }
        let item = WorkItem(provider: provider, sessionID: sessionID, turnID: turnID, project: project,
                            state: state, updatedAt: date, source: "로컬 기록", event: event)
        last = item
        return item
    }

    private mutating func codex(_ object: [String: Any]) -> WorkItem? {
        guard let kind = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { return nil }
        if kind == "session_meta" {
            sessionID = payload["id"] as? String ?? sessionID
            if let cwd = payload["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            excluded = payload["parent_thread_id"] != nil || (payload["source"] as? [String: Any])?["subagent"] != nil
            return nil
        }
        guard !excluded else { return nil }
        if kind == "turn_context" {
            if let incoming = payload["turn_id"] as? String, incoming != turnID {
                turnID = incoming; taskStartedAt = nil; firstObservedAt = nil; computerUse.reset(); last = nil
            }
            if let cwd = payload["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
            return nil
        }
        guard let date = Dates.parse(object["timestamp"]), let event = payload["type"] as? String else { return nil }
        guard date.timeIntervalSinceNow < 60, last == nil || date >= last!.updatedAt else { return nil }
        if kind == "event_msg" {
            if event == "task_started" {
                computerUse.reset()
                turnID = payload["turn_id"] as? String ?? ""
                taskStartedAt = date; firstObservedAt = date
                return emit(.running, at: date, event: event)
            }
            if ["task_complete", "turn_aborted", "error"].contains(event) {
                if let incoming = payload["turn_id"] as? String {
                    if !turnID.isEmpty && incoming != turnID { return nil }
                    turnID = incoming
                }
                return emit(event == "task_complete" ? .responded : event == "turn_aborted" ? .interrupted : .failed, at: date, event: event)
            }
        }
        // Activity refreshes an active turn; never revive an already finished turn from usage records.
        if kind == "response_item", last == nil || last?.state == .running || last?.state == .waiting {
            if event == "function_call" || event == "custom_tool_call" {
                let name = payload["name"] as? String ?? ""
                let namespace = payload["namespace"] as? String ?? ""
                let qualifiedName = namespace.isEmpty ? name : "\(namespace).\(name)"
                computerUse.start(name: qualifiedName, id: payload["call_id"] as? String ?? "", at: date)
                let waiting = name == "request_user_input" || name.hasSuffix(".request_user_input")
                return emit(waiting ? .waiting : .running, at: date, event: waiting ? "request_user_input" : "tool_call")
            }
            if ["reasoning", "function_call_output", "custom_tool_call_output"].contains(event) {
                if event != "reasoning" { computerUse.finish(id: payload["call_id"] as? String ?? "", at: date, output: payload["output"]) }
                return emit(.running, at: date, event: "activity")
            }
        }
        return nil
    }

    private mutating func claude(_ object: [String: Any]) -> WorkItem? {
        guard object["isSidechain"] as? Bool != true else { return nil }
        if let id = object["sessionId"] as? String { sessionID = id }
        if let cwd = object["cwd"] as? String { project = URL(fileURLWithPath: cwd).lastPathComponent }
        guard let kind = object["type"] as? String, let date = Dates.parse(object["timestamp"]) else { return nil }
        guard date.timeIntervalSinceNow < 60, last == nil || date >= last!.updatedAt else { return nil }
        let message = object["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? [[String: Any]] ?? []
        if kind == "user" {
            if content.contains(where: { $0["type"] as? String == "tool_result" }) {
                for block in content where block["type"] as? String == "tool_result" {
                    computerUse.finish(id: block["tool_use_id"] as? String ?? "", at: date, output: block["content"])
                }
                return emit(.running, at: date, event: "tool_result")
            }
            // Ignore injected context and system/meta messages masquerading as a user role.
            guard object["isMeta"] as? Bool != true,
                  object["userType"] as? String != "internal",
                  object["turnOrigin"] as? String != "agent" else { return nil }
            if message["content"] is String || content.contains(where: { $0["type"] as? String == "text" }) {
                computerUse.reset()
                turnID = object["promptId"] as? String ?? object["uuid"] as? String ?? ""
                taskStartedAt = date; firstObservedAt = date
                return emit(.running, at: date, event: "user_prompt")
            }
        }
        if kind == "assistant" {
            for block in content where block["type"] as? String == "tool_use" {
                computerUse.start(name: block["name"] as? String ?? "", id: block["id"] as? String ?? "", at: date)
            }
            if object["isApiErrorMessage"] as? Bool == true { return emit(.failed, at: date, event: "api_error") }
            if content.contains(where: { $0["type"] as? String == "tool_use" && ["AskUserQuestion", "ExitPlanMode"].contains($0["name"] as? String ?? "") }) {
                return emit(.waiting, at: date, event: "user_input_tool")
            }
            if message["stop_reason"] as? String == "end_turn", content.contains(where: { $0["type"] as? String == "text" }) {
                return emit(.responded, at: date, event: "end_turn")
            }
            return emit(.running, at: date, event: "assistant_activity")
        }
        if kind == "system", object["subtype"] as? String == "stop_hook_summary" {
            return emit(object["preventedContinuation"] as? Bool == true ? .running : .responded, at: date, event: "stop_hook_summary")
        }
        return nil
    }
}

/// Incremental JSONL reader with bounded memory, incomplete-line buffering and rotation detection.
final class TranscriptTail {
    let url: URL
    var decoder: TranscriptDecoder
    var offset: UInt64 = 0
    var inode: UInt64 = 0
    var pending = Data()
    var discardUntilNewline = false
    var lastError: String?
    let maxBytes = 2 * 1024 * 1024

    init(url: URL, provider: Provider) {
        self.url = url
        let base = url.deletingPathExtension().lastPathComponent
        decoder = TranscriptDecoder(provider: provider, sessionID: provider == .codex ? String(base.suffix(36)) : base)
    }

    func read() -> [WorkItem] {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if number != inode || size < offset {
                offset = 0; pending.removeAll(); discardUntilNewline = false
                decoder = TranscriptDecoder(provider: decoder.provider, sessionID: decoder.sessionID)
                inode = number
            }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            if offset == 0 && size > UInt64(maxBytes) {
                // Read a bounded header to identify subagents and the workspace before tailing.
                let prefix = try handle.read(upToCount: 256 * 1024) ?? Data()
                if let end = prefix.firstIndex(of: 10), let object = try? JSONSerialization.jsonObject(with: prefix[..<end]) as? [String: Any] { _ = decoder.consume(object) }
                offset = size - UInt64(maxBytes); discardUntilNewline = true
            }
            try handle.seek(toOffset: offset)
            let chunk = try handle.read(upToCount: maxBytes) ?? Data()
            offset += UInt64(chunk.count)
            pending.append(chunk)
            var items: [WorkItem] = []
            var start = pending.startIndex
            while let end = pending[start...].firstIndex(of: 10) {
                let line = pending[start..<end]
                if !discardUntilNewline, line.count <= maxBytes,
                   let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let item = decoder.consume(object) { items.append(item) }
                start = pending.index(after: end); discardUntilNewline = false
            }
            pending.removeSubrange(..<start)
            if pending.count > maxBytes { pending.removeAll(); discardUntilNewline = true }
            lastError = nil
            return items
        } catch {
            lastError = "기록 읽기 실패"; return []
        }
    }
}
