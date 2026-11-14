import AppKit
import SwiftUI

/// A card must be drawn inside its own table row, whatever was clicked, answered or resized before.
/// Synthetic data only; nothing is sent. `--ui-smoke-overlap` runs both parts, `--ui-smoke-overlap-quick` one width.
extension AppDelegate {
    @MainActor func verifyThreadOverlap(destination: URL) async {
        var report = "", failures: [String] = []
        let records = destination.appendingPathComponent("diagnostics")
        ThreadLayoutRecorder.folder = records
        report += "SlackModel.reducesMotion=\(SlackModel.reducesMotion), OS=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), reduce-motion argument=\(CommandLine.arguments.contains("--ui-smoke-reduce-motion"))\n"
        guard !SlackModel.reducesMotion else {
            try? report.write(to: destination.appendingPathComponent("thread-overlap.txt"), atomically: true, encoding: .utf8)
            smokeFailed("AC4-01 requires SlackModel.reducesMotion == false; animation reproduction was not run")
        }
        if CommandLine.arguments.contains("--ui-smoke-overlap-shrink") {
            failures += await overlapShrink(report: &report)
            try? report.write(to: destination.appendingPathComponent("thread-overlap.txt"), atomically: true, encoding: .utf8)
            if !failures.isEmpty { smokeFailed(failures.joined(separator: "\n")) }
            return
        }
        if CommandLine.arguments.contains("--ui-smoke-overlap-throttle-only") {
            failures += await overlapThrottle(destination: destination, report: &report)
            try? report.write(to: destination.appendingPathComponent("thread-overlap.txt"), atomically: true, encoding: .utf8)
            if !failures.isEmpty { smokeFailed(failures.joined(separator: "\n")) }
            return
        }
        report += "== large list to small list (AC5-01)\n"
        failures += await overlapShrink(report: &report)
        report += "== animated live list changes (AC4-01)\n"
        failures += await overlapAnimated(report: &report)
        if CommandLine.arguments.contains("--ui-smoke-overlap-animation-only") {
            try? report.write(to: destination.appendingPathComponent("thread-overlap.txt"), atomically: true, encoding: .utf8)
            if !failures.isEmpty { smokeFailed(failures.joined(separator: "\n")) }
            return
        }
        let quick = CommandLine.arguments.contains("--ui-smoke-overlap-quick")
        for dark in [false, true] {
            for width in quick ? [CGFloat(300)] : [300, 360, 520] {
                report += "== isolated list, width \(width) \(dark ? "dark" : "light")\n"
                failures += await overlapIsolated(width: width, dark: dark, destination: destination, report: &report)
            }
        }
        report += "== live chat window\n"
        failures += await overlapLive(destination: destination, report: &report)
        report += "== live list changes\n"
        failures += await overlapChanges(report: &report)
        // The watch ran all through the checks above; in a correct list it wrote nothing.
        let automatic = ((try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []).filter { $0.hasSuffix("-auto.json") }
        report += "automatic records written during the checks: \(automatic.count)\n"
        if !automatic.isEmpty { failures.append("The layout watch wrote \(automatic.count) record(s) in a correct list: \(automatic)") }
        report += "== layout records\n"
        failures += await overlapRecords(destination: destination, report: &report)
        report += "== throttled layout notification (AC4-04)\n"
        failures += await overlapThrottle(destination: destination, report: &report)
        try? report.write(to: destination.appendingPathComponent("thread-overlap.txt"), atomically: true, encoding: .utf8)
        if !failures.isEmpty {
            FileHandle.standardError.write(Data(("OVERLAP FAIL:\n" + failures.joined(separator: "\n") + "\n").utf8))
            smokeFailed("A card draws outside its table row (\(failures.count) cases); see thread-overlap.txt")
        }
    }

    /// The shared layout check, in full, written into the report line by line.
    @MainActor private func overlapAudit(_ coordinator: NativeThreadList.Coordinator, _ step: String, report: inout String, materialize: Bool = false) -> [String] {
        let outcome = ThreadLayoutAudit.inspect(coordinator, full: true, forceLayout: true, materialize: materialize)
        for row in outcome.rows {
            let parts = (row["parts"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "Host" }
                .map { "host[slot \(Int($0["slot"] as? Double ?? 0)) drawn \(Int($0["drawn"] as? Double ?? 0))]" }
            report += "\(step) row \(row["index"] ?? "?") \(row["id"] ?? "?"): row=\(row["height"] ?? "?") layout=\(row["layoutHeight"] ?? "?") reach=\(Int(row["reach"] as? Double ?? 0)) \(parts.joined(separator: " "))\n"
        }
        report += "\(step): \(outcome.shownRowViews) row views shown of \(outcome.rowCount) rows\n"
        return outcome.violations.map { "\(step) row \($0.row) \($0.id): \($0.code) -- \($0.detail)" }
    }

    /// Synthetic report room. Thread A is the one from the report: a post with a status mark, replies that fold or carry a
    /// file, and a last reply asking for a checklist answer; it starts unloaded, as a thread does before it is opened.
    /// B asks for a button answer, C is an ordinary thread.
    private func overlapThreads(room: String) -> [SlackThread] {
        let base = 1_800_000_000.0
        func message(_ at: Double, _ body: String, mine: Bool = false) -> ChatMessage {
            ChatMessage(id: "slack:\(room):\(Int(base + at))", fromUser: mine, speaker: mine ? "" : "업무비서", body: body,
                        date: Date(timeIntervalSince1970: base + at), sessionID: "\(Int(base + at))", profile: mine ? "" : "work-assistant")
        }
        let detail = (1...6).map { "- 상세 \($0): 합성 보고의 상세 줄입니다. 폭이 좁으면 줄이 접혀 높이가 달라집니다." }.joined(separator: "\n")
        let asking = HermesReplyEvidence(statusText: "", hasStatus: false, hasControls: true, color: nil)
        var root = message(10, "**마감 테스트 메일 1건 도착**\n합성 보고의 첫 글입니다.")
        root.marks = [ChatMark(color: "#E8A33D", text: "확인 필요")]
        var asked = message(14, "**소유자가 할 일**\n- 합성 항목을 골라 작성해 주세요.\n\n**결정 필요**\n- 아래에서 고릅니다.\n\n**상세**\n" + detail)
        asked.hermesChecklist = ["전부", "합성 첫째 항목", "합성 둘째로 조금 더 긴 항목 이름", "셋째"]
        asked.hermesChecklistCanSkip = true
        asked.hermesReplyEvidence = asking
        asked.marks = [ChatMark(color: "#E01E5A", text: "결정 필요")]
        var buttons = message(20, "**🔴 합성 버튼 보고**\n\n**결정 필요**\n- 아래에서 고릅니다.\n\n**상세**\n" + detail)
        buttons.hermesButtons = ["승인", "거절", "의견", "확인"]
        buttons.hermesReplyEvidence = asking
        let plain = message(30, "**폴라리스 특허** 합성 일반 스레드입니다.\n" + String(repeating: "본문 줄입니다. ", count: 40))
        func thread(_ root: ChatMessage, replies: [ChatMessage] = [], total: Int = 0, loaded: Bool = true) -> SlackThread {
            SlackThread(id: root.id, room: room, ts: String(Int(root.date.timeIntervalSince1970)), root: root, replies: replies, replyCount: total,
                        loaded: loaded, latest: (replies.last ?? root).date.timeIntervalSince1970, latestFromUser: false)
        }
        return [thread(root, replies: [asked], total: 4, loaded: false), thread(buttons), thread(plain)]
    }

    /// What opening thread A brings in: every reply, the last of them asking for the checklist answer.
    private func overlapLoaded(_ thread: SlackThread) -> SlackThread {
        var loaded = thread
        let all = overlapThreadReplies(thread)
        loaded.replies = all; loaded.replyCount = all.count; loaded.loaded = true
        return loaded
    }
    private func overlapThreadReplies(_ thread: SlackThread) -> [ChatMessage] {
        let at = thread.root.date.timeIntervalSince1970
        func message(_ offset: Double, _ body: String, mine: Bool = false) -> ChatMessage {
            ChatMessage(id: "slack:\(thread.room):\(Int(at + offset))", fromUser: mine, speaker: mine ? "" : "업무비서", body: body,
                        date: Date(timeIntervalSince1970: at + offset), sessionID: "\(Int(at + offset))", profile: mine ? "" : "work-assistant")
        }
        var attached = message(3, "첨부 파일을 올렸어요.")
        attached.files = [ChatFile(id: "F-SYNTH", name: "합성 문서.pdf", mimetype: "application/pdf", size: 2048, url: "", thumb: "")]
        // A report laid out the way Slack's blocks arrive: a status bar, a table, a code box, a list with detail lines.
        var rich = message(4, "**마감 점검 요약**\n> 확인 필요한 메일이 있어요\n> - 항목 하나\n\n| 메일 | 상태 | 마감 |\n|---|:-:|--:|\n| 폴라리스 특허 출원 관련 합성 메일 제목이 긴 경우 | 대기 | 11-06 |\n| 마감 테스트 메일 | 도착 | 11-05 |\n\n```\n합성 코드 줄 1\n합성 코드 줄 2는 폭이 좁으면 접힐 만큼 길게 씁니다 합성 합성 합성 합성\n```\n- 항목 가\n  ↳ 세부 설명이 길어서 폭이 좁으면 줄이 접히는 경우를 보려고 길게 씁니다 합성 합성\n- 항목 나")
        rich.quoteColors = ["#E8A33D"]
        return [message(1, "확인 부탁드려요.", mine: true),
                message(2, (1...16).map { "긴 답글 \($0)번째 줄입니다. 접으면 앞부분만 보입니다." }.joined(separator: "\n")),
                attached, rich] + thread.replies
    }

    /// The conversation after the owner answered the checklist: their line, and the character's reply
    /// (still being written when `streaming`).
    private func overlapAnswered(_ thread: SlackThread, streaming: String? = nil) -> SlackThread {
        var answered = thread
        let at = thread.root.date.timeIntervalSince1970
        func reply(_ offset: Double, _ body: String, mine: Bool) -> ChatMessage {
            ChatMessage(id: "slack:\(thread.room):\(Int(at + offset))", fromUser: mine, speaker: mine ? "" : "업무비서", body: body,
                        date: Date(timeIntervalSince1970: at + offset), sessionID: "\(Int(at + offset))", profile: mine ? "" : "work-assistant")
        }
        var written = reply(21, streaming ?? "받았어요. 합성 처리 결과를 알려드립니다.\n" + String(repeating: "결과 설명 줄입니다. ", count: 30), mine: false)
        written.streaming = streaming != nil
        answered.replies += [reply(20, "합성 선택: 전부", mine: true), written]
        answered.replyCount = answered.replies.count
        return answered
    }

    // MARK: Part one: the list on its own

    @MainActor private func overlapIsolated(width: CGFloat, dark: Bool, destination: URL, report: inout String) async -> [String] {
        func settle(_ milliseconds: UInt64 = 300) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
        let isolated = SlackModel(), chat = ChatModel()
        let view = ChatView(model: chat, slack: isolated, web: WebPaneModel())
        isolated.threads = overlapThreads(room: "CRPT")
        let coordinator = NativeThreadList.Coordinator(model: isolated)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: width, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { coordinator.disconnect(); window.close() }
        window.contentView = coordinator.makeScroll(); window.makeKeyAndOrderFront(nil)
        if CommandLine.arguments.contains("--ui-smoke-overlap-legacy-scroller") { coordinator.scroll.scrollerStyle = .legacy }
        isolated.newPost = true
        func update() {
            isolated.prepareNativeInputs(chat: chat, dark: dark, reduceMotion: true, vault: [nil, nil, nil])
            let rows = isolated.renderedThreads.map { memo -> NativeThreadRow in
                let thread = memo.thread
                let target = isolated.target?.id == thread.id
                let inputs = isolated.rowInputs(memo, chat: chat, dark: dark, reduceMotion: true, target: target)
                return NativeThreadRow(id: thread.id, inputs: inputs, token: String(MessageChecklist.shared.revision),
                    card: { view.nativeThreadContent(thread, inputs: inputs, target: target) }, content: { AnyView(EmptyView()) })
            }
            coordinator.update(rows: rows, stamp: isolated.entryViewportStamp)
        }
        let tag = " @\(Int(width))" + (dark ? "d" : "l")
        var failures: [String] = []
        func step(_ name: String) async {
            update(); await settle()
            failures += overlapAudit(coordinator, name + tag, report: &report, materialize: true)
        }
        await step("initial")
        func picture(_ name: String) {
            guard CommandLine.arguments.contains("--ui-smoke-overlap-pictures"), let bitmap = coordinator.table.bitmapImageRepForCachingDisplay(in: coordinator.table.bounds) else { return }
            coordinator.table.cacheDisplay(in: coordinator.table.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("overlap-\(name)-\(Int(width))\(dark ? "d" : "l").png"))
        }
        isolated.pick(isolated.threads[0], foldable: true); await step("pick-A-unloaded")
        isolated.threads[0] = overlapLoaded(isolated.threads[0]); await step("A-loaded")
        let loadedA = isolated.threads[0]
        picture("loaded")
        for (name, index) in [("pick-B", 1), ("pick-C", 2), ("pick-A-again", 0)] {
            isolated.pick(isolated.threads[index], foldable: index == 0); await step(name)
        }
        // The long reply's 더 보기 and 접기.
        let longReply = isolated.threads[0].replies[1].id
        chat.toggleReply(longReply); await step("fold-open")
        chat.toggleReply(longReply); await step("fold-closed")
        // Press where the checklist's buttons are, left to right and row by row; its choice changes the piece's own state.
        func checklistHost() -> NativeThreadCard.Host? {
            (coordinator.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeThreadCard)?.subviews.compactMap { $0 as? NativeThreadCard.Host }.first
        }
        if let first = checklistHost() {
            for x in stride(from: CGFloat(8), to: first.bounds.width, by: 38) {
                for y in [CGFloat(10), 30, 50] {
                    guard let host = checklistHost(), let hostWindow = host.window else { break }
                    coordinator.table.scrollRowToVisible(0)
                    let point = host.convert(NSPoint(x: x, y: y), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: hostWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { hostWindow.sendEvent(event) }
                    }
                    await settle(120)
                    failures += overlapAudit(coordinator, "press(\(Int(x)),\(Int(y)))" + tag, report: &report, materialize: true)
                }
            }
        }
        isolated.threads[0] = overlapAnswered(loadedA, streaming: "합성 스트리밍 단어1 단어2 단어3"); await step("answer-streaming")
        isolated.threads[0] = overlapAnswered(loadedA); await step("answered")
        isolated.pick(isolated.threads[2], foldable: false); await step("pick-C-after-answer")
        return failures
    }

    // MARK: Part two: the real chat window

    @MainActor private func overlapLive(destination: URL, report: inout String) async -> [String] {
        func settle(_ milliseconds: UInt64 = 500) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
        let model = slack.model
        var failures: [String] = []
        guard let room = model.postRoom else { return ["live: the synthetic room has no post room"] }
        func audit(_ name: String) {
            guard let coordinator = model.nativeGeometry as? NativeThreadList.Coordinator else { failures.append("\(name): no native list"); return }
            failures += overlapAudit(coordinator, name, report: &report)
        }
        if CommandLine.arguments.contains("--ui-smoke-overlap-legacy-scroller") { model.scrollView?.scrollerStyle = .legacy }
        model.typing = [:]; model.draft = ""
        model.threads = overlapThreads(room: room)
        resizeChat(to: CGSize(width: 440 + slackStrip, height: 560)); await settle(900)
        audit("live-initial")
        let ids = model.threads.map(\.id)
        func thread(_ index: Int) -> SlackThread { model.threads.first { $0.id == ids[index] }! }
        model.pick(thread(0), foldable: true); await settle(); audit("live-pick-A-unloaded")
        model.threads[0] = overlapLoaded(thread(0)); await settle(900); audit("live-A-loaded")
        let loadedA = thread(0)
        let longReply = loadedA.replies[1].id
        chat.toggleReply(longReply); await settle(); audit("live-fold-open")
        chat.toggleReply(longReply); await settle(); audit("live-fold-closed")
        model.pickByButton(thread(0)); await settle(); audit("live-button-A")
        // The owner's answer goes out and the character writes back, word by word.
        let words = (1...24).map { "합성 스트리밍 단어\($0)" }
        for count in stride(from: 3, through: words.count, by: 7) {
            model.threads[0] = overlapAnswered(loadedA, streaming: words.prefix(count).joined(separator: " "))
            model.typing = [ids[0]: [TypingIndicator(id: "typing-A", speaker: "업무비서", profile: "work-assistant")]]
            await settle(200); audit("live-streaming-\(count)")
        }
        model.typing = [:]
        model.threads[0] = overlapAnswered(loadedA); await settle(900); audit("live-answered-A")
        model.pick(thread(1), foldable: false); await settle(); audit("live-pick-B")
        model.pick(thread(2), foldable: false); await settle(); audit("live-pick-C")
        for width in [CGFloat(340), 520, 300, 440] {
            resizeChat(to: CGSize(width: width + slackStrip, height: 560)); await settle(900)
            audit("live-resized-\(Int(width))")
        }
        // The same actions again, a few milliseconds apart, as fast hands would do them. Each is looked at once while
        // work is still pending (noted, not failed) and again after it has settled (failed).
        model.threads[0] = thread(0).loaded ? loadedA : overlapThreads(room: room)[0]
        var pending: [String] = []
        func quick(_ name: String, _ action: () -> Void) async {
            action(); await settle(40)
            var transient: [String] = []
            if let coordinator = model.nativeGeometry as? NativeThreadList.Coordinator { transient = overlapAudit(coordinator, "quick-" + name, report: &report) }
            if !transient.isEmpty { pending.append(contentsOf: transient) }
        }
        for round in 0..<3 {
            await quick("fold-A-\(round)") { model.threads[0] = overlapThreads(room: room)[0] }
            await quick("pick-A-\(round)") { model.pick(thread(0), foldable: true) }
            await quick("load-A-\(round)") { model.threads[0] = loadedA }
            await quick("button-A-\(round)") { model.pickByButton(thread(0)) }
            for count in stride(from: 3, through: words.count, by: 7) {
                await quick("stream-\(round)-\(count)") {
                    model.threads[0] = overlapAnswered(loadedA, streaming: words.prefix(count).joined(separator: " "))
                    model.typing = [ids[0]: [TypingIndicator(id: "typing-A", speaker: "업무비서", profile: "work-assistant")]]
                }
            }
            await quick("final-\(round)") { model.typing = [:]; model.threads[0] = overlapAnswered(loadedA) }
            await quick("pick-C-\(round)") { model.pick(thread(2), foldable: false) }
            await settle(900); audit("live-rapid-settled-\(round)")
        }
        report += "rapid steps that were still pending when looked at: \(pending.count)\n" + pending.prefix(12).joined(separator: "\n") + "\n"
        return failures
    }

    // MARK: Part three: the list changing under the reader

    /// Each change the list can go through while someone reads it, at the top, middle and bottom of the scroll.
    /// After each action the table is looked at while work is still pending (written down, not failed) and again once
    /// it has settled (failed). Replies go through the model's own send callback, which here only records the words.
    @MainActor private func overlapChanges(report: inout String) async -> [String] {
        func settle(_ milliseconds: UInt64 = 700) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
        let model = slack.model
        var failures: [String] = [], pending: [String] = []
        guard let room = model.postRoom else { return ["changes: the synthetic room has no post room"] }
        let originalSend = model.onSend
        var sent: [(text: String, thread: String?)] = []
        model.onSend = { text, _, thread, _ in sent.append((text, thread?.id)) }
        defer { model.onSend = originalSend }
        let words = (1...24).map { "합성 스트리밍 단어\($0)" }
        func scroll(_ place: Int) {
            guard let view = model.scrollView, let document = view.documentView else { return }
            let range = max(0, document.bounds.height - view.contentView.bounds.height)
            view.contentView.scroll(to: NSPoint(x: 0, y: [0, range / 2, range][place]))
            view.reflectScrolledClipView(view.contentView)
        }
        func look(_ name: String, settled: Bool) {
            guard let coordinator = model.nativeGeometry as? NativeThreadList.Coordinator else { failures.append("\(name): no native list"); return }
            let found = overlapAudit(coordinator, name, report: &report)
            if settled { failures += found } else { pending += found }
        }
        func reset(_ place: Int) async {
            var fresh = overlapThreads(room: room)
            fresh[0] = overlapLoaded(fresh[0])
            model.typing = [:]; model.draft = ""; model.open = []; model.picked = nil; model.replyTo = nil; model.newPost = true
            model.threads = fresh
            await settle(); scroll(place); await settle(300)
        }
        func thread(_ index: Int) -> SlackThread { model.threads[index] }
        func newThread(_ number: Int, tall: Bool) -> SlackThread {
            let at = 1_800_001_000.0 + Double(number)
            let root = ChatMessage(id: "slack:\(room):\(Int(at))", fromUser: false, speaker: "업무비서",
                                   body: "**합성 새 스레드 \(number)**\n" + String(repeating: "새 스레드 본문 줄입니다. ", count: tall ? 30 : 4),
                                   date: Date(timeIntervalSince1970: at), sessionID: "\(Int(at))", profile: "work-assistant")
            return SlackThread(id: root.id, room: room, ts: String(Int(at)), root: root, replies: [], replyCount: 0, loaded: true, latest: at, latestFromUser: false)
        }
        /// An action, then the table 40ms later and again after settling.
        func act(_ name: String, _ action: () -> Void) async {
            action(); await settle(40); look(name + " (pending)", settled: false)
            await settle(); look(name, settled: true)
        }
        let places = ["top", "middle", "bottom"]
        for place in 0..<3 {
            let tag = "@" + places[place]
            // The order changes: a thread lower down gets a newer answer and moves up, then moves back.
            await reset(place)
            await act("reorder-up " + tag) { model.threads = self.overlapThreadsMoved(model.threads, from: 2, to: 0) }
            await act("reorder-down " + tag) { model.threads = self.overlapThreadsMoved(model.threads, from: 0, to: 2) }
            await act("reorder-middle " + tag) { model.threads = self.overlapThreadsMoved(model.threads, from: 1, to: 0) }
            // A new thread comes in above the picked one; one above it leaves.
            await reset(place)
            model.pick(thread(1), foldable: false); await settle(); look("picked-B " + tag, settled: true)
            await act("insert-above-picked " + tag) { model.threads.insert(newThread(1, tall: true), at: 0) }
            await act("insert-top-short " + tag) { model.threads.insert(newThread(2, tall: false), at: 0) }
            await act("remove-above-picked " + tag) { model.threads.removeFirst() }
            await act("remove-tall-above " + tag) { model.threads.removeFirst() }
            await act("remove-picked " + tag) { model.threads.removeAll { $0.id == model.picked } }
            // The answer buttons of an opened thread go away: waiting becomes working and the card gets much shorter.
            await reset(place)
            model.pickByButton(thread(0)); await settle(); look("opened-A " + tag, settled: true)
            await act("answered-buttons-gone " + tag) { model.threads[0] = self.overlapAnswered(self.overlapLoaded(self.overlapThreads(room: room)[0]), streaming: nil) }
            await act("answered-short " + tag) {
                var shorter = model.threads[0]; shorter.replies = Array(shorter.replies.prefix(1)); shorter.replyCount = 1; model.threads[0] = shorter
            }
            // The owner's checklist answer and a composer reply go out through the model's send callback and come back.
            await reset(place)
            await act("checklist-send " + tag) {
                model.answerHermesChecklist(thread(0), selected: ["전부"])
                var echoed = thread(0)
                let at = echoed.root.date.timeIntervalSince1970
                var mine = ChatMessage(id: "slack:\(room):\(Int(at + 20))", fromUser: true, speaker: "", body: sent.last?.text ?? "", date: Date(timeIntervalSince1970: at + 20), pending: true, sessionID: "x", profile: "")
                mine.pending = true
                echoed.replies.append(mine); echoed.replyCount += 1; model.threads[0] = echoed
                model.typing = [echoed.id: [TypingIndicator(id: "typing-A", speaker: "업무비서", profile: "work-assistant")]]
            }
            for count in stride(from: 3, through: words.count, by: 7) {
                await act("send-streaming-\(count) " + tag) {
                    var echoed = thread(0)
                    echoed.replies[echoed.replies.count - 1].pending = false
                    let at = echoed.root.date.timeIntervalSince1970
                    var written = ChatMessage(id: "slack:\(room):\(Int(at + 21))", fromUser: false, speaker: "업무비서", body: words.prefix(count).joined(separator: " "),
                                              date: Date(timeIntervalSince1970: at + 21), sessionID: "y", profile: "work-assistant")
                    written.streaming = true
                    if echoed.replies.last?.id == written.id { echoed.replies.removeLast() } else { echoed.replyCount += 1 }
                    echoed.replies.append(written); model.threads[0] = echoed
                }
            }
            await act("send-final " + tag) {
                model.typing = [:]
                var echoed = thread(0); echoed.replies[echoed.replies.count - 1].streaming = false; model.threads[0] = echoed
            }
            await reset(place)
            await act("composer-reply " + tag) {
                model.reply(thread(1)); model.draft = "합성 컴포저 답글"; model.send()
                var echoed = thread(1)
                let at = echoed.root.date.timeIntervalSince1970
                echoed.replies.append(ChatMessage(id: "slack:\(room):\(Int(at + 30))", fromUser: true, speaker: "", body: sent.last?.text ?? "", date: Date(timeIntervalSince1970: at + 30), sessionID: "z", profile: ""))
                echoed.replyCount += 1; model.threads[1] = echoed
            }
            // Another room and back.
            await reset(place)
            let mine = model.selected ?? room
            await act("room-away " + tag) { model.select(model.rooms.first { $0.id != mine }?.id ?? mine) }
            await act("room-back " + tag) {
                model.select(mine)
                var fresh = self.overlapThreads(room: room); fresh[0] = self.overlapLoaded(fresh[0]); model.threads = fresh
            }
            // The window grows when a thread opens.
            await reset(place)
            resizeChat(to: CGSize(width: 440 + slackStrip, height: 360)); await settle(900)
            await act("open-in-small-window " + tag) { model.pick(thread(0), foldable: true) }
            await act("open-other-in-small-window " + tag) { model.pick(thread(1), foldable: false) }
            resizeChat(to: CGSize(width: 440 + slackStrip, height: 560)); await settle(900)
            look("window-grown " + tag, settled: true)
            // Everything above, 40ms apart.
            await reset(place)
            for round in 0..<2 {
                for step in 0..<10 {
                    switch step {
                    case 0: model.pick(thread(0), foldable: true)
                    case 1: model.threads.insert(newThread(10 + round, tall: true), at: 0)
                    case 2: model.threads = overlapThreadsMoved(model.threads, from: model.threads.count - 1, to: 0)
                    case 3: model.pickByButton(thread(1))
                    case 4: model.threads.removeFirst()
                    case 5: model.threads[0] = overlapAnswered(thread(0).replies.isEmpty ? overlapLoaded(thread(0)) : thread(0), streaming: "합성 몰아치기")
                    case 6: model.pick(thread(model.threads.count - 1), foldable: false)
                    case 7: model.threads.insert(newThread(20 + round, tall: false), at: 0)
                    case 8: model.threads.removeLast()
                    default: model.threads = overlapThreads(room: room)
                    }
                    await settle(40); look("burst-\(round)-\(step) " + tag + " (pending)", settled: false)
                }
                await settle(); look("burst-\(round) " + tag, settled: true)
            }
        }
        // Scrolling by hand while the list changes: rows come and go from the table's own recycling.
        await reset(0)
        for step in 0..<24 {
            if let view = model.scrollView {
                let range = max(0, (view.documentView?.bounds.height ?? 0) - view.contentView.bounds.height)
                let y = step < 12 ? CGFloat(step) * range / 11 : CGFloat(23 - step) * range / 11
                view.contentView.scroll(to: NSPoint(x: 0, y: y)); view.reflectScrolledClipView(view.contentView)
            }
            switch step % 6 {
            case 0: model.threads.insert(newThread(30 + step, tall: step % 12 < 6), at: min(1, model.threads.count))
            case 1: model.pick(thread(min(1, model.threads.count - 1)), foldable: false)
            case 2: model.threads = overlapThreadsMoved(model.threads, from: model.threads.count - 1, to: 0)
            case 3: if model.threads.count > 3 { model.threads.remove(at: 1) }
            case 4: model.threads[0] = overlapAnswered(thread(0).replies.isEmpty ? overlapLoaded(thread(0)) : thread(0), streaming: "합성 스크롤 중 \(step)")
            default: model.pick(thread(0), foldable: true)
            }
            await settle(40); look("scrolling-\(step) (pending)", settled: false)
            if step % 6 == 5 { await settle(); look("scrolling-settled-\(step)", settled: true) }
        }
        report += "changes steps that were still unsettled 40ms after the action: \(pending.count)\n" + pending.prefix(20).joined(separator: "\n") + "\n"
        return failures
    }

    private func overlapLargeThreads(room: String) -> [SlackThread] {
        var threads = (0..<70).map { index -> SlackThread in
            let at = 1_800_010_000.0 + Double(index)
            let post = ChatMessage(id: "overlap-motion-\(index)", fromUser: false, speaker: "합성 직원",
                body: "합성 행 \(index)\n" + String(repeating: "줄바꿈이 있는 합성 본문입니다. ", count: 12), date: Date(timeIntervalSince1970: at))
            return SlackThread(id: post.id, room: room, ts: String(Int(at)), root: post, replies: [], replyCount: 0, loaded: true, latest: at, latestFromUser: false)
        }
        var large = overlapLoaded(overlapThreads(room: room)[0])
        large.root.body += "\n" + (0..<100).map { "합성 큰 스레드 상세 \($0)" }.joined(separator: "\n")
        threads += [large] + Array(overlapThreads(room: room).dropFirst())
        return threads
    }

    /// Exercise the actual SwiftUI -> NSViewRepresentable bridge with motion enabled. The large card is near the
    /// bottom of a long list, so table recycling, height changes and window fitting can interrupt the same animation.
    @MainActor private func overlapAnimated(report: inout String) async -> [String] {
        func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        let model = slack.model
        guard let room = model.postRoom else { return ["animated: no synthetic room"] }
        var failures: [String] = []
        func scroll(_ fraction: CGFloat) {
            guard let scroll = model.scrollView, let doc = scroll.documentView else { return }
            model.userScrolls += 1
            model.scrollInputAt = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.bounds.height - scroll.contentView.bounds.height) * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for round in 0..<12 {
            let fresh = overlapLargeThreads(room: room), big = fresh[70]
            model.typing = [:]; model.bells = [:]; model.notices = []
            model.open = []; model.picked = nil; model.replyTo = nil; model.newPost = true
            model.threads = fresh
            // The long post must actually be expanded; a folded 100-line body is only its short preview.
            for id in [big.root.id, fresh[69].root.id] where !chat.expandedReplies.contains(id) { chat.toggleReply(id) }
            resizeChat(to: CGSize(width: (round % 2 == 0 ? 340 : 520) + slackStrip, height: 560))
            await wait(900)
            scroll([0, 0.5, 1][round % 3]); await wait(300)
            model.pick(big, foldable: true)
            SlackModel.animated {
                model.bells = [big.id: true]
                model.notices = [SlackNoticeItem(id: "synthetic-motion", title: "합성 질문", color: "#FFCC00", threads: [big.id])]
            }
            await wait(40)
            // A reply changes another row while the picked card's expansion is still moving.
            model.threads[69].root.body += "\n" + String(repeating: "합성 새 답글 높이 변화\n", count: 45)
            await wait(40)
            resizeChat(to: CGSize(width: (round % 2 == 0 ? 520 : 340) + slackStrip, height: 420))
            await wait(40)
            model.threads[70] = overlapAnswered(big)
            await wait(40)
            SlackModel.animated { model.notices = []; model.bells = [:] }
            scroll(round % 2 == 0 ? 1 : 0.9)
            await wait(40)
            model.threads[69].root.body = fresh[69].root.body
            await wait(700)
            guard let coordinator = model.nativeGeometry as? NativeThreadList.Coordinator else {
                failures.append("animated round \(round): no native list"); continue
            }
            let outcome = ThreadLayoutAudit.inspect(coordinator, full: false, forceLayout: false)
            let state = coordinator.diagnostics
            let bigHeight = state.heights[big.id] ?? 0
            report += "animated round \(round): bigHeight=\(bigHeight) shown=\(outcome.shownRowViews)/\(outcome.rowCount) ready=\(state.ready) updating=\(state.updating) queued=\(state.queued) clip=\(coordinator.scroll.contentView.bounds)\n"
            if bigHeight < 2000 { failures.append("animated round \(round): large thread only \(bigHeight)pt") }
            for row in outcome.rows where row["hasRowView"] as? Bool == true {
                report += "animated round \(round) row \(row["index"] ?? "?"): rect=\(row["rect"] ?? "?") rowView=\(row["rowView"] ?? "?")\n"
            }
            for violation in outcome.violations {
                let line = "animated round \(round): \(violation.code) row \(violation.row): \(violation.detail)"
                report += line + "\n"; failures.append(line)
            }
        }
        return failures
    }

    /// AC5-01: only a large-to-small list transition in the actual chat window; no earlier overlap scenarios.
    @MainActor private func overlapShrink(report: inout String) async -> [String] {
        func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        let model = slack.model
        guard let room = model.postRoom else { return ["shrink: no synthetic room"] }
        var failures: [String] = []
        for (shared, fraction, label) in [(true, CGFloat(1), "shared-bottom"), (true, 0.5, "shared-middle"),
                                           (false, 1, "disjoint-bottom"), (false, 0.5, "disjoint-middle"), (true, 0, "shared-top")] {
            let large = overlapLargeThreads(room: room), big = large[70]
            model.typing = [:]; model.bells = [:]; model.notices = []; model.draft = ""
            model.open = []; model.picked = nil; model.replyTo = nil; model.newPost = true
            model.threads = large
            for id in [big.root.id, large[69].root.id] where !chat.expandedReplies.contains(id) { chat.toggleReply(id) }
            resizeChat(to: CGSize(width: 360 + slackStrip, height: 420))
            await wait(900)
            model.pick(big, foldable: true)
            await wait(900)
            guard let coordinator = model.nativeGeometry as? NativeThreadList.Coordinator else { failures.append("\(label): no native list"); continue }
            model.userScrolls += 1; model.scrollInputAt = ProcessInfo.processInfo.systemUptime
            let range = max(0, coordinator.table.bounds.height - coordinator.scroll.contentView.bounds.height)
            coordinator.scroll.contentView.scroll(to: NSPoint(x: 0, y: range * fraction))
            coordinator.scroll.reflectScrolledClipView(coordinator.scroll.contentView)
            await wait(300)
            let before = ThreadLayoutAudit.inspect(coordinator, full: false, forceLayout: false)
            let height = coordinator.diagnostics.heights[big.id] ?? 0
            report += "\(label) before: automaticHeights=\(coordinator.table.usesAutomaticRowHeights), rowSizeStyle=\(coordinator.table.rowSizeStyle.rawValue), current=\(model.nativeGeometry === coordinator), rows=\(before.rowCount), bigHeight=\(height), clip=\(coordinator.scroll.contentView.bounds), table=\(coordinator.table.frame), tableBounds=\(coordinator.table.bounds), violations=\(before.violations.map(\.code))\n"
            if before.rowCount < 150 || height < 2000 { failures.append("\(label): large-list precondition not met") }
            var small = overlapThreads(room: room)
            if !shared {
                for index in small.indices {
                    small[index].id = "shrink-new-" + small[index].id
                    small[index].root.id = small[index].id
                    for reply in small[index].replies.indices { small[index].replies[reply].id = "shrink-new-" + small[index].replies[reply].id }
                }
            }
            model.threads = small
            resizeChat(to: CGSize(width: 440 + slackStrip, height: 560))
            await wait(900)
            let after = ThreadLayoutAudit.inspect(coordinator, full: false, forceLayout: false)
            report += "\(label) after: automaticHeights=\(coordinator.table.usesAutomaticRowHeights), rowSizeStyle=\(coordinator.table.rowSizeStyle.rawValue), current=\(model.nativeGeometry === coordinator), rows=\(after.rowCount), shown=\(after.shownRowViews), clip=\(coordinator.scroll.contentView.bounds), table=\(coordinator.table.frame), tableBounds=\(coordinator.table.bounds), violations=\(after.violations.map(\.code))\n"
            for row in after.rows where row["hasRowView"] as? Bool == true {
                report += "\(label) row \(row["index"] ?? "?"): rect=\(row["rect"] ?? "?") rowView=\(row["rowView"] ?? "?")\n"
            }
            for violation in after.violations {
                let line = "\(label): \(violation.code) row \(violation.row): \(violation.detail)"
                report += line + "\n"; failures.append(line)
            }
        }
        return failures
    }

    /// AC4-04: one clean look, then one throttled notification of a 25pt displacement, then no more layout callbacks.
    @MainActor private func overlapThrottle(destination: URL, report: inout String) async -> [String] {
        func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        let isolated = SlackModel()
        let coordinator = NativeThreadList.Coordinator(model: isolated)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 400, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let watch = ThreadLayoutWatch()
        let folder = ThreadLayoutRecorder.folder
        let forced = ThreadLayoutDiagnosticsPolicy.forced
        ThreadLayoutRecorder.folder = destination.appendingPathComponent("diagnostics-throttle")
        ThreadLayoutDiagnosticsPolicy.forced = true
        defer {
            watch.stop(); coordinator.disconnect(); window.close()
            ThreadLayoutRecorder.folder = folder; ThreadLayoutDiagnosticsPolicy.forced = forced
        }
        window.contentView = coordinator.makeScroll(); window.makeKeyAndOrderFront(nil)
        coordinator.update(rows: (0..<8).map { index in
            NativeThreadRow(id: "throttle-\(index)", fixedHeight: 120, content: { AnyView(Text("합성 행 \(index)")) })
        }, stamp: isolated.entryViewportStamp)
        await wait(900)
        // The tested watch receives exactly the two calls below. No later Coordinator callback supplies another look.
        coordinator.table.afterLayout = nil
        coordinator.table.beforeDraw = nil
        let before = ThreadLayoutAudit.inspect(coordinator, full: false, forceLayout: false)
        guard before.violations.isEmpty else { return ["throttle: initial list has violations"] }
        let looks = ThreadLayoutWatch.looks
        watch.layoutFinished(coordinator)
        report += "throttle 1: clean violations=\(before.violations.count), looks=\(ThreadLayoutWatch.looks - looks)\n"
        await wait(100)
        guard let rowView = coordinator.table.rowView(atRow: 1, makeIfNecessary: false) else { return ["throttle: no live row to displace"] }
        rowView.setFrameOrigin(NSPoint(x: rowView.frame.minX, y: rowView.frame.minY + 25))
        let mutated = ThreadLayoutAudit.inspect(coordinator, full: false, forceLayout: false)
        watch.layoutFinished(coordinator)
        if !["rowview-position", "rowviews-overlap"].allSatisfy({ code in mutated.violations.contains { $0.code == code } }) {
            return ["throttle: the 25pt displacement did not create the required violations"]
        }
        report += "throttle 2-3: offset=\(rowView.frame.minY - coordinator.table.rect(ofRow: 1).minY), violations=\(mutated.violations.map(\.code)), looks=\(ThreadLayoutWatch.looks - looks)\n"
        await wait(600)
        let idle = ThreadLayoutAudit.inspect(coordinator, full: false, forceLayout: false)
        report += "throttle 4: offset after 600ms=\(rowView.frame.minY - coordinator.table.rect(ofRow: 1).minY), violations=\(idle.violations.map(\.code))\n"
        await wait(2300)
        let records = ((try? FileManager.default.contentsOfDirectory(atPath: ThreadLayoutRecorder.folder.path)) ?? []).filter { $0.hasSuffix("-auto.json") }
        report += "throttle 5: looks=\(ThreadLayoutWatch.looks - looks), automatic records=\(records.count), offset=\(rowView.frame.minY - coordinator.table.rect(ofRow: 1).minY)\n"
        guard records.count == 1 else { return ["throttle: expected one automatic record after a throttled notification, got \(records.count)"] }
        let url = ThreadLayoutRecorder.folder.appendingPathComponent(records[0])
        guard let data = try? Data(contentsOf: url), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let confirmed = object["confirmedKeys"] as? [String], confirmed.contains("rowview-position@throttle-1") else {
            return ["throttle: the automatic record did not confirm the displaced row"]
        }
        return []
    }

    private func overlapThreadsMoved(_ threads: [SlackThread], from: Int, to: Int) -> [SlackThread] {
        var moved = threads
        guard moved.indices.contains(from) else { return moved }
        let item = moved.remove(at: from)
        moved.insert(item, at: min(to, moved.count))
        return moved
    }

    // MARK: Part four: the record, and the watch that writes it

    /// The manual record holds what it should and none of the words; a list that is wrong for good gets one automatic record
    /// and no more within ten minutes; switched off, the watch never looks.
    @MainActor private func overlapRecords(destination: URL, report: inout String) async -> [String] {
        func settle(_ milliseconds: UInt64) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
        let model = slack.model
        var failures: [String] = []
        guard let room = model.postRoom, let coordinator = model.nativeGeometry as? NativeThreadList.Coordinator else { return ["records: no live list"] }
        defer { ThreadLayoutDiagnosticsPolicy.forced = nil }
        resizeChat(to: CGSize(width: 440 + slackStrip, height: 560))
        var fresh = overlapThreads(room: room); fresh[0] = overlapLoaded(fresh[0])
        model.typing = [:]; model.open = []; model.picked = nil; model.threads = fresh
        model.pick(fresh[0], foldable: true)
        await settle(900)

        // 1. A manual record: every part present, and none of the synthetic words, names, files or links.
        let folder = ThreadLayoutRecorder.folder
        guard let url = ThreadLayoutRecorder.write(ThreadLayoutAudit.snapshot(coordinator, kind: "manual"), manual: true) else { return ["records: the manual record was not written"] }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return ["records: the manual record is not JSON"] }
        for key in ["kind", "app", "model", "coordinator", "rows", "orphans", "floating", "violations", "rowViewsShown", "rowCount"] where object[key] == nil { failures.append("records: the manual record has no '\(key)'") }
        let app = object["app"] as? [String: Any] ?? [:]
        for key in ["version", "build", "commit", "screenScale", "window", "scrollBounds", "documentHeight", "source", "room"] where app[key] == nil { failures.append("records: app has no '\(key)'") }
        for key in ["picked", "target", "open", "pageHold", "followsStream", "scrollRevision"] where (object["model"] as? [String: Any])?[key] == nil { failures.append("records: model has no '\(key)'") }
        for key in ["updating", "queued", "remeasuring", "ready"] where (object["coordinator"] as? [String: Any])?[key] == nil { failures.append("records: coordinator has no '\(key)'") }
        let rows = object["rows"] as? [[String: Any]] ?? []
        if rows.isEmpty { failures.append("records: the manual record has no rows") }
        for row in rows { for key in ["index", "id", "rect", "height", "cardHeight"] where row[key] == nil { failures.append("records: a row has no '\(key)'") } }
        for row in rows where row["hasRowView"] as? Bool == true { for key in ["rowView", "cell", "cellRow", "cellKind"] where row[key] == nil { failures.append("records: a shown row has no '\(key)'") } }
        if rows.count != (object["rowCount"] as? Int ?? -1) { failures.append("records: the record lists \(rows.count) rows of \(object["rowCount"] ?? "?")") }
        let parts = rows.flatMap { $0["parts"] as? [[String: Any]] ?? [] }
        for kind in ["Text", "Host"] where !parts.contains(where: { $0["kind"] as? String == kind }) { failures.append("records: no \(kind) part in the rows") }
        let forbidden = ["업무비서", "work-assistant", "합성 문서", "마감 테스트", "폴라리스", "긴 답글", "상세", "합성", "https://", "http", "확인 필요", ".pdf"]
            + fresh.flatMap { $0.messages.map(\.body) }.filter { !$0.isEmpty }
        for word in forbidden where text.contains(word) { failures.append("records: the manual record contains '\(word.prefix(30))'") }
        report += "manual record \(url.lastPathComponent): \(text.utf8.count) bytes, \(rows.count) rows, \(parts.count) parts, floating \((object["floating"] as? [Any])?.count ?? 0)\n"

        // 2. A list that is wrong for good: a stray row view and a stray cell stay in the table (a frame moved by hand is put back
        // by the table within a frame, so it cannot stand for a lasting fault). One automatic record, then none for ten minutes.
        let autoFolder = destination.appendingPathComponent("diagnostics-tamper")
        try? FileManager.default.removeItem(at: autoFolder)
        ThreadLayoutRecorder.folder = autoFolder
        defer { ThreadLayoutRecorder.folder = folder }
        ThreadLayoutDiagnosticsPolicy.forced = true
        let stray = NSTableRowView(frame: NSRect(x: 0, y: 20, width: 200, height: 40))
        coordinator.table.addSubview(stray)
        let strayCell = NativeThreadCard(frame: NSRect(x: 0, y: 70, width: 200, height: 40))
        coordinator.table.addSubview(strayCell)
        func nudge() { coordinator.table.needsLayout = true; coordinator.table.layoutSubtreeIfNeeded() }
        var automatic: [String] = []
        for _ in 0..<70 {
            nudge(); await settle(100)
            automatic = ((try? FileManager.default.contentsOfDirectory(atPath: autoFolder.path)) ?? []).filter { $0.hasSuffix("-auto.json") }
            if !automatic.isEmpty { break }
        }
        if automatic.count != 1 { failures.append("records: a stray row view should give one automatic record, got \(automatic)") }
        else if let data = try? Data(contentsOf: autoFolder.appendingPathComponent(automatic[0])), let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let violations = record["violations"] as? [[String: Any]] ?? []
            for code in ["orphan-rowview", "orphan-cell"] where !violations.contains(where: { $0["code"] as? String == code }) { failures.append("records: the automatic record does not name \(code): \(violations)") }
            report += "automatic record \(automatic[0]): \(violations.count) violation(s), confirmed \(record["confirmedKeys"] ?? "?")\n"
        }
        for _ in 0..<40 { nudge(); await settle(100) }
        let again = ((try? FileManager.default.contentsOfDirectory(atPath: autoFolder.path)) ?? []).filter { $0.hasSuffix("-auto.json") }
        if again.count != 1 { failures.append("records: no second automatic record within ten minutes, got \(again)") }
        stray.removeFromSuperview(); strayCell.removeFromSuperview()

        // 3. Switched off: the watch never looks, so nothing is written even for the same fault.
        let offFolder = destination.appendingPathComponent("diagnostics-off")
        try? FileManager.default.removeItem(at: offFolder)
        ThreadLayoutRecorder.folder = offFolder
        ThreadLayoutDiagnosticsPolicy.forced = false
        let looksBefore = ThreadLayoutWatch.looks
        coordinator.table.addSubview(stray)
        for _ in 0..<50 { nudge(); await settle(100) }
        stray.removeFromSuperview()
        let wrote = ((try? FileManager.default.contentsOfDirectory(atPath: offFolder.path)) ?? []).count
        if ThreadLayoutWatch.looks != looksBefore || wrote != 0 { failures.append("records: switched off, the watch looked \(ThreadLayoutWatch.looks - looksBefore) times and wrote \(wrote) files") }
        report += "switched off: looks \(ThreadLayoutWatch.looks - looksBefore), files \(wrote)\n"
        return failures
    }
}
