import AppKit

extension AppDelegate {
    /// Large, entirely synthetic snapshot. No Slack transport or user account is opened.
    func verifyPublish(destination: URL) {
        Task { @MainActor [self] in
            smokeCheck(isSmoke && !slack.persists, "Publish benchmark is isolated")
            var snapshot = SlackBridge.Snapshot()
            snapshot.status = .connected
            for roomIndex in 0..<30 {
                let room = "SYNTH\(roomIndex)"
                snapshot.rooms.append(SlackRoom(id: room, name: "Synthetic \(roomIndex)"))
                snapshot.members[room] = [SlackMember(profile: "", name: "Synthetic")]
                snapshot.threads[room] = (0..<50).map { threadIndex in
                    let stamp = 1_700_000_000 + Double(roomIndex*100_000+threadIndex*100)
                    let ts = String(stamp)
                    let root = ChatMessage(id: "slack:\(room):\(ts)", fromUser: false, speaker: "Synthetic", body: "Synthetic root", date: Date(timeIntervalSince1970: stamp))
                    let replies: [ChatMessage] = (1...30).map { index in
                        let mine = index%2 == 0 && index != 30
                        let body = index == 30 ? "확인 후 승인해줘" : "Synthetic reply \(index)"
                        return ChatMessage(id: "slack:\(room):\(stamp+Double(index))", fromUser: mine, speaker: "Synthetic", body: body, date: Date(timeIntervalSince1970: stamp+Double(index)))
                    }
                    return SlackThread(id: root.id, room: room, ts: ts, root: root, replies: replies, replyCount: replies.count, loaded: true, latest: stamp+30, latestFromUser: false)
                }
            }
            slack.model.selected = "SYNTH0"
            slack.acceptSnapshot(snapshot)
            var rows: [[String: Any]] = []
            var prepared = SlackPublishCache()
            func prepare(_ value: SlackBridge.Snapshot) async -> SlackPublishCache {
                let previous = prepared
                return await withCheckedContinuation { continuation in
                    slack.queue.async {
                        var next = previous
                        next.prepare(value.threads, excluding: [])
                        continuation.resume(returning: next)
                    }
                }
            }
            for opened in [false, true] {
                if opened { showChat() } else { collapseChat() }
                try? await Task.sleep(nanoseconds: 900_000_000)
                for index in 0..<3 {
                    let count = slack.publishCount
                    let start = StallTrace.now
                    let changed = slack.acceptSnapshot(snapshot)
                    smokeCheck(!changed && slack.publishCount == count, "Unchanged snapshot does not publish")
                    rows.append(["kind": "unchanged", "open": opened, "ms": (StallTrace.now-start)*1000, "publishes": slack.publishCount-count])
                    var thread = snapshot.threads["SYNTH0"]![0]
                    let stamp = thread.latest+1
                    thread.replies.append(ChatMessage(id: "slack:SYNTH0:\(stamp)", fromUser: false, speaker: "Synthetic", body: "New synthetic reply \(index)", date: Date(timeIntervalSince1970: stamp)))
                    thread.latest = stamp; thread.replyCount += 1; thread.latestFromUser = false
                    snapshot.threads["SYNTH0"]![0] = thread
                    smokeCheck(snapshot.changedFields(from: slack.snapshot) == ["threads"], "Reply changes only the threads field")
                    let preparation = StallTrace.now
                    prepared = await prepare(snapshot)
                    let preparationMS = (StallTrace.now-preparation)*1000
                    let response = StallTrace.now
                    slack.acceptSnapshot(snapshot, prepared: prepared)
                    let sections = slack.publishSections
                    let display = StallTrace.now
                    pet.layoutSubtreeIfNeeded()
                    CATransaction.flush()
                    rows.append(["kind": "reply", "open": opened, "sections_ms": sections, "prepare_ms": preparationMS, "display_ms": (StallTrace.now-display)*1000, "response_ms": (StallTrace.now-response)*1000])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            // Isolate the real-account trigger: only one remote read stamp changes.
            for opened in [false, true] {
                if opened { showChat() } else { collapseChat() }
                try? await Task.sleep(nanoseconds: 900_000_000)
                for index in 0..<6 {
                    SlackInputSmoke.bodies = 0; SlackInputSmoke.conversations = 0; SlackInputSmoke.threads = 0; SlackInputSmoke.lines = 0
                    SlackInputSmoke.measuring = true
                    let thread = snapshot.threads["SYNTH0"]![index + (opened ? 6 : 0)]
                    smokeCheck(slack.model.bells[thread.id] == true, "Read fixture starts with an unread approval bell")
                    let beforeNotices = slack.model.notices
                    let other = snapshot.threads["SYNTH0"]![49]
                    let rowMemo = slack.model.renderedThreads.first { $0.thread.id == thread.id }!
                    let otherMemo = slack.model.renderedThreads.first { $0.thread.id == other.id }!
                    let oldRow = slack.model.rowInputs(rowMemo, chat: chat, dark: false, reduceMotion: false, target: false)
                    let oldOther = slack.model.rowInputs(otherMemo, chat: chat, dark: false, reduceMotion: false, target: false)
                    snapshot.threadRead[thread.id] = (snapshot.threadRead[thread.id] ?? thread.latest) + 1
                    smokeCheck(snapshot.changedFields(from: slack.snapshot) == ["threadRead"], "Read benchmark changes only one read stamp")
                    let start = StallTrace.now
                    slack.acceptSnapshot(snapshot)
                    let sections = slack.publishSections
                    smokeCheck(slack.model.bells[thread.id] == false && slack.model.notices != beforeNotices, "One read stamp changes the bell and notice contents")
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async {
                            self.pet.layoutSubtreeIfNeeded(); CATransaction.flush(); continuation.resume()
                        }
                    }
                    let elapsed = (StallTrace.now-start)*1000
                    smokeCheck(oldRow != slack.model.rowInputs(rowMemo, chat: chat, dark: false, reduceMotion: false, target: false), "Changed bell invalidates its own row")
                    smokeCheck(oldOther == slack.model.rowInputs(otherMemo, chat: chat, dark: false, reduceMotion: false, target: false), "Changed bell preserves unrelated row inputs")
                    rows.append(["kind": "threadRead", "open": opened, "response_ms": elapsed, "sections_ms": sections,
                                 "body_calls": SlackInputSmoke.bodies, "conversation_calls": SlackInputSmoke.conversations, "thread_calls": SlackInputSmoke.threads, "line_calls": SlackInputSmoke.lines])
                    SlackInputSmoke.measuring = false
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            let data = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: destination.appendingPathComponent("publish.json"))
            let pictured = snapshot.threads["SYNTH0"]![12]
            slack.model.requestScroll(pictured.id)
            try? await Task.sleep(nanoseconds: 800_000_000)
            smokeCheck(slack.model.bells[pictured.id] == true, "Pictured row starts unread")
            capture(destination: destination.appendingPathComponent("read-before"))
            snapshot.threadRead[pictured.id] = pictured.latest+1
            slack.acceptSnapshot(snapshot)
            try? await Task.sleep(nanoseconds: 400_000_000)
            smokeCheck(slack.model.bells[pictured.id] == false, "Pictured row becomes read")
            capture(destination: destination.appendingPathComponent("read-after"))
            capture(destination: destination.appendingPathComponent("read-rows"))
            NSApp.terminate(nil)
        }
    }
}
