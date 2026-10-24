import AppKit

/// A made-up workspace whose sends succeed or fail as the check says, and can be held back to answer late.
/// Everything else is answered by the usual Slack smoke fixture. Nothing reaches Slack.
final class SlackSendScript {
    private let lock = NSLock()
    private var plan: [(ok: Bool, gate: DispatchSemaphore?)] = []
    private var sentLog: [[String: String]] = []
    let workspace: String
    init(workspace: String) { self.workspace = workspace }
    /// The script of the run, when `--ui-smoke-slack-send` is given.
    static var current: SlackSendScript?

    /// How the next send answers. A held one waits until the returned gate is opened.
    @discardableResult func next(_ ok: Bool, held: Bool = false) -> DispatchSemaphore? {
        let gate = held ? DispatchSemaphore(value: 0) : nil
        lock.lock(); plan.append((ok, gate)); lock.unlock()
        return gate
    }
    var sent: [[String: String]] { lock.lock(); defer { lock.unlock() }; return sentLog }
    private func take() -> (ok: Bool, gate: DispatchSemaphore?) {
        lock.lock(); defer { lock.unlock() }
        return plan.isEmpty ? (true, nil) : plan.removeFirst()
    }
    private func answer(_ body: [String: Any]) -> Result<Data, SlackAPI.Failure> { .success((try? JSONSerialization.data(withJSONObject: body)) ?? Data()) }

    var api: SlackAPI {
        let base = SlackSmokeFixture.api()
        return SlackAPI(transport: { [self] method, parameters in
            switch method {
            case "auth.test": return answer(["ok": true, "user_id": "UME", "url": workspace])
            case "files.getUploadURLExternal":
                return answer(["ok": true, "upload_url": "https://upload.invalid/" + (parameters["filename"] ?? ""), "file_id": "FSMOKE" + (parameters["length"] ?? "")])
            case "chat.postMessage", "files.completeUploadExternal":
                let step = take()
                step.gate?.wait()
                guard step.ok else { return answer(["ok": false, "error": "smoke_refused"]) }
                lock.lock(); sentLog.append(parameters.merging(["method": method]) { first, _ in first }); lock.unlock()
                var message: [String: Any] = ["ts": String(format: "%.6f", Date().timeIntervalSince1970), "user": "UME", "text": parameters["text"] ?? ""]
                if let thread = parameters["thread_ts"] { message["thread_ts"] = thread }
                return answer(["ok": true, "message": message])
            default: return base.transport(method, parameters)
            }
        }, raw: { url, body in body == nil ? base.raw(url, body) : .success(Data("OK".utf8)) })
    }
}

