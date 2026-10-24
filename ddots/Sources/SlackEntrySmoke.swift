import AppKit
import SwiftUI

/// Gives synthetic navigation input a responder inside the conversation without editing any message.
private final class SlackEntryScrollFocus: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
}

/// `--ui-smoke-room` workspace: the usual made-up rooms, plus two long rooms and one whose listing waits for the smoke.
/// In 긴방A an old post near the top has the newest reply; in 긴방B the newest line is the last post. Nothing reaches Slack.
final class SlackEntryScript {
    static var current: SlackEntryScript?
    /// 늦은방 is empty until `armLate()`; its next listing then waits for `release()`, as a slow answer from Slack would.
    /// Until then nothing waits, so reading the other rooms in the background is never held up by it.
    let late = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = true, lateArmed = false
    func armLate() { lock.lock(); lateArmed = true; lock.unlock() }
    static let newestA = 8, newestLate = 2
    func release() { lock.lock(); let was = held; held = false; lock.unlock(); if was { late.signal() } }

    /// 보류방: empty until `stage` 1. Each stage gives one older post a newer reply (stage 1: post 6 with three replies,
    /// 2: post 2, 3: post 4) and the six newest posts newer replies too. A pass reads the replies of at most six threads
    /// (the bridge's burst), newest posts first, so the held post, older than all of them, is read on a later pass: the room
    /// shows it waiting first. Its replies are then held until `letReplies()`, so the order of arrival is set by the smoke.
    static let heldPosts = [6, 2, 4], fillers = 24..<30
    private var stage = 0
    private var asked = Set<Int>(), released = Set<Int>()
    private let replyGate = DispatchSemaphore(value: 0)
    /// When each stage began: its replies are dated from then, so they are recent whenever in the run the stage comes.
    private var stageAt: [Int: Date] = [:]
    func advance(to next: Int) { lock.lock(); stage = next; stageAt[next] = Date(); lock.unlock() }
    /// True while a held thread's replies are being asked for and held back.
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return !asked.subtracting(released).isEmpty }
    func letReplies() {
        lock.lock(); let blocked = asked.subtracting(released); released.formUnion(blocked); lock.unlock()
        for _ in blocked { replyGate.signal() }
    }

    var api: SlackAPI {
        let now = Date(), base = SlackSmokeFixture.api(now: now)
        func stamp(_ ago: Double) -> String { String(format: "%.6f", now.timeIntervalSince1970 - ago) }
        func post(_ room: String, _ index: Int, ago: Double, latest: Double? = nil, replies: Int = 0) -> [String: Any] {
            var message: [String: Any] = ["ts": stamp(ago), "user": index % 2 == 0 ? "UME" : "UBOT",
                                          "text": "\(room) 글 \(index). " + String(repeating: "방에 들어오면 가장 최근 대화가 보여야 합니다. ", count: 3)]
            if index % 2 == 1 { message["bot_profile"] = ["name": "개인비서"] }
            if replies > 0 { message["reply_count"] = replies; message["thread_ts"] = stamp(ago); message["latest_reply"] = stamp(latest ?? ago - 60) }
            return message
        }
        func reply(_ thread: Double, ago: Double, _ text: String) -> [String: Any] {
            ["ts": stamp(ago), "thread_ts": stamp(thread), "user": "UBOT", "bot_profile": ["name": "개인비서"], "text": text]
        }
        var histories: [String: [[String: Any]]] = [:], replies: [String: [[String: Any]]] = [:]
        // 긴방A: thirty posts an hour apart; post 8 got the newest reply of all, a minute ago.
        histories["CLONGA"] = (0..<30).map { index in
            let ago = 40_000 - Double(index) * 1000
            if index == Self.newestA {
                replies[stamp(ago)] = [reply(ago, ago: ago - 100, "첫 답글"), reply(ago, ago: ago - 50, "둘째 답글"), reply(ago, ago: 20, "방금 단 가장 최근 답글")]
                return post("긴방A", index, ago: ago, latest: 20, replies: 3)
            }
            if index % 7 == 0 { replies[stamp(ago)] = [reply(ago, ago: ago - 60, "예전 답글")]; return post("긴방A", index, ago: ago, replies: 1) }
            return post("긴방A", index, ago: ago)
        }
        // 긴방B: the last post is the newest line; an older thread's reply is older still.
        histories["CLONGB"] = (0..<30).map { index in
            let ago = index == 29 ? 10 : 39_000 - Double(index) * 1000
            if index == 4 { replies[stamp(ago)] = [reply(ago, ago: 12_000, "예전 답글")]; return post("긴방B", index, ago: ago, latest: 12_000, replies: 1) }
            return post("긴방B", index, ago: ago)
        }
        histories["CLATE"] = (0..<20).map { index in
            let ago = 30_000 - Double(index) * 1000
            if index == Self.newestLate {
                replies[stamp(ago)] = [reply(ago, ago: ago - 100, "늦은 답글"), reply(ago, ago: 15, "늦은방 가장 최근 답글")]
                return post("늦은방", index, ago: ago, latest: 15, replies: 2)
            }
            return post("늦은방", index, ago: ago)
        }
        // A page of 새우튀김's list under post 15 of 긴방A: its page buttons hold the view in place while a page is asked for.
        if let index = histories["CLONGA"]?.firstIndex(where: { ($0["text"] as? String)?.hasPrefix("긴방A 글 15.") == true }) {
            let ago = 40_000 - 15 * 1000.0
            histories["CLONGA"]![index]["reply_count"] = 1; histories["CLONGA"]![index]["thread_ts"] = stamp(ago); histories["CLONGA"]![index]["latest_reply"] = stamp(ago - 60)
            replies[stamp(ago)] = [["ts": stamp(ago - 60), "thread_ts": stamp(ago), "user": ShrimpVault.defaultBot, "bot_profile": ["name": "새우튀김"],
                                    "text": "쪽 1/3 · 총 25건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다"]]
        }
        func heldAgo(_ index: Int) -> Double { 36_000 - Double(index) * 1000 }
        func dated(_ at: Date, _ ago: Double) -> String { String(format: "%.6f", at.timeIntervalSince1970 - ago) }
        /// The listing of 보류방 at a stage. The held posts reached so far carry a reply 150 seconds older than their stage;
        /// the six newest posts carry replies 200–205 seconds older than the current stage. None is recent enough to be
        /// read ahead of the others as live, so they are read newest post first and the held post, the oldest of them,
        /// comes last while being the newest conversation.
        func heldListing(_ stage: Int, _ times: [Int: Date]) -> [[String: Any]] {
            (0..<30).map { index in
                let ago = heldAgo(index)
                var message = post("보류방", index, ago: ago)
                var latest: String?, count = 0
                if Self.fillers.contains(index), let at = times[stage] { latest = dated(at, Double(200 + index - Self.fillers.lowerBound)); count = 1 }
                if let order = Self.heldPosts.firstIndex(of: index), order < stage, let at = times[order + 1] { latest = dated(at, 150); count = index == 6 ? 3 : 1 }
                if let latest { message["reply_count"] = count; message["thread_ts"] = stamp(ago); message["latest_reply"] = latest }
                return message
            }
        }
        func heldReplies(_ index: Int, _ stage: Int, _ times: [Int: Date]) -> [[String: Any]] {
            let ago = heldAgo(index), long = String(repeating: "늦게 도착한 답글이 카드를 키웁니다. ", count: 12)
            func line(_ ts: String, _ text: String) -> [String: Any] { ["ts": ts, "thread_ts": stamp(ago), "user": "UBOT", "bot_profile": ["name": "개인비서"], "text": text] }
            if Self.fillers.contains(index), let at = times[stage] { return [line(dated(at, Double(200 + index - Self.fillers.lowerBound)), "단계 \(stage) 답글")] }
            guard let order = Self.heldPosts.firstIndex(of: index), let at = times[order + 1] else { return [] }
            switch index {
            case 6: return [line(stamp(ago - 100), "첫 답글"), line(stamp(ago - 50), "둘째 답글"), line(dated(at, 150), "보류방 최근 답글. " + long)]
            default: return [line(dated(at, 150), "보류방 글 \(index)의 새 답글. " + long)]
            }
        }
        let added: [[String: Any]] = [["id": "CLONGA", "name": "긴방A"], ["id": "CLONGB", "name": "긴방B"], ["id": "CLATE", "name": "늦은방"], ["id": "CHELD", "name": "보류방"]]
        return SlackAPI(transport: { [self] method, parameters in
            let room = parameters["channel"] ?? ""
            switch method {
            case "users.conversations":
                guard case .success(let data) = base.transport(method, parameters),
                      var body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return base.transport(method, parameters) }
                body["channels"] = ((body["channels"] as? [[String: Any]]) ?? []) + added
                return .success((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
            case "conversations.history" where room == "CHELD":
                lock.lock(); let now = stage, times = stageAt; lock.unlock()
                return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "messages": now == 0 ? [] : Array(heldListing(now, times).reversed())])) ?? Data())
            case "conversations.replies" where room == "CHELD":
                lock.lock(); let now = stage, times = stageAt; lock.unlock()
                guard let index = (0..<30).first(where: { stamp(heldAgo($0)) == parameters["ts"] }) else {
                    return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "messages": []])) ?? Data())
                }
                if Self.heldPosts.contains(index) {
                    lock.lock(); let held = !released.contains(index); if held { asked.insert(index) }; lock.unlock()
                    if held { _ = replyGate.wait(timeout: .now() + 25) }
                }
                return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "messages": heldReplies(index, now, times)])) ?? Data())
            case "conversations.members" where room == "CHELD":
                return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "members": ["UME"]])) ?? Data())
            case "conversations.history" where histories[room] != nil:
                lock.lock(); let wait = room == "CLATE" && held, armed = room != "CLATE" || lateArmed; lock.unlock()
                if !armed { return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "messages": []])) ?? Data()) }
                if wait { _ = late.wait(timeout: .now() + 30); late.signal() }
                return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "messages": Array(histories[room]!.reversed())])) ?? Data())
            case "conversations.replies" where histories[room] != nil:
                return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "messages": replies[parameters["ts"] ?? ""] ?? []])) ?? Data())
            case "conversations.members" where histories[room] != nil:
                return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "members": ["UME"]])) ?? Data())
            default: return base.transport(method, parameters)
            }
        }, raw: base.raw)
    }
}

