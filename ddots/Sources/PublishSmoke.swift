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

/// Anonymous counts, collected read-only from the installed app. No real message or identity is a fixture input.
private struct PublishScale: Decodable {
    struct Thread: Decodable {
        let rootCharacters: Int, replyCharacters: [Int], declaredReplies: Int, cachedReplies: Int, loadedCount: Int
        let userMessageCount: Int, rootUserCount: Int, latestUserCount: Int, workingCount: Int, closedCount: Int
        let dismissedCount: Int, recentRootCount: Int, alertCount: Int, questionCount: Int
    }
    struct Room: Decodable {
        let directCount: Int, ddotsMemberCount: Int, hubCount: Int, threadCount: Int, replyCount: Int
        let alertThreads: Int, questionThreads: Int, otherNoticeThreads: Int
        let threads: [Thread]
    }
    let roomCount: Int, threadCount: Int, replyCount: Int, alertThreads: Int, questionThreads: Int
    let rooms: [Room]
}

extension AppDelegate {
    /// T-11: the actual publish engine runs while a 36-line synthetic answer unfolds.
    @MainActor func verifyScaledPublishStreaming(destination: URL, scaleURL: URL) async {
        smokeCheck(isSmoke && !slack.persists && Ddots.enabled, "Scaled publish is synthetic and ddots is enabled")
        let scale = try! JSONDecoder().decode(PublishScale.self, from: Data(contentsOf: scaleURL))
        smokeCheck(scale.rooms.count == scale.roomCount, "Anonymous room count matches")
        // No record/transport activity is part of this in-memory workload.
        slack.archive = nil; slack.recordWriter = nil; slack.keepsRecord = false; slack.kept = [:]
        slack.dismissed = [:]; slack.confirmed = [:]; slack.lastRead = [:]
        let ownerCount = scale.rooms.reduce(0) { $0 + $1.ddotsMemberCount }
        let cast = (0..<max(1, ownerCount)).map { ChatCharacter(id: "synthetic-owner-\($0)", name: "합성 직원 \($0)") }
        slack.characters = cast
        var snapshot = SlackBridge.Snapshot(); snapshot.status = .connected
        let now = Date().timeIntervalSince1970
        func body(_ count: Int, seed: Int) -> String {
            let phrase = "합성 자료 \(seed). 검토한 결과와 다음 항목을 안내합니다. "
            return String(String(repeating: phrase, count: max(1, count / phrase.count + 1)).prefix(max(1, count)))
        }
        var owner = 0
        for (roomIndex, roomScale) in scale.rooms.enumerated() {
            let room = "SYNTH-\(roomIndex)"
            snapshot.rooms.append(SlackRoom(id: room, name: "합성 방 \(roomIndex)", direct: roomScale.directCount > 0))
            let profile = roomScale.ddotsMemberCount > 0 ? cast[owner].id : ""
            let name = roomScale.ddotsMemberCount > 0 ? cast[owner].name : "합성 작성자"
            if roomScale.ddotsMemberCount > 0 { owner += 1 }
            snapshot.members[room] = [SlackMember(profile: profile, name: name)]
            snapshot.threads[room] = roomScale.threads.enumerated().map { index, counts in
                let age = counts.recentRootCount > 0 ? 3600.0 : 3 * 86_400.0
                let stamp = now - age + Double(index) / 100
                let ts = String(format: "%.6f", stamp)
                var root = ChatMessage(id: "slack:\(room):thread-\(index)", fromUser: counts.rootUserCount > 0,
                    speaker: name, body: body(counts.rootCharacters, seed: index), date: Date(timeIntervalSince1970: stamp), profile: profile)
                var replies = counts.replyCharacters.enumerated().map { offset, length in
                    ChatMessage(id: "slack:\(room):thread-\(index):reply-\(offset)", fromUser: offset < max(0, counts.userMessageCount - counts.rootUserCount),
                        speaker: name, body: body(length, seed: offset), date: Date(timeIntervalSince1970: stamp + Double(offset + 1)), profile: profile)
                }
                if !replies.isEmpty { replies[replies.count - 1].fromUser = counts.latestUserCount > 0 }
                if counts.workingCount > 0 { root.hermesReplyState = .working }
                else if counts.closedCount > 0 { root.hermesReplyState = .closed }
                if counts.questionCount > 0 { root.hermesReplyState = .asking; root.body += "\n승인해줘" }
                let latest = replies.last?.date.timeIntervalSince1970 ?? stamp
                let result = SlackThread(id: root.id, room: room, ts: ts, root: root, replies: replies,
                    replyCount: counts.declaredReplies, loaded: counts.loadedCount > 0, latest: latest, latestFromUser: counts.latestUserCount > 0)
                if counts.dismissedCount > 0 { slack.dismissed[result.id] = latest }
                return result
            }
            slack.lastRead[room] = now - 86_400
        }
        smokeCheck(snapshot.threads.values.reduce(0) { $0 + $1.count } == scale.threadCount &&
                   snapshot.threads.values.flatMap { $0 }.reduce(0) { $0 + $1.replies.count } == scale.replyCount,
                   "Synthetic thread and reply counts match the read-only census")
        slack.model.selected = Ddots.room
        slack.acceptSnapshot(snapshot)
        try? await Task.sleep(nanoseconds: 700_000_000)
        // Use one already counted reply for the writer, retaining a single identity through the final arrival.
        guard let room = slack.model.ddotsShown.first(where: { snapshot.threads[$0]?.contains(where: { !$0.replies.isEmpty }) == true }),
              let threadIndex = snapshot.threads[room]?.lastIndex(where: { !$0.replies.isEmpty }) else { smokeFailed("Scale contains a shown reply") }
        var thread = snapshot.threads[room]![threadIndex]
        let replyIndex = thread.replies.count - 1
        let writerID = thread.replies[replyIndex].id
        let profile = snapshot.members[room]!.first!.profile
        thread.replies[replyIndex].body = "◐ 생각 중..."
        thread.replies[replyIndex].date = Date(timeIntervalSince1970: now - 1)
        thread.replies[replyIndex].fromUser = false; thread.replies[replyIndex].profile = profile
        thread.replies[replyIndex].hermesReplyState = nil
        thread.latest = now - 1; thread.latestFromUser = false
        snapshot.threads[room]![threadIndex] = thread
        slack.acceptSnapshot(snapshot); slack.model.requestScroll("slack-bottom")
        try? await Task.sleep(nanoseconds: 700_000_000)
        let watching = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "scaled publish streaming smoke")
        defer { ProcessInfo.processInfo.endActivity(watching) }
        let text = (1...36).map { "\($0). 최종 메시지까지 이어지는 합성 답변과 검토 결과입니다. [자료 \($0)](https://example.com/\($0))" }.joined(separator: "\n")
        let characters = Array(text)
        var preview = StreamPreview(id: "synthetic-scaled-stream", room: room, thread: thread.ts, since: now - 2,
            updated: now, expires: now + 120, body: "첫 글자", done: false, profile: profile)
        preview.execution = "합성 답변 수신 중"
        // Each delivery is accompanied by the real publish triggers from the incident: threads and remote reads.
        let carrierIndex = snapshot.threads[room]!.indices.first { $0 != threadIndex }!
        var samples: [[String: Double]] = []
        var publications: [[String: Any]] = []
        let threadIDs = Set(snapshot.threads.values.flatMap { $0.map(\.id) })
        let roomIDs = Set(snapshot.rooms.map(\.id))
        let readAliases = Dictionary(uniqueKeysWithValues: snapshot.threads.values.flatMap { $0.map { ($0.room + ":" + $0.ts, $0.id) } })
        func privateValue<T>(_ name: String, as type: T.Type) -> T {
            guard let value = Mirror(reflecting: slack).children.first(where: { $0.label == name })?.value as? T else {
                smokeFailed("Publish contract field exists: " + name)
            }
            return value
        }
        func relative(_ values: [String: Double], keys: Set<String>) -> [String: Double] {
            values.filter { keys.contains($0.key) }.mapValues { (($0 - now) * 1000).rounded() / 1000 }
        }
        func threadReceipts(_ values: [String: Double]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: relative(values, keys: Set(readAliases.keys)).map { (readAliases[$0.key]!, $0.value) })
        }
        func publication() -> [String: Any] {
            // Read-only inspection of the synthetic controller's private contract fields; no production API is added.
            let remote: [String: Double] = privateValue("remoteQuiet", as: [String: Double].self)
            let rooms: Set<String> = privateValue("readRooms", as: Set<String>.self)
            let threads: Set<String> = privateValue("readThreads", as: Set<String>.self)
            return ["notices": slack.model.notices.map { ["id": $0.id, "title": $0.title, "color": $0.color, "threads": $0.threads] as [String: Any] },
                "roomNotices": slack.model.roomNotices.mapValues { ["alerts": $0.alerts, "questions": $0.questions] },
                "bells": slack.model.bells, "unread": slack.model.unread,
                "lastRead": relative(slack.lastRead, keys: roomIDs), "localRead": relative(slack.localRead, keys: roomIDs),
                "localThreads": threadReceipts(slack.localThreads), "threadRead": relative(snapshot.threadRead, keys: threadIDs),
                "readRooms": rooms.intersection(roomIDs).sorted(), "readThreads": threads.compactMap { readAliases[$0] }.sorted(),
                "remoteQuiet": relative(remote, keys: threadIDs), "dismissed": relative(slack.dismissed, keys: threadIDs)]
        }
        var sent = 0, step = 0
        while sent < characters.count {
            sent = min(characters.count, sent + 45); step += 1
            preview.body = String(characters.prefix(sent)); preview.updated = Date().timeIntervalSince1970; preview.expires = preview.updated + 120
            slack.model.receiveStreams([preview])
            if step % 2 == 0 {
                snapshot.threads[room]![carrierIndex].root.body = body(scale.rooms[Int(room.dropFirst(6))!].threads[carrierIndex].rootCharacters, seed: step)
                snapshot.threads[room]![carrierIndex].latest += 0.001
            } else {
                let carrier = snapshot.threads[room]![carrierIndex]
                snapshot.threadRead[carrier.id] = carrier.latest + (step % 4 == 1 ? 1 : -1)
            }
            smokeCheck(slack.acceptSnapshot(snapshot), "Synthetic delivery invokes the actual publish path")
            samples.append(slack.publishSections); publications.append(publication())
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        preview.done = true; slack.model.receiveStreams([preview])
        thread.replies[replyIndex].body = text; thread.replies[replyIndex].hermesButtons = ["확인"]
        snapshot.threads[room]![threadIndex] = thread
        slack.acceptSnapshot(snapshot); samples.append(slack.publishSections); publications.append(publication())
        slack.model.receiveStreams([])
        try? await Task.sleep(nanoseconds: 3_200_000_000)
        smokeCheck(slack.model.renderedThreads.contains { $0.thread.messages.contains { $0.id == writerID && $0.body == text && !$0.streaming } },
                   "Scaled stream reaches its single finalized message")
        func summary(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            func rank(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
            return ["p50_ms": rank(0.5), "p95_ms": rank(0.95), "max_ms": sorted.last!,
                    "ge16ms": Double(values.filter { $0 >= 16 }.count), "ge50ms": Double(values.filter { $0 >= 50 }.count)]
        }
        let names = Set(samples.flatMap { $0.keys })
        let summaries = Dictionary(uniqueKeysWithValues: names.map { name in (name, summary(samples.compactMap { $0[name] })) })
        let result: [String: Any] = ["publishCount": samples.count, "sections": summaries, "samples_ms": samples,
            "roomCount": scale.roomCount, "threadCount": scale.threadCount, "replyCount": scale.replyCount,
            "ddotsRoomCount": slack.model.ddotsShown.count, "selectedThreadCount": slack.model.threads.count]
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("scaled-publish.json"))
        let contract = try! JSONSerialization.data(withJSONObject: publications, options: [.sortedKeys, .prettyPrinted])
        try! contract.write(to: destination.appendingPathComponent("publications.json"))
        if let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-publish-reference"), index + 1 < CommandLine.arguments.count {
            let original = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
            let expected = try! JSONSerialization.data(withJSONObject: original, options: [.sortedKeys, .prettyPrinted])
            smokeCheck(contract == expected, "T-13 all publish results match the recorded unchanged engine")
        }
        capture(destination: destination.appendingPathComponent("scaled-final"))
        print("Scaled publish streaming passed; total \(summaries["total"]!)")
        NSApp.terminate(nil)
    }
}
