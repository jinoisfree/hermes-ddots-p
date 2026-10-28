import AppKit

/// `--ui-smoke-ddots --ui-smoke-record-memory`: what the record holds in memory stays near the two newest months.
/// The Mac that keeps the record reads only those at start, and an older month only when a line of it is to be written,
/// still without writing a line twice. Months read further back, and Slack's longer listings, are let go on leaving the room.
extension AppDelegate {
    @MainActor func verifyRecordMemory(destination: URL) async {
        func check(_ condition: Bool, _ message: String) { if !condition { smokeFailed(message) } }
        func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }
        func until(_ what: String, _ condition: () -> Bool) async {
            for _ in 0..<80 where !condition() { slack.tick(); await settle() }
            check(condition(), "Timed out: " + what)
        }
        await ensureDdotsSmoke(destination: destination)
        let model = slack.model
        guard let shelf = slack.archive else { smokeFailed("The check keeps a record") }
        guard let original = shelf.months().first.flatMap({ shelf.read(month: $0).first }) else { smokeFailed("The check's record has an oldest month") }
        let oldest = DdotsArchive.month(Date(timeIntervalSince1970: original.at))
        func held() -> [DdotsLine] { slack.kept.values.flatMap { $0 } }
        await until("the record is read at start") { !slack.loadingKept && !slack.keptMonths.isEmpty && slack.recordWriter != nil }
        check(!slack.keptMonths.contains(oldest) && slack.recordWriter?.unread == [oldest] && !held().contains { $0.text.contains("석 달 전") },
              "At start only the two newest months are read; the oldest is left on file: \(slack.keptMonths) unread \(String(describing: slack.recordWriter?.unread))")
        var lines = ["start months \(slack.keptMonths) unread \(slack.recordWriter?.unread.sorted() ?? [])"]

        // Further back, then out of the room and in again: the month read further back is let go.
        while !slack.keptMonths.contains(oldest), model.hasOlder {
            let before = slack.keptMonths
            model.onOlder?()
            await until("an older month is read") { !slack.loadingKept && (slack.keptMonths != before || !model.hasOlder) }
            if slack.keptMonths == before { break }
        }
        check(slack.keptMonths.contains(oldest) && held().contains { $0.text.contains("석 달 전") }, "이전 글 보기 reads the oldest month: \(slack.keptMonths)")
        lines.append("after older \(slack.keptMonths)")
        model.select("CCOW"); await settle()
        model.onOlder?(); model.onOlder?()
        await until("the longer listing is asked for") { (slack.limits["CCOW"] ?? 0) > SlackBridge.pageSize }
        let longer = slack.limits["CCOW"] ?? 0
        model.select(Ddots.room); await settle()
        check(slack.keptMonths.first == slack.keptFloor && !slack.keptMonths.contains(oldest) && !held().contains { $0.text.contains("석 달 전") } && model.hasOlder,
              "Out of the room and back, only the two newest months stay, with the rest still behind 이전 글 보기: \(slack.keptMonths)")
        check(slack.limits["CCOW"] == nil, "Leaving a Slack room puts its listing back to the usual size: was \(longer), now \(String(describing: slack.limits["CCOW"]))")
        lines.append("after leaving \(slack.keptMonths) CCOW limit \(longer) -> \(slack.limits["CCOW"].map(String.init) ?? "usual")")

        // A line of the month that is not read back: the one already written is not written again, a new one is written once.
        func message(_ ts: String, _ at: Double, _ body: String) -> ChatMessage {
            ChatMessage(id: "slack:Dassistant:" + ts, fromUser: false, speaker: "개인비서", body: body, date: Date(timeIntervalSince1970: at), sessionID: original.thread)
        }
        // The line already written, as Slack gives it again, and a reply under it said later the same month.
        slack.record(scanned: ["Dassistant": [message(original.ts, original.at, original.text), message(String(format: "%.6f", original.at + 60), original.at + 60, "석 달 전에 덧붙인 말이야.")]])
        await until("the waiting lines are written") { slack.recordWaiting.isEmpty && !slack.readingBack && !slack.recordWriting && slack.recordBacklog.isEmpty }
        slack.fileQueue.sync {}
        let month = shelf.read(month: oldest)
        let raw = (try? FileManager.default.contentsOfDirectory(at: shelf.root.appendingPathComponent(DdotsArchive.records), includingPropertiesForKeys: nil))?
            .compactMap { try? String(contentsOf: $0.appendingPathComponent(oldest + ".jsonl"), encoding: .utf8) }.joined() ?? ""
        let rows = raw.split(separator: "\n")
        check(rows.filter { $0.contains("석 달 전에 정리한 일정표야") }.count == 1 && rows.filter { $0.contains("석 달 전에 덧붙인 말이야") }.count == 1
              && month.contains { $0.text == "석 달 전에 덧붙인 말이야." } && slack.recordWriter?.unread.isEmpty == true,
              "The oldest month is read back before writing: nothing twice, the new line once: \(rows.map { $0.prefix(160) })")
        check(!slack.keptMonths.contains(oldest), "Writing a line of a month not shown does not read it into memory again")
        lines.append("oldest month rows \(rows.count), unread after \(slack.recordWriter?.unread.sorted() ?? [])")
        try? (lines.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("record-memory.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
