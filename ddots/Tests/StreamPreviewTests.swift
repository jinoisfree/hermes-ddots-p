import Foundation

@main struct StreamPreviewTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let root = ChatMessage(id: "root", fromUser: true, speaker: "사용자", body: "질문", date: Date(timeIntervalSince1970: 989), profile: "me")
        let spinner = ChatMessage(id: "spinner", fromUser: false, speaker: "개인비서", body: "◐ 생각 중...", date: Date(timeIntervalSince1970: 991), profile: "personal-secretary")
        let base = SlackThread(id: "C1:100.1", room: "C1", ts: "100.1", root: root, replies: [spinner], replyCount: 1, loaded: true, latest: 991, latestFromUser: false)
        var p = StreamPreview(id: "first", room: "C1", thread: "100.1", since: 990, updated: 1000, expires: 1120, body: "첫 줄\n둘째 줄", done: false, profile: "personal-secretary")
        func apply(_ t: SlackThread = base, _ previews: [StreamPreview]? = nil) -> SlackThread {
            StreamPreview.applying(previews ?? [p], to: t, names: [:], now: now)
        }
        let streamed = apply()
        precondition(streamed.replies.count == 1 && streamed.replies[0].id == spinner.id)
        precondition(streamed.replies[0].body == p.body && streamed.replies[0].streaming)
        precondition(AgentStop.working(streamed, typing: []))
        precondition(base.replies[0].body == spinner.body) // The authoritative record was not changed.
        p.status = "waiting"; p.input_id = "m2"
        precondition(apply().replies[0].body.hasPrefix("추가 지시 반영 대기\n\n"))
        p.status = "applying"
        precondition(apply().replies[0].body.hasPrefix("추가 지시 반영 중\n\n"))
        let decoded = try JSONDecoder().decode(StreamPreview.self, from: JSONEncoder().encode(p))
        precondition(decoded.status == "applying" && decoded.input_id == "m2")
        p.status = nil; p.input_id = nil
        var completed = base; completed.replies[0].body = "최종 답변 및 승인 버튼"
        precondition(apply(completed) == completed)
        var early = base
        early.replies[0].date = Date(timeIntervalSince1970: 989.5)
        let earlyPreview = apply(early)
        precondition(earlyPreview.replies.count == 1 && earlyPreview.replies[0].id == spinner.id)
        early.replies[0].body = "최종 답변 — Slack은 작성중 메시지의 시각을 유지한다"
        precondition(apply(early) == early)
        var background = p; background.updated = 1002; background.body = "후속 내부 호출의 본문"
        precondition(apply(early, [background]) == early)
        var previousTurn = base
        var old = spinner; old.id = "old"; old.date = Date(timeIntervalSince1970: 988); old.body = "지난 요청의 답변"
        previousTurn.replies.insert(old, at: 0)
        precondition(apply(previousTurn).replies.count == 2)
        precondition(apply(previousTurn).replies.last?.streaming == true)
        var other = base; other.room = "C2"
        precondition(apply(other) == other)
        other = base; other.ts = "other"
        precondition(apply(other) == other)
        var expired = p; expired.expires = 999
        precondition(apply(base, [expired]) == base)
        var replacement = p; replacement.id = "next"; replacement.updated = 1001; replacement.body = "새 문장"
        precondition(apply(base, [p, replacement]).replies.count == 1)
        precondition(apply(base, [p, replacement]).replies[0].body == "새 문장")
        var absent = base; absent.replies = []; absent.replyCount = 0
        precondition(apply(absent).replies.count == 1)
        precondition(apply(absent).replies[0].id == "stream:first")
        precondition(apply(base, []) == base)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("profiles/personal-secretary/cache/ddots-streams")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        p.profile = nil
        try JSONEncoder().encode(p).write(to: cache.appendingPathComponent("sample.json"))
        try Data("unfinished json".utf8).write(to: cache.appendingPathComponent("broken.json"))
        let read = StreamPreview.read(home: folder, now: now)
        precondition(read.count == 1 && read[0].profile == "personal-secretary")
        precondition(StreamPreview.read(home: folder, now: Date(timeIntervalSince1970: 1200)).isEmpty)
        var reveal = StreamReveal()
        var growing = p; growing.body = "한글🙂 자연스럽게 이어지는 답변입니다."
        reveal.receive([growing], now: 0)
        let firstFrame = reveal.frame(now: 0)[0].body
        let middleFrame = reveal.frame(now: 0.1)[0].body
        precondition(firstFrame.count < middleFrame.count && middleFrame.count < growing.body.count)
        precondition(growing.body.hasPrefix(middleFrame))
        precondition(reveal.frame(now: 0.4)[0].body == growing.body && !reveal.pending)
        growing.body += " 추가 문장"
        reveal.receive([growing], now: 1)
        precondition(reveal.frame(now: 1)[0].body.hasPrefix(middleFrame))
        precondition(reveal.frame(now: 1, immediately: true)[0].body == growing.body)
        growing.body = "수정된 응답"
        reveal.receive([growing], now: 2)
        precondition(reveal.frame(now: 2)[0].body == growing.body)
        growing.body = "수정된 응답입니다["; growing.updated += 1
        reveal.receive([growing], now: 2.1)
        _ = reveal.frame(now: 2.48)
        growing.body.removeLast(); growing.updated += 1
        reveal.receive([growing], now: 2.5)
        precondition(reveal.frame(now: 2.5)[0].body == growing.body, "filtered suffix must not erase and replay the whole answer")
        var stale = growing; stale.updated -= 1; stale.body = "수"
        reveal.receive([stale], now: 2.6)
        precondition(reveal.frame(now: 2.6)[0].body == growing.body, "stale snapshots cannot shrink visible text")
        reveal.receive([], now: 3)
        precondition(reveal.frame(now: 3).isEmpty && !reveal.pending)
        var burst = p; burst.profile = "personal-secretary"; burst.body = String(repeating: "가나다라마바사 ", count: 100)
        var smooth = StreamReveal()
        smooth.receive([burst], now: 10)
        let partial = smooth.frame(now: 10.5)[0]
        precondition(partial.body.count > 1 && partial.body.count < burst.body.count)
        let finalDuringReveal = apply(completed, [partial])
        precondition(finalDuringReveal.replies.count == 1 && finalDuringReveal.replies[0].id == spinner.id)
        precondition(finalDuringReveal.replies[0].body != completed.replies[0].body)
        precondition(completed.replies[0].body == "최종 답변 및 승인 버튼")
        smooth.receive([], now: 10.6)
        precondition(!smooth.frame(now: 10.7).isEmpty, "preview removal must not interrupt a pending reveal")
        let finished = smooth.frame(now: 13.1)
        precondition(!smooth.pending && apply(completed, finished) == completed)
        smooth.receive([], now: 13.2)
        precondition(smooth.frame(now: 13.2).isEmpty)
        precondition(StreamReveal.visiblePrefix("본문<span style=\"font-size:20") == "본문")
        precondition(StreamReveal.visiblePrefix("본문<span>제목") == "본문<span>제목")
        precondition(StreamReveal.visiblePrefix("비교 1 < 2") == "비교 1 < 2")
        print("Stream previews: replacement, completion, isolation, expiry, corruption and private file reading passed")
    }
}