extension AppDelegate {
    /// Clicking a room, narrow tab or wide row, shows the conversation with its newest line: the card is on screen and
    /// answers a click. Nothing is opened, picked or rewritten on the way, and a later scroll, click or link is not undone.
    @MainActor func verifyRoomEntry(destination: URL, check: @escaping @MainActor (Bool, String) -> Void) async {
        let model = slack.model
        func settle(_ seconds: Double = 0.9) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func until(_ what: String, _ condition: () -> Bool) async {
            for _ in 0..<160 where !condition() { slack.tick(); await settle(0.25) }
            check(condition(), (condition() ? "Arrived: " : "Timed out: ") + what + (condition() ? "" : " (room=\(model.selected ?? "nil"), threads=\(model.threads.count), loading=\(model.loading), notice=\(model.notice ?? "nil"))"))
        }
        func thread(_ room: String, _ index: Int) -> String? {
            model.threads.first { $0.room == room && $0.root.body.hasPrefix("\(["CLONGA": "긴방A", "CLONGB": "긴방B", "CLATE": "늦은방"][room]!) 글 \(index).") }?.id
        }
        /// How much of a card is on screen: whole, or at least half the view for a card taller than that.
        func shown(_ id: String?) -> Bool {
            guard let id, let rect = model.rowFrame(id), let scroll = model.scrollView else { return false }
            let seen = rect.intersection(scroll.contentView.bounds).height
            return seen >= min(rect.height, scroll.contentView.bounds.height / 2) - 2
        }
        func place() -> String { "viewport=\(model.scrollView.map { "\($0.contentView.bounds)" } ?? "none"), document=\(model.scrollView?.documentView.map { "\($0.bounds)" } ?? "none"), visible=\(model.visibleThreads.suffix(4)), target=\(model.scrollTarget), targetFrame=\(String(describing: model.rowFrame(model.entryTarget))), bottomFrame=\(String(describing: model.rowFrame("slack-bottom")))" }
        func post(_ type: NSEvent.EventType, _ point: CGPoint) {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
        }
        /// A real click on a room's tab or row, where the sidebar drew it.
        func clickRoom(_ room: String) async {
            guard let frame = chat.smokeFrames["room-" + room], frame.height > 4,
                  let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first else { check(false, "Room \(room) is drawn in the sidebar"); return }
            let point = host.convert(CGPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY), to: nil)
            check(host.bounds.contains(host.convert(point, from: nil)), "Room \(room) is inside the window: \(frame)")
            post(.leftMouseDown, point); post(.leftMouseUp, point)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        /// A real click on the visible part of a conversation card.
        func clickCard(_ id: String) async {
            guard let rect = model.rowFrame(id), let scroll = model.scrollView else { check(false, "Card \(id) is drawn"); return }
            let seen = rect.intersection(scroll.contentView.bounds)
            let point = scroll.contentView.convert(CGPoint(x: seen.minX + 24, y: seen.midY), to: nil)
            post(.leftMouseDown, point); post(.leftMouseUp, point)
            await settle()
        }
        func scrollByHand(toTop: Bool) {
            guard let scroll = model.scrollView, let document = scroll.documentView else { return }
            model.userScrolls += 1
            let end = max(0, document.bounds.maxY - scroll.contentView.bounds.height)
            let y = (document.isFlipped ? toTop : !toTop) ? 0 : end
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        guard let script = SlackEntryScript.current else { check(false, "The room entry workspace is running"); return }
        // Observe exposure itself and the frames that follow it. A check after settle() cannot see an initial jump.
        let firstFrames = destination.appendingPathComponent("entry-first-visible.txt")
        let oldVisible = model.onEntryViewportVisible, oldFrame = model.onEntryViewportFrame, oldTick = pet.onAnimationTick
        var frameLog = "event\troom\trequest\tcontent\ttarget\toffset\terror\tdocument\ttargetFrame\tbottomFrame\n"
        var recordedFrames = Set<String>(), entryExposures = 0, visibleFrames = 0
        var maximumError: CGFloat = 0
        func sampleEntry(_ event: String) {
            guard model.source == .slack, model.entryHolds, let scroll = model.scrollView,
                  let document = scroll.documentView, scroll.alphaValue > 0.99 else { return }
            if event != "expose", (!pet.chatShown || scroll.isHiddenOrHasHiddenAncestor) { return }
            let stamp = model.entryViewportStamp, target = model.entryTarget, bounds = scroll.contentView.bounds
            let wanted: CGFloat
            if target == "slack-bottom" { wanted = document.isFlipped ? document.bounds.maxY - bounds.height : document.bounds.minY }
            else if let frame = model.rowFrame(target) {
                wanted = target.hasPrefix(SlackModel.endMark) ? (document.isFlipped ? frame.maxY - bounds.height : frame.minY) : frame.midY - bounds.height / 2
            } else {
                try? frameLog.write(to: firstFrames, atomically: true, encoding: .utf8)
                check(false, "An exposed entry has no target geometry: \(place())"); return
            }
            let expected = min(max(wanted, document.bounds.minY), max(document.bounds.minY, document.bounds.maxY - bounds.height))
            let error = abs(bounds.minY - expected)
            maximumError = max(maximumError, error)
            if event == "expose" { entryExposures += 1 } else { visibleFrames += 1 }
            let key = "\(event):\(stamp.room ?? "nil"):\(stamp.request):\(stamp.content)"
            if recordedFrames.insert(key).inserted || error > 2 {
                frameLog += "\(event)\t\(stamp.room ?? "nil")\t\(stamp.request)\t\(stamp.content)\t\(target)\t\(bounds.minY)\t\(error)\t\(document.bounds)\t\(String(describing: model.rowFrame(target)))\t\(String(describing: model.rowFrame("slack-bottom")))\n"
            }
            if model.entryViewportPending || error > 2 || (target != "slack-bottom" && !model.threads.isEmpty && !shown(model.newestThread?.id)) {
                try? frameLog.write(to: firstFrames, atomically: true, encoding: .utf8)
                check(false, "Every first visible entry and following frame is already at the newest conversation: event=\(event), pending=\(model.entryViewportPending), error=\(error), \(place())")
            }
        }
        model.onEntryViewportVisible = { oldVisible?(); sampleEntry("expose") }
        model.onEntryViewportFrame = { oldFrame?(); sampleEntry("draw") }
        pet.onAnimationTick = { oldTick?(); sampleEntry("frame") }
        defer {
            model.onEntryViewportVisible = oldVisible; model.onEntryViewportFrame = oldFrame; pet.onAnimationTick = oldTick
            frameLog += "exposures=\(entryExposures), visibleFrames=\(visibleFrames), maximumError=\(maximumError)\n"
            try? frameLog.write(to: firstFrames, atomically: true, encoding: .utf8)
        }
        model.foldAll(animated: false)
        model.dragSidebar(to: SlackSidebar.width); await settle()
        await until("the long rooms are listed") { model.rooms.contains { $0.id == "CLONGA" } && model.rooms.contains { $0.id == "CLATE" } }

        // Narrow tab: an old post with the newest reply comes on screen, without being opened or picked.
        await clickRoom("CLONGA")
        await until("긴방A is read") { model.selected == "CLONGA" && model.threads.count >= 30 }
        await settle(1.2)
        let newestA = thread("CLONGA", SlackEntryScript.newestA), lastA = thread("CLONGA", 29)
        check(newestA != nil && model.newestThread?.id == newestA && newestA != lastA, "긴방A's newest conversation is an older post: \(String(describing: model.newestThread?.id))")
        check(shown(newestA), "Clicking 긴방A's tab shows the post with the newest reply: \(place())")
        check(!shown(lastA), "It is not just the foot of the room: \(place())")
        check(model.open.isEmpty && model.picked == nil && model.replyTo == nil, "Entering opens and picks nothing: open=\(model.open), picked=\(String(describing: model.picked))")
        capture(destination: destination.appendingPathComponent("entry-narrow"))
        // Dispatch actual keyboard input: layout-only offset changes must not impersonate a reader's scroll.
        if let scroll = model.scrollView, let document = scroll.documentView {
            let bounds = scroll.contentView.bounds
            let gestures = model.userScrolls
            let responder = panel.firstResponder
            let focus = SlackEntryScrollFocus(frame: .zero)
            document.addSubview(focus)
            check(panel.makeFirstResponder(focus), "Keyboard scrolling has a responder inside the conversation")
            let pageDown = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                           context: nil, characters: "\u{F72D}", charactersIgnoringModifiers: "\u{F72D}",
                                           isARepeat: false, keyCode: 121)!
            NSApp.postEvent(pageDown, atStart: false)
            await settle(0.1)
            check(model.userScrolls > gestures && !model.entryHolds && !model.entryViewportPending,
                  "Keyboard input cancels entry without a live-scroll notification")
            panel.makeFirstResponder(responder)
            focus.removeFromSuperview()
            let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - bounds.height) : document.bounds.minY
            scroll.contentView.scroll(to: NSPoint(x: bounds.minX, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            let reading = scroll.contentView.bounds.minY, refreshed = model.threads
            model.threads = refreshed
            await settle(0.4)
            check(!model.entryHolds && !model.entryViewportPending && scroll.alphaValue > 0.99 && abs(scroll.contentView.bounds.minY - reading) <= 2,
                  "Republishing threads preserves the keyboard reading position")
            await clickRoom("CLONGA"); await settle(1.2)
            check(shown(newestA), "Entering again restores the newest conversation after native scrolling")
        }
        if let newestA {
            await clickCard(newestA)
            check(model.open.contains(newestA), "Clicking that card opens it: open=\(model.open), picked=\(String(describing: model.picked))")
            check(model.rowFrame("message:" + (model.threads.first { $0.id == newestA }?.replies.last?.id ?? "")).map { $0.intersects(model.scrollView!.contentView.bounds) } ?? false,
                  "Its newest reply is on screen after the click: \(place())")
            capture(destination: destination.appendingPathComponent("entry-opened"))
        }

        // Round trip: the opened card and the draft stay; returning shows the opened card's newest reply.
        model.draft = "긴방A에서 쓰던 글"
        await clickRoom("CLONGB")
        await until("긴방B is read") { model.selected == "CLONGB" && model.threads.count >= 30 }
        await settle(1.2)
        let lastB = thread("CLONGB", 29)
        check(model.newestThread?.id == lastB && model.entryTarget == "slack-bottom", "In 긴방B the newest line is the last post")
        check(shown(lastB), "Clicking 긴방B shows its last post: \(place())")
        await clickRoom("CLONGA"); await settle(1.2)
        check(model.selected == "CLONGA" && model.draft == "긴방A에서 쓰던 글", "The draft comes back with its room: \(model.draft.debugDescription)")
        check(newestA.map { model.open.contains($0) } ?? false && shown(newestA), "Returning shows the opened card again: open=\(model.open), \(place())")
        model.foldAll(animated: false); await settle(0.4)

        // The same tab again, after scrolling away by hand, goes back to the newest conversation.
        scrollByHand(toTop: false); await settle(0.5)
        check(!shown(newestA), "Scrolled by hand to the foot, the conversation is off screen: \(place())")
        await clickRoom("CLONGA"); await settle(1.2)
        check(shown(newestA) && model.draft == "긴방A에서 쓰던 글", "Clicking the shown room's tab again brings it back: \(place())")

        // Keep this room's existing draft destination so later card/page checks use the same saved draft.
        // Reopening and switching back to Slack preserve that draft and its file.
        let attachment = destination.appendingPathComponent("entry-draft.txt")
        try? "보내지 않는 합성 첨부".write(to: attachment, atomically: true, encoding: .utf8)
        model.attachments = [attachment]
        scrollByHand(toTop: false); await settle(0.4)
        collapseChat(); await settle(0.7); showChat(); await settle(1.2)
        check(model.selected == "CLONGA" && shown(newestA), "Reopening brings the room's newest conversation into view: \(place())")
        check(model.draft == "긴방A에서 쓰던 글" && model.attachments == [attachment],
              "Reopening keeps the unsent draft and attachment")
        scrollByHand(toTop: false); await settle(0.4)
        if IMessageFeature.enabled { model.source = .imessage; await settle(0.4); model.source = .slack }
        else { model.select("CLONGA") }
        await settle(1.2)
        check(shown(newestA) && model.draft == "긴방A에서 쓰던 글" && model.attachments == [attachment],
              "Returning to Slack shows its newest conversation and retains the draft: \(place())")
        // Bringing an already open window forward does not reset a reader's position.
        scrollByHand(toTop: false); await settle(0.4)
        let broughtForward = model.scrollRevision, reading = model.scrollView?.contentView.bounds.minY
        showChat(); await settle(1.0)
        check(model.scrollRevision == broughtForward && model.scrollView?.contentView.bounds.minY == reading,
              "Focusing the open window preserves its reading position")
        collapseChat(); await settle(0.7); showChat(); await settle(0.35)
        scrollByHand(toTop: false)
        let manualReopen = model.scrollView?.contentView.bounds.minY ?? -1
        await settle(1.2)
        check(abs((model.scrollView?.contentView.bounds.minY ?? -100) - manualReopen) <= 2,
              "A manual scroll after reopening cancels its delayed entry passes: \(place())")
        model.attachments = []
        await clickRoom("CLONGA"); await settle(1.2)
        capture(destination: destination.appendingPathComponent("entry-reopened"))

        // Wide rows behave the same way.
        model.dragSidebar(to: SlackSidebar.expandedWidth); await settle()
        await clickRoom("CLONGB"); await settle(1.2)
        check(model.selected == "CLONGB" && shown(lastB), "A wide row enters 긴방B at its last post: \(place())")
        await clickRoom("CLONGA"); await settle(1.2)
        check(model.selected == "CLONGA" && shown(newestA) && !shown(lastA), "A wide row enters 긴방A at the post with the newest reply: \(place())")
        capture(destination: destination.appendingPathComponent("entry-wide"))
        scrollByHand(toTop: true); await settle(0.5)
        await clickRoom("CLONGA"); await settle(1.2)
        check(shown(newestA), "Clicking the shown room's row again brings it back: \(place())")

        // Quick switching ends where the last click went, not where an earlier one was still arriving.
        await clickRoom("CLONGB"); await clickRoom("CLONGA"); await clickRoom("CLONGB"); await clickRoom("CLONGA")
        await settle(1.4)
        check(model.selected == "CLONGA" && shown(newestA) && !shown(lastA), "A→B→A→B→A ends on 긴방A's newest conversation: \(place())")
        await clickRoom("CLONGB"); await clickRoom("CLONGA"); await clickRoom("CLONGB")
        await settle(1.4)
        check(model.selected == "CLONGB" && shown(lastB), "B→A→B ends on 긴방B's last post: \(place())")

        // A scroll by hand right after entering is not undone by the passes still waiting.
        // The scroll comes as soon as the click has changed the room, before the entry's passes have run.
        await clickRoom("CLONGA")
        for _ in 0..<100 where model.selected != "CLONGA" { try? await Task.sleep(nanoseconds: 5_000_000) }
        scrollByHand(toTop: true)
        let top = model.scrollView?.contentView.bounds.minY ?? -1
        await settle(1.4)
        check(abs((model.scrollView?.contentView.bounds.minY ?? -100) - top) <= 2, "A scroll by hand right after entering stays: was \(top), \(place())")

        // Clicking a card picks it and the next room entry does not take that away.
        if let first = thread("CLONGA", 0) {
            await clickCard(first)
            check(model.open.contains(first) || model.picked == first, "A card near the top answers a click: open=\(model.open), picked=\(String(describing: model.picked))")
            await settle(0.8)
            check(shown(first), "The clicked card stays in view, not pulled to the newest one: \(place())")
            model.foldAll(animated: false)
        }

        // A link to an old post goes there and the room entry does not pull it back.
        if let old = model.threads.first(where: { $0.room == "CLONGA" && $0.root.body.hasPrefix("긴방A 글 1.") }) {
            await clickRoom("CLONGB"); await settle()
            slack.follow(room: "CLONGA", ts: old.ts, url: nil)
            await settle(1.6)
            check(model.selected == "CLONGA" && shown(old.id) && model.scrollTarget == old.id, "A link to an old post stays there: \(place())")
            model.foldAll(animated: false)
        } else { check(false, "긴방A has an old post to link to") }

        // A page held in place by 새우튀김's page button gives way to a click on the room it is in.
        await clickRoom("CLONGA"); await settle(1.2)
        await until("새우튀김's page under post 15 is read") { model.threads.contains { $0.root.body.hasPrefix("긴방A 글 15.") && !$0.replies.isEmpty } }
        if let page = model.threads.first(where: { $0.room == "CLONGA" && $0.root.body.hasPrefix("긴방A 글 15.") }), let control = page.replies.first {
            // The page asked for is only noted; nothing is sent anywhere.
            var asked: [String] = []
            let (send, pageSend) = (model.onSend, model.onPageSend)
            model.onSend = { _, _, _, _ in }; model.onPageSend = { text, _, _ in asked.append(text) }
            defer { model.onSend = send; model.onPageSend = pageSend }
            model.requestScroll(page.id); await settle(1.2)
            let anchor = "page-anchor:" + control.id
            // In the native list the paged post is a SwiftUI piece hosted in the card; its frames are in that piece's own space.
            if NativeListFeature.enabled, let rect = chat.smokeFrames["ux58-page-2"], let piece = model.rowViews.object(forKey: ("line:" + control.id) as NSString), piece.window === panel {
                // Without the outer named space SwiftUI reports the piece's frames in window coordinates (top-left origin).
                let local = rect.maxX <= piece.bounds.width + 1 && rect.maxY <= piece.bounds.height + 1
                let height = panel.contentView?.bounds.height ?? 0
                let point = local ? piece.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil) : NSPoint(x: rect.midX, y: height - rect.midY)
                try? "page click local=\(local) rect=\(rect) piece=\(piece.convert(piece.bounds, to: nil)) point=\(point) hit=\(String(describing: panel.contentView?.hitTest(point).map { type(of: $0) }))\n".write(to: destination.appendingPathComponent("page-click.txt"), atomically: true, encoding: .utf8)
                post(.leftMouseDown, point); post(.leftMouseUp, point)
                try? await Task.sleep(nanoseconds: 150_000_000)
            } else if let rect = chat.smokeFrames["ux58-page-2"], let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first,
               let row = model.rowViews.object(forKey: anchor as NSString), row.window === panel {
                let point = NSPoint(x: host.convert(NSPoint(x: rect.midX, y: 0), to: nil).x, y: row.convert(NSPoint(x: 0, y: row.bounds.midY), to: nil).y)
                post(.leftMouseDown, point); post(.leftMouseUp, point)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            check(model.pageHold == anchor, "새우튀김's page button holds the view in place: \(String(describing: model.pageHold)), asked=\(asked), trusted=\(model.vault.trusted(control)), user=\(String(describing: control.slackUserID)), body=\(control.body.prefix(20)), button=\(String(describing: chat.smokeFrames["ux58-page-2"])), row=\(model.rowViews.object(forKey: anchor as NSString) != nil), \(place())")
            await clickRoom("CLONGA"); await settle(1.2)
            check(model.pageHold == nil && shown(newestA) && model.draft == "긴방A에서 쓰던 글",
                  "Clicking the room while a page is held lets go and shows its newest conversation: hold=\(String(describing: model.pageHold)), \(place())")
        } else { check(false, "긴방A has 새우튀김's page under post 15") }

        // 보류방: its replies come only when the smoke lets them, so what happens before and after is known.
        let heldName = "보류방"
        func heldThread(_ index: Int) -> SlackThread? { model.threads.first { $0.room == "CHELD" && $0.root.body.hasPrefix("\(heldName) 글 \(index).") } }
        func offset(_ id: String?) -> CGFloat? {
            guard let id, let rect = model.rowFrame(id), let scroll = model.scrollView else { return nil }
            return rect.minY - scroll.contentView.bounds.minY
        }
        // Pinned to the first place, as the user can from its menu, so its row is on screen.
        model.pin("CHELD", slot: 0); await settle(0.6)
        script.advance(to: 1)
        await clickRoom("CHELD")
        await until("보류방 is listed while post 6's replies are held") { model.selected == "CHELD" && model.threads.count >= 30 && script.waiting }
        await settle(0.6)
        guard let six = heldThread(6), let five = heldThread(5), let two0 = heldThread(2) else { check(false, "보류방 has posts 2, 5 and 6"); return }
        check(!six.loaded && model.newestThread?.id == six.id && shown(six.id), "Before its replies arrive, 보류방 shows post 6, the newest by its listing: \(place())")
        // Clicking the room again while they are held starts its entry over; picking a card that has nothing to unfold
        // asks for no place, and the replies that come after it do not move the view.
        await clickRoom("CHELD"); await settle(0.6)
        await clickCard(five.id)
        let revision = model.scrollRevision, before = offset(five.id)
        check(model.picked == five.id && model.open.isEmpty, "Clicking post 5 picks it without opening anything: picked=\(String(describing: model.picked))")
        script.letReplies()
        await until("post 6's replies are read") { heldThread(6)?.loaded == true && !script.waiting && model.threads.allSatisfy(\.loaded) }
        await settle(1.4)
        let moved = before.flatMap { b in offset(five.id).map { abs($0 - b) } } ?? .infinity
        let onScreen = model.rowFrame(five.id).map { $0.intersects(model.scrollView!.contentView.bounds) } ?? false
        check(model.scrollRevision == revision && moved <= 2 && onScreen && model.picked == five.id,
              "Replies arriving after a card was picked do not move the view: moved=\(moved), revision \(revision)→\(model.scrollRevision), \(place())")

        // Folding an opened card stands too: a reply that comes after the fold does not pull the view anywhere.
        await clickCard(six.id)
        check(model.open.contains(six.id), "Clicking post 6 opens it: open=\(model.open)")
        script.advance(to: 2)
        await until("post 2's new reply is held") { script.waiting }
        await clickRoom("CHELD"); await settle(0.6)
        check(model.open.contains(six.id) && model.newestThread?.id == two0.id && shown(two0.id), "Clicking 보류방 again keeps the open card and shows post 2, newest now: \(place())")
        // A real click on the space between two cards folds the open one.
        let visible = model.visibleThreads
        if let pair = zip(visible, visible.dropFirst()).first(where: { a, b in
               guard let x = model.rowFrame(a), let y = model.rowFrame(b), let scroll = model.scrollView else { return false }
               return y.minY - x.maxY > 8 && scroll.contentView.bounds.contains(CGPoint(x: x.midX, y: (x.maxY + y.minY) / 2)) }),
           let a = model.rowFrame(pair.0), let b = model.rowFrame(pair.1), let scroll = model.scrollView {
            let point = scroll.contentView.convert(CGPoint(x: a.midX, y: (a.maxY + b.minY) / 2), to: nil)
            post(.leftMouseDown, point); post(.leftMouseUp, point)
        }
        await settle(0.8)
        check(model.open.isEmpty, "A click between the cards folds the open one: open=\(model.open)")
        let folded = model.scrollRevision, foldedTop = model.scrollView?.contentView.bounds.minY ?? -1
        script.letReplies()
        await until("post 2's new reply is read") { heldThread(2)?.replies.isEmpty == false && !script.waiting && model.threads.allSatisfy(\.loaded) }
        await settle(1.4)
        check(model.scrollRevision == folded && abs((model.scrollView?.contentView.bounds.minY ?? -100) - foldedTop) <= 2,
              "A reply arriving after the fold does not move the view: was \(foldedTop), revision \(folded)→\(model.scrollRevision), \(place())")

        // Scrolled away by hand, clicking the room again goes to its newest conversation, and goes there once more when
        // that conversation's replies arrive while the room settles.
        script.advance(to: 3)
        await until("post 4's new reply is held") { script.waiting }
        scrollByHand(toTop: false); await settle(0.4)
        model.draft = "보류방에서 쓰던 글"
        let four = heldThread(4)?.id
        check(!shown(four), "Scrolled by hand to the foot, post 4 is off screen: \(place())")
        await clickRoom("CHELD"); await settle(0.6)
        let entered = model.scrollRevision
        check(model.newestThread?.id == four && shown(four), "Clicking 보류방 again shows post 4, newest now: \(place())")
        script.letReplies()
        await until("post 4's new reply is read") { heldThread(4)?.replies.isEmpty == false && !script.waiting && model.threads.allSatisfy(\.loaded) }
        await settle(1.4)
        let latestReply = heldThread(4)?.replies.last.map { "message:" + $0.id }
        check(model.scrollRevision > entered && shown(four) && latestReply.flatMap { model.rowFrame($0) }.map { $0.intersects(model.scrollView!.contentView.bounds) } == true,
              "The reply arriving right after the click is brought into view with its card: revision \(entered)→\(model.scrollRevision), \(place())")
        check(model.draft == "보류방에서 쓰던 글" && model.open.isEmpty && model.picked == nil, "The draft stays and nothing is opened or picked: \(model.draft.debugDescription), open=\(model.open)")
        capture(destination: destination.appendingPathComponent("entry-held"))
        model.draft = ""
        model.pin("CHELD", slot: nil); await settle(0.4)

        // An empty room is entered safely.
        model.pin("CTEAM", slot: 0); await settle(0.6)
        await clickRoom("CTEAM"); await settle(1.2)
        check(model.selected == "CTEAM" && model.threads.isEmpty && model.entryTarget == "slack-bottom", "An empty room is entered at its foot: \(model.threads.count)")

        // A room whose listing comes late shows its newest conversation once it arrives, and again once its replies are read.
        model.pin("CLATE", slot: 1); await settle(0.6)
        script.armLate()
        await clickRoom("CLATE"); await settle(0.8)
        check(model.selected == "CLATE" && model.threads.isEmpty, "늦은방 waits for its listing: \(model.threads.count)")
        collapseChat(); await settle(0.7); showChat(); await settle(0.5)
        check(model.selected == "CLATE" && model.threads.isEmpty, "Reopening an unloaded room still waits for its listing")
        script.release()
        await until("늦은방 is read") { model.threads.count >= 20 && model.threads.allSatisfy(\.loaded) }
        await settle(1.4)
        let newestLate = thread("CLATE", SlackEntryScript.newestLate)
        check(model.newestThread?.id == newestLate && shown(newestLate) && !shown(thread("CLATE", 19)), "A late listing arrives at the post with the newest reply: \(place())")
        check(model.open.isEmpty && model.picked == nil, "A late arrival opens and picks nothing")
        capture(destination: destination.appendingPathComponent("entry-late"))
        model.draft = ""
        model.pin("CTEAM", slot: nil); model.pin("CLATE", slot: nil)
        model.dragSidebar(to: SlackSidebar.width); await settle(0.4)
        check(entryExposures >= 8 && visibleFrames > 0 && maximumError <= 2,
              "First-visible checks cover room selection, reopening, source return and delayed data: exposures=\(entryExposures), frames=\(visibleFrames), maxError=\(maximumError)")
    }
}

/// `--ui-smoke-ddots --ui-smoke-ddots-entry`: the ddots workspace, with the listing of 개인비서's conversation held
/// until the smoke lets it come. Only entering and leaving the shared room is checked here.
final class DdotsEntryScript {
    static var current: DdotsEntryScript?
    private let lock = NSLock()
    private var asked = false, released = false
    private let gate = DispatchSemaphore(value: 0)
    /// True while the listing is being asked for and held back.
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return asked && !released }
    func letListing() { lock.lock(); let blocked = asked && !released; released = true; lock.unlock(); if blocked { gate.signal() } }
    var api: SlackAPI {
        let base = SlackSmokeFixture.api(ddots: true)
        return SlackAPI(transport: { [self] method, parameters in
            if method == "conversations.history", parameters["channel"] == "DJARVIS" {
                lock.lock(); let held = !released; if held { asked = true }; lock.unlock()
                if held { _ = gate.wait(timeout: .now() + 25) }
            }
            return base.transport(method, parameters)
        }, raw: base.raw)
    }
}