extension AppDelegate {
    /// `--ui-smoke-slack-send`: sends through the real model and controller to a made-up workspace and checks that a failure
    /// waits where it was going, never over what is being written elsewhere, and comes back only when asked.
    @MainActor func verifySlackSend(destination: URL, script: SlackSendScript) async {
        func check(_ condition: Bool, _ message: String) { if !condition { smokeFailed(message) } }
        func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        let steps = destination.appendingPathComponent("slack-send-steps.txt")
        func step(_ name: String) {
            let line = Data((name + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: steps) { handle.seekToEndOfFile(); handle.write(line); handle.closeFile() } else { try? line.write(to: steps) }
        }
        func until(_ what: String, _ condition: () -> Bool) async {
            step("wait: " + what)
            for _ in 0..<40 where !condition() { await settle(0.1) }
            check(condition(), "Timed out: " + what)
        }
        let model = slack.model
        slack.smokeSends = true
        // Sent files are copied beside what Slack keeps; in the check that is a folder of its own.
        slack.store = SlackFileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("ddots-send-store-\(UUID().uuidString)"))
        SmokeLeftovers.note(slack.store.root)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-send-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SmokeLeftovers.note(folder)
        func file(_ name: String) -> URL { let url = folder.appendingPathComponent(name); try? Data("합성 \(name)".utf8).write(to: url); return url }
        let note = file("메모.txt"), photo = file("사진.png"), plan = file("계획.txt")
        await until("rooms are read") { model.threads.filter { !$0.ts.isEmpty }.count >= 2 && model.workspace == script.workspace }
        let workspace = model.workspace

        // 1. A post fails in room A after the user has gone to room B and started writing there.
        model.select("CCOW"); model.writeNewPost(); model.draft = "A방 새 글"
        var gate = script.next(false, held: true)
        model.send()
        check(model.draft.isEmpty, "The sent words leave the draft")
        model.select("CTRUTH"); model.draft = "B방 초안"; model.attachments = [note]
        gate?.signal()
        await until("the held failure arrives") { model.drafts.failures.count == 1 }
        check(model.draft == "B방 초안" && model.attachments == [note], "A failure in another room leaves this room's draft and files alone: \(model.draft) \(model.attachments)")
        check(model.failedHere.isEmpty && model.failedElsewhere.map(\.text) == ["A방 새 글"], "The failure waits in its own room")
        check(model.notice?.contains("보낸 방의 입력창 위 ‘되살리기’") == true, "The room shown says where the failure waits: \(String(describing: model.notice))")
        await settle(); capture(destination: destination.appendingPathComponent("send-failed-elsewhere"))
        if let away = model.failedElsewhere.first { model.showFailure(away) }
        check(model.selected == "CCOW" && model.failedHere.map(\.text) == ["A방 새 글"] && model.draft.isEmpty, "Going to it shows the failure in its room without filling the draft")
        await settle(); capture(destination: destination.appendingPathComponent("send-failed-here"))
        step("1 restore"); model.restoreFailure(model.failedHere[0].id); step("1 restored")
        check(model.draft == "A방 새 글" && model.target == nil && model.newPost && model.failedHere.isEmpty, "Bringing it back makes it a new post of its room again")
        script.next(true)
        model.send()
        await until("the restored post is sent") { script.sent.last?["text"] == "A방 새 글" }
        check(script.sent.last?["channel"] == "CCOW" && script.sent.last?["thread_ts"] == nil, "The restored post goes to the room it was written for: \(String(describing: script.sent.last))")
        model.select("CTRUTH")
        check(model.draft == "B방 초안" && model.attachments == [note], "Room B's draft is still there")
        model.draft = ""; model.attachments = []

        step("2"); // 2. Another thread of the same room.
        model.select("CCOW")
        await until("room A is shown") { model.threads.allSatisfy { $0.room == "CCOW" } && model.threads.contains { $0.root.body.hasPrefix("문의가 하나 더") } }
        // Two short threads: one with a reply, one without.
        guard let x = model.threads.first(where: { $0.root.body.hasPrefix("내일 오전 일정") }),
              let y = model.threads.first(where: { $0.root.body.hasPrefix("문의가 하나 더") }) else { smokeFailed("The short threads are there") }
        model.reply(x); model.draft = "X 답글"
        gate = script.next(false, held: true)
        model.send()
        model.pick(y, foldable: false); model.draft = "Y 초안"
        gate?.signal()
        await until("the thread failure arrives") { model.failedHere.count == 1 }
        check(model.draft == "Y 초안" && model.target?.id == y.id, "A failure in another thread leaves this thread's draft alone")
        model.restoreFailure(model.failedHere[0].id)
        check(model.draft == "X 답글" && model.target?.id == x.id, "Bringing it back goes to its own thread: \(String(describing: model.target?.id))")
        script.next(true)
        model.send()
        await until("the restored reply is sent") { script.sent.last?["text"] == "X 답글" }
        check(script.sent.last?["thread_ts"] == x.ts && script.sent.last?["channel"] == "CCOW", "The restored reply goes to its thread")
        model.pick(y, foldable: false)
        check(model.draft == "Y 초안", "Thread Y's draft waited for it: \(model.draft)")
        model.draft = ""

        step("3"); // 3. The same thread, written again before the failure came back.
        model.reply(x); model.draft = "첫 답글"
        gate = script.next(false, held: true)
        model.send()
        model.draft = "새로 쓰는 답글"
        gate?.signal()
        await until("the same-place failure arrives") { model.failedHere.count == 1 }
        check(model.draft == "새로 쓰는 답글", "A failure does not write over a new draft at its own place")
        model.restoreFailure(model.failedHere[0].id)
        check(model.draft == "첫 답글\n새로 쓰는 답글" && model.target?.id == x.id, "Bringing it back keeps the new words after the failed ones")
        model.draft = ""

        step("4"); // 4. Several failures, one with files, keep their order and their files.
        model.writeNewPost()
        script.next(false); model.draft = "실패 1"; model.send()
        script.next(false); model.draft = "실패 2"; model.attachments = [photo, plan]; model.send()
        await until("both failures arrive") { model.failedHere.count == 2 }
        check(model.failedHere.map(\.text) == ["실패 1", "실패 2"] && model.failedHere[1].files == [photo, plan], "Failures keep the order they were sent and their files")
        model.restoreFailure(model.failedHere[1].id)
        model.restoreFailure(model.failedHere[0].id)
        check(model.draft == "실패 1\n실패 2" && model.attachments == [photo, plan] && model.failedHere.isEmpty, "Both come back with nothing lost: \(model.draft) \(model.attachments)")
        script.next(true)
        model.send()
        await until("files are sent") { script.sent.last?["method"] == "files.completeUploadExternal" }
        check(script.sent.last?["files"]?.contains("FSMOKE") == true && script.sent.last?["channel_id"] == "CCOW" && script.sent.last?["initial_comment"] == "실패 1\n실패 2", "The files go with their words")
        // A file that is gone before it is sent is a failure like any other.
        let missing = folder.appendingPathComponent("사라진.txt")
        model.attachments = [missing]; model.send()
        await until("the missing file fails") { model.failedHere.count == 1 }
        check(model.failedHere[0].reason == "파일을 찾지 못했어요: 사라진.txt" && model.failedHere[0].files == [missing], "A missing file is said by name and kept with its failure")
        model.discardFailure(model.failedHere[0].id)

        step("6"); // 6. Going to another thread by a link, a notice or a search result leaves the words where they were written.
        model.foldAll(); model.reply(x); model.draft = "X 초안"; model.attachments = [note]
        guard let address = model.link(to: y).flatMap(URL.init(string:)), slack.follow(address) else { smokeFailed("A link to thread Y is followed") }
        await until("the link reaches Y") { model.target?.id == y.id }
        check(model.target?.id == y.id && model.draft.isEmpty && model.attachments.isEmpty, "Following a link to Y does not carry X's words: \(model.draft)")
        script.next(true); model.draft = "Y 글"; model.send()
        await until("the post to Y is sent") { script.sent.last?["text"] == "Y 글" }
        check(script.sent.last?["thread_ts"] == y.ts && script.sent.last?["channel"] == "CCOW", "Only Y's words go to Y")
        model.go(to: x.id)
        check(model.target?.id == x.id && model.draft == "X 초안" && model.attachments == [note], "Going back to X by a notice or search result brings X's words and files back")
        // 7. Clicking away or folding the window lets go of the thread; its words wait for it.
        model.foldAll()
        check(model.target?.id != x.id && model.draft.isEmpty && model.attachments.isEmpty, "Folding leaves X's words with X: \(model.draft)")
        model.foldAll(animated: false)
        model.pick(x, foldable: false)
        check(model.target?.id == x.id && model.draft == "X 초안" && model.attachments == [note], "Picking X again brings its words back")
        step("8"); // 8. Leaving a room and coming back returns to the thread or new post that was being written.
        model.draft = "X 방 복귀"; model.attachments = []
        model.select("CTRUTH")
        check(model.draft.isEmpty && model.target?.room != "CCOW", "Another room starts with its own draft")
        model.select("CCOW")
        await until("room A is back") { model.threads.contains { $0.id == x.id } }
        check(model.replyTo == x.id && model.target?.id == x.id && model.draft == "X 방 복귀", "Coming back answers X again with its words: \(String(describing: model.target?.id))")
        script.next(true); model.send()
        await until("the X reply is sent") { script.sent.last?["text"] == "X 방 복귀" }
        check(script.sent.last?["thread_ts"] == x.ts && script.sent.last?["channel"] == "CCOW", "It goes to X")
        model.writeNewPost(); model.draft = "A 새 글 복귀"; model.attachments = [plan]
        model.select("CTRUTH"); model.select("CCOW")
        await until("room A is back again") { model.threads.contains { $0.id == x.id } }
        check(model.newPost && model.target == nil && model.draft == "A 새 글 복귀" && model.attachments == [plan], "Coming back to a new post keeps it a new post")
        script.next(true); model.send()
        await until("the new post with a file is sent") { script.sent.last?["initial_comment"] == "A 새 글 복귀" }
        check(script.sent.last?["channel_id"] == "CCOW" && script.sent.last?["thread_ts"] == nil, "It goes to the room as a new post")
        // 9. A pet bubble showing another room's line does not take the words along.
        model.reply(x); model.draft = "말풍선 전 초안"
        guard let other = model.rooms.first(where: { $0.id == "CTRUTH" }), let line = slack.snapshotLine(in: other.id) else { smokeFailed("Room B has a line") }
        slack.reveal(line)
        check(model.selected == "CTRUTH" && model.draft.isEmpty, "Revealing a bubble's line in another room leaves the draft in its room")
        model.select("CCOW")
        check(model.draft == "말풍선 전 초안" && model.replyTo == x.id, "Coming back finds it")
        // 10. A thread deleted while being answered: its words stay in the draft and no longer aim at it.
        model.release(thread: x.id)
        check(model.draft == "말풍선 전 초안" && model.replyTo != x.id && model.picked != x.id, "The words stay when their thread goes")
        model.draft = ""; model.foldAll()
        step("5"); // 5. Answers that come after the connection was replaced change nothing shown.
        gate = script.next(false, held: true)
        let late = script.next(true, held: true)
        model.draft = "늦게 실패할 글"; model.send()
        model.draft = "늦게 성공할 글"; model.send()
        model.draft = "옛 워크스페이스 초안"
        let next = SlackSendScript(workspace: "https://other-smoke.slack.com/")
        slack.start(next.api)
        check(model.draft.isEmpty && model.attachments.isEmpty, "A new connection does not show the old workspace's draft")
        gate?.signal(); late?.signal()
        for delay in [0.2, 0.6, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.slack.tick() } }
        await until("the other workspace is read") { model.workspace == next.workspace }
        await settle(0.6)
        check(model.failedHere.isEmpty && model.failedElsewhere.isEmpty && model.notice == nil, "A late failure of the old connection is not shown in the new one: \(String(describing: model.notice))")
        check(model.drafts.failures.contains { $0.workspace == workspace && $0.text == "늦게 실패할 글" }, "The late failure is kept with its own workspace")
        check(model.draft.isEmpty && !model.threads.contains { $0.messages.contains { $0.body == "늦게 성공할 글" } }, "A late success does not reach the new connection")
        check(model.drafts.saved.contains { $0.key.workspace == workspace && $0.value.text == "옛 워크스페이스 초안" }, "The old workspace's draft is put away with it")
        try? "PASS: drafts per room/thread/new post, failure restore and targets, several failures with files, missing file, late answers after reconnect\n"
            .write(to: destination.appendingPathComponent("slack-send.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
