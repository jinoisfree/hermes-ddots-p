import AppKit

extension AppDelegate {
    /// `--ui-smoke-bubble-reply-live`: keeps the app alive with an all-local Slack double so that real pointer and key input from
    /// outside can drive the bubble's input. Commands arrive as files in `<out>/cmd`; every message the double receives is appended
    /// to `<out>/sent.jsonl`. No network, no real Slack, no real agent.
    @MainActor func verifyBubbleReplyLive(destination: URL) async {
        let out = destination, cmd = destination.appendingPathComponent("cmd")
        try? FileManager.default.createDirectory(at: cmd, withIntermediateDirectories: true)
        let script = SlackSendScript(workspace: "https://bubble-reply.invalid/")
        slack.persists = false; slack.store = SlackFileStore(root: out.appendingPathComponent("sent-files")); slack.smokeSends = true
        slack.start(script.api)
        // The made-up workspace is read for the chosen room only while the controller counts the conversation as open; the pet itself stays folded.
        for _ in 0..<250 {
            if slack.model.connected && !slack.model.loading && !slack.model.rooms.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        slack.model.selected = "CCOW"
        slack.chatOpen = true
        let roster: [(profile: String, name: String)] = [("work-x", "민트"), ("queue-z", "고객응대")]
        var held: DispatchSemaphore?
        var beat = 0
        // The made-up workspace holds an approval and fresh posts that would take the bubble; they are put aside until asked for.
        var quiet = true
        isPreview = false
        var writerProfile = "work-x"
        func wire() {
            slack.model.ddotsMembers = roster.map { .init(profile: $0.profile, name: $0.name, room: "D" + $0.profile) }
            for member in roster { slack.model.members["D" + member.profile] = [.init(profile: member.profile, name: member.name, user: "U" + member.profile)] }
            for room in ["CCOW", "CTRUTH"] { slack.model.members[room] = roster.map { .init(profile: $0.profile, name: $0.name, user: "U" + $0.profile) } }
        }
        func thread() -> SlackThread? {
            slack.snapshot.threads.values.flatMap { $0 }.first { $0.root.body.hasPrefix("내일 오전 일정") && !$0.ts.isEmpty }
        }
        func rect(_ view: NSView?, _ frame: CGRect) -> [Int] {
            guard let view, let window = view.window else { return [] }
            let r = window.convertToScreen(view.convert(frame, to: nil)); return [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
        }
        func snapshot() -> [String: Any] {
            let target = thread()
            let echoes = target.map { t in slack.model.threads.first { $0.id == t.id }?.messages.filter { $0.pending }.count ?? 0 } ?? 0
            return ["open": bubbleReply.open, "visible": bubbleReply.visible, "text": bubbleReply.text, "problem": bubbleReply.problem, "placeholder": bubbleReply.placeholder,
                    "focused": bubbleReply.focused, "target": bubbleReply.target?.thread ?? "", "working": bubbleReply.target?.working ?? false, "queued": bubbleReply.target?.queued ?? false,
                    "headline": pet.headline, "subtitle": pet.subtitle, "shimmer": pet.bubbleText.subtitleShimmer as Any, "interrupted": slack.model.interruption.thread ?? "",
                    "thread": target?.id ?? "", "room": target?.room ?? "", "ts": target?.ts ?? "", "pendingEchoes": echoes, "rowHeight": bubbleReply.height,
                    "keyWindow": panel.isKeyWindow, "enabled": bubbleReplyEnabled, "paused": model.paused, "bubbleShown": pet.bubbleShown,
                    "bubble": rect(pet, pet.bubbleGlassFrame), "reply": rect(pet, pet.bubbleReplyFrame),
                    "head": { let r = panel.convertToScreen(pet.convert(pet.atlas.interactionRect(in: pet.spriteRect), to: nil)); return [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] }(),
                    "panel": [Int(panel.frame.minX), Int(panel.frame.minY), Int(panel.frame.width), Int(panel.frame.height)],
                    "chatExpanded": chatExpanded, "connected": slack.connected,
                    "snapshotThreads": slack.snapshot.threads.mapValues { $0.count }, "selected": slack.model.selected ?? ""]
        }
        var written = 0
        func flush() {
            let sent = script.sent
            guard sent.count > written else { return }
            let lines = sent[written...].compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
            if let handle = try? FileHandle(forWritingTo: out.appendingPathComponent("sent.jsonl")) { handle.seekToEndOfFile(); handle.write(Data(lines.utf8)); try? handle.close() }
            else { try? lines.write(to: out.appendingPathComponent("sent.jsonl"), atomically: true, encoding: .utf8) }
            written = sent.count
        }
        try? "".write(to: out.appendingPathComponent("sent.jsonl"), atomically: true, encoding: .utf8)
        dashboard?.orderOut(nil)
        try? "ready".write(to: out.appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
        while true {
            wire(); flush()
            // The usual 0.75 s beat does not run in a UI check.
            if !model.paused { slack.tick() }
            beat += 1
            if quiet { slack.model.approvalThreads = []; nudges.dismiss() }
            if beat % 5 == 0 { updatePet() }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: cmd.path)) ?? []
            for name in names.sorted() {
                try? FileManager.default.removeItem(at: cmd.appendingPathComponent(name))
                if name == "stop" { flush(); NSApp.terminate(nil); return }
                if name.hasPrefix("capture-") { capture(destination: out.appendingPathComponent("shots/" + String(name.dropFirst(8)))) }
                switch name {
                case "typing-on", "typing-queue":
                    writerProfile = name == "typing-queue" ? "queue-z" : "work-x"
                    if let t = thread() {
                        slack.activity = SlackActivity(writers: [.init(profile: writerProfile, name: roster.first { $0.profile == writerProfile }!.name, room: t.room, thread: t.ts, since: Date().timeIntervalSince1970)], recent: [])
                    }
                case "noisy": quiet = false; slack.model.approvalThreads = nil
                case "quiet": quiet = true
                case "typing-off": slack.activity = SlackActivity()
                case "hold-next": held = script.next(true, held: true)
                case "release": held?.signal(); held = nil
                case "failnext": script.next(false)
                case "setting-off": bubbleReplyEnabled = false
                case "setting-on": bubbleReplyEnabled = true
                case "pause": model.paused = true; updatePet()
                case "resume": model.paused = false; updatePet()
                case "file-drop-open": fileDrop.openText()
                case "file-drop-close": fileDrop.close()
                case "chat-open":
                    showChat()
                    if let t = thread() { slack.model.open.insert(t.id) }
                case "chat-new-post": slack.model.writeNewPost()
                case "chat-send":
                    slack.model.draft = "채팅창에서 끼어들기"; slack.model.send()
                case "chat-prompt": break
                default: break
                }
                if name.hasPrefix("move-") {
                    let parts = name.dropFirst(5).split(separator: "-").compactMap { Double($0) }
                    if parts.count == 2 { placePet(at: NSPoint(x: parts[0], y: parts[1])) }
                }
                var state = snapshot()
                if name == "chat-prompt" { state["chatPrompt"] = (slack.model.sendTarget == nil) ? "new" : "reply"; state["interruptible"] = slack.model.interruptible?.id ?? "" }
                if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) { try? data.write(to: out.appendingPathComponent("done-" + name + ".json")) }
            }
            if let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.sortedKeys]) { try? data.write(to: out.appendingPathComponent("state.json")) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