extension AppDelegate {
    @MainActor func verifyDdotsEntry(destination: URL, script: DdotsEntryScript) async {
        let model = slack.model
        var report = ""
        func check(_ ok: Bool, _ title: String) {
            report += "\(ok ? "PASS" : "FAIL"): \(title)\n"
            try? report.write(to: destination.appendingPathComponent("ddots-entry.txt"), atomically: true, encoding: .utf8)
            if !ok { capture(destination: destination.appendingPathComponent("ddots-entry-failure")); smokeFailed(title) }
        }
        func settle(_ seconds: Double = 0.9) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func until(_ what: String, _ condition: () -> Bool) async {
            for _ in 0..<80 where !condition() { slack.tick(); await settle(0.25) }
            check(condition(), (condition() ? "Arrived: " : "Timed out: ") + what)
        }
        func shown(_ id: String?) -> Bool {
            guard let id, let rect = model.rowFrame(id), let scroll = model.scrollView else { return false }
            return rect.intersection(scroll.contentView.bounds).height >= min(rect.height, scroll.contentView.bounds.height / 2) - 2
        }
        /// At the newest line as the app itself counts it: close enough that new lines are followed. A "생각 중" line
        /// in this workspace keeps the foot moving by a few points.
        func atFoot() -> Bool { (model.place()?.fromBottom ?? .infinity) <= SlackModel.followDistance }
        func place() -> String { "viewport=\(model.scrollView.map { "\($0.contentView.bounds)" } ?? "none"), fromBottom=\(model.place()?.fromBottom ?? -1), visible=\(model.visibleThreads.suffix(3)), target=\(model.scrollTarget), alpha=\(model.scrollView?.alphaValue ?? -1), pending=\(model.entryViewportPending), document=\(String(describing: model.scrollView?.documentView?.bounds)), last=\(String(describing: model.threads.last.flatMap { model.rowFrame($0.id) })), bottom=\(String(describing: model.rowFrame("slack-bottom")))" }
        let previousVisible = model.onEntryViewportVisible
        var firstExposures = 0
        model.onEntryViewportVisible = {
            previousVisible?()
            guard model.isDdots, model.entryTarget == "slack-bottom", let scroll = model.scrollView,
                  let document = scroll.documentView else { return }
            let gap = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.maxY
                : scroll.contentView.bounds.minY - document.bounds.minY
            firstExposures += 1
            check(!model.entryViewportPending && scroll.alphaValue > 0.99 && abs(gap) <= 2,
                  "workspace's first visible entry is at its newest line: gap=\(gap), pending=\(model.entryViewportPending)")
        }
        defer { model.onEntryViewportVisible = previousVisible }
        func clickRoom(_ room: String) async {
            guard let frame = chat.smokeFrames["room-" + room], frame.height > 4,
                  let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first else { check(false, "Room \(room) is drawn in the sidebar"); return }
            let point = host.convert(CGPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        func scrollByHand(toTop: Bool) {
            guard let scroll = model.scrollView, let document = scroll.documentView else { return }
            let end = max(0, document.bounds.maxY - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: (document.isFlipped ? toTop : !toTop) ? 0 : end)); scroll.reflectScrolledClipView(scroll.contentView)
            model.userScrolls += 1
        }
        func last() -> String? { model.threads.last { !$0.ts.isEmpty }?.id }

        // The shared room is shown first; one character's conversation comes late, after the smoke lets it.
        await until("개인비서's conversation is being listed") { model.isDdots && model.selected == Ddots.room && script.waiting }
        let early = model.threads.count
        script.letListing()
        await until("every conversation in workspace is read") { !script.waiting && model.threads.count > early && model.threads.contains { $0.room == "DJARVIS" } && model.threads.allSatisfy(\.loaded) }
        check(model.entryTarget == "slack-bottom", "workspace, kept in order of activity, is entered at its foot")
        await settle(1.4)
        check(atFoot() && shown(last()), "Replies that come late still leave workspace at its newest line: \(place())")
        capture(destination: destination.appendingPathComponent("ddots-entry-late"))

        // To a channel and back.
        model.draft = "workspace에서 쓰던 글"
        await clickRoom("CCOW")
        await until("SNS담당방 is read") { model.selected == "CCOW" && !model.threads.isEmpty && model.threads.allSatisfy(\.loaded) }
        await settle(1.2)
        check(shown(model.newestThread?.id), "Clicking SNS담당방 shows its newest conversation: newest=\(String(describing: model.newestThread?.id)), \(place())")
        await clickRoom(Ddots.room); await settle(1.2)
        check(model.isDdots && atFoot() && shown(last()), "Clicking workspace brings back its newest line: \(place())")
        check(model.draft == "workspace에서 쓰던 글", "workspace's draft comes back with it: \(model.draft.debugDescription)")

        // Scrolled up by hand, a click on the shared room's tab goes back to its newest line.
        scrollByHand(toTop: true); await settle(0.5)
        let scrollable = !atFoot()
        await clickRoom(Ddots.room); await settle(1.2)
        check(atFoot() && shown(last()), "Clicking workspace again after scrolling up returns to its newest line (scrolled away first: \(scrollable)): \(place())")
        // A scroll by hand right after the click is kept.
        await clickRoom("CCOW"); await settle(1.0); await clickRoom(Ddots.room)
        for _ in 0..<100 where !model.isDdots { try? await Task.sleep(nanoseconds: 5_000_000) }
        scrollByHand(toTop: true)
        let top = model.scrollView?.contentView.bounds.minY ?? -1
        await settle(1.4)
        check(abs((model.scrollView?.contentView.bounds.minY ?? -100) - top) <= 2, "A scroll by hand right after entering workspace stays: was \(top), \(place())")
        check(firstExposures > 0, "workspace's first visible entry was observed: \(firstExposures)")
        model.draft = ""
        report += "PASS: entering workspace and a channel shows the newest conversation.\n"
        try? report.write(to: destination.appendingPathComponent("ddots-entry.txt"), atomically: true, encoding: .utf8)
        capture(destination: destination)
        NSApp.terminate(nil)
    }
}
