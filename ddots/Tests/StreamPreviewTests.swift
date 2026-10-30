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
        print("Stream previews: replacement, completion, isolation, expiry, corruption and private file reading passed")
    }
}
