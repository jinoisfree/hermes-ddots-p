import Foundation

/// Deletion claims and file IDs live only in memory, including unkept rooms.
/// A cached receipt is only a hint: re-read the Slack thread and file owner before deleting.
final class ShrimpReceipts {
    static let setting = "shrimpDeleteUploadedOriginals"
    static let lifetime: TimeInterval = 7 * 86400
    struct Receipt: Equatable {
        let source: String
        let count: Int
    }
    struct Claim: Hashable {
        let room: String
        let thread: String
        let receipt: String
    }
    struct Outcome {
        var deleted = Set<String>()
        var notice: String?
    }
    private var authenticatedUser: String?
    private var attempted = Set<Claim>()
    private var permissionFailed = false
    private var showedFailure = false
    private(set) var deleted = Set<String>()

    static func parse(_ text: String) -> Receipt? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].hasPrefix("저장했어요 — "),
              lines.last!.hasPrefix("올린 원본: ") else { return nil }
        let source = String(lines.last!.dropFirst("올린 원본: ".count))
        guard validTS(source) else { return nil }
        let title = String(lines[0].dropFirst("저장했어요 — ".count))
        func path(_ value: String) -> Bool {
            !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value != 0x2028 && $0.value != 0x2029 } &&
            value.components(separatedBy: "/").allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("..") }
        }
        if lines.count == 2 {
            guard path(title), title.range(of: #"^[0-9]+개$"#, options: .regularExpression) == nil else { return nil }
            return Receipt(source: source, count: 1)
        }
        guard title.hasSuffix("개"), let count = Int(title.dropLast()), (2...10).contains(count),
              lines.count == count + 2 else { return nil }
        let paths = lines.dropFirst().dropLast()
        guard paths.allSatisfy({ $0.hasPrefix("- ") && path(String($0.dropFirst(2))) }), Set(paths).count == count else { return nil }
        return Receipt(source: source, count: count)
    }
    static func validTS(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil && Double(value)?.isFinite == true
    }
    static func recent(_ ts: String, now: Date) -> Bool {
        guard validTS(ts), let seconds = Double(ts) else { return false }
        let age = now.timeIntervalSince1970 - seconds
        return age >= 0 && age <= lifetime
    }
    static func ts(_ message: ChatMessage, room: String) -> String? {
        let prefix = "slack:\(room):"
        guard message.id.hasPrefix(prefix) else { return nil }
        let ts = String(message.id.dropFirst(prefix.count))
        return validTS(ts) ? ts : nil
    }

    func process(threads: [SlackThread], me: String, bot: String, api: SlackAPI,
                 enabled: Bool = true, now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        guard enabled, !permissionFailed, !me.isEmpty, !bot.isEmpty, me != bot else { return outcome }
        // Bounded work per pass and total claims per connection; never silently evict a deletion claim.
        guard attempted.count < 2000 else { return outcome }
        var work = 0
        for thread in threads where thread.loaded && Self.validTS(thread.ts) {
            receipts: for message in thread.messages where !message.fromUser && message.slackUserID == bot {
                guard let receipt = Self.parse(message.body), let ts = Self.ts(message, room: thread.room),
                      Self.recent(ts, now: now), Self.recent(receipt.source, now: now),
                      Double(ts)! >= Double(receipt.source)! else { continue }
                let claim = Claim(room: thread.room, thread: thread.ts, receipt: ts)
                guard !attempted.contains(claim), work < 4, attempted.count < 2000 else { continue }
                attempted.insert(claim); work += 1
                do {
                    if authenticatedUser == nil {
                        let identity = try api.call("auth.test").get()
                        authenticatedUser = identity["user_id"] as? String
                    }
                    guard authenticatedUser == me else { continue }
                    let raw = try messages(api: api, claim: claim)
                    guard let confirmation = raw.first(where: { $0["ts"] as? String == ts }),
                          confirmation["user"] as? String == bot,
                          (confirmation["channel"] as? String ?? thread.room) == thread.room,
                          (confirmation["thread_ts"] as? String ?? ts) == thread.ts,
                          let body = confirmation["text"] as? String,
                          Self.parse(SlackText.display(body, users: [:])) == receipt,
                          let source = raw.first(where: { $0["ts"] as? String == receipt.source }),
                          source["user"] as? String == me,
                          (source["channel"] as? String ?? thread.room) == thread.room,
                          (source["thread_ts"] as? String ?? receipt.source) == thread.ts,
                          let files = source["files"] as? [[String: Any]], files.count == receipt.count,
                          files.count <= 10 else { continue }
                    let ids = files.compactMap { $0["id"] as? String }
                    guard ids.count == files.count, Set(ids).count == ids.count,
                          ids.allSatisfy({ $0.range(of: #"^F[A-Z0-9]+$"#, options: .regularExpression) != nil }) else { continue }
                    var verifiedIDs: [String] = []
                    for file in files {
                        let id = file["id"] as! String
                        if deleted.contains(id) || file["mode"] as? String == "tombstone" || file["is_deleted"] as? Bool == true { continue }
                        let info = try api.call("files.info", ["file": id]).get()
                        guard let verified = info["file"] as? [String: Any], verified["id"] as? String == id,
                              verified["user"] as? String == me, verified["is_external"] as? Bool != true,
                              verified["mode"] as? String != "external" else { continue receipts }
                        if verified["mode"] as? String == "tombstone" || verified["is_deleted"] as? Bool == true { continue }
                        verifiedIDs.append(id)
                    }
                    for id in verifiedIDs {
                        _ = try api.call("files.delete", ["file": id]).get()
                        deleted.insert(id); outcome.deleted.insert(id)
                    }
                } catch {
                    if case SlackAPI.Failure.api(let code) = error, code.hasPrefix("missing_scope") || ["no_permission", "cant_delete_file", "not_allowed_token_type"].contains(code) {
                        permissionFailed = true
                        outcome.notice = "올린 원본을 지우지 못했어요 — ddots의 Slack 연결에 파일 삭제 권한이 필요해요. README의 ‘저장된 업로드 원본 삭제’ 안내를 확인해 주세요."
                        return outcome
                    }
                    if !showedFailure {
                        showedFailure = true
                        outcome.notice = "올린 원본을 지우지 못했어요. Slack에서 확인해 주세요. 자동 재시도는 하지 않아요."
                    }
                }
            }
        }
        return outcome
    }
    private func messages(api: SlackAPI, claim: Claim) throws -> [[String: Any]] {
        var result: [[String: Any]] = [], cursor = ""
        for _ in 0..<10 {
            var params = ["channel": claim.room, "ts": claim.thread, "limit": "100"]
            if !cursor.isEmpty { params["cursor"] = cursor }
            let page = try api.call("conversations.replies", params).get()
            result += page["messages"] as? [[String: Any]] ?? []
            cursor = ((page["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
            if cursor.isEmpty { return page["has_more"] as? Bool == true ? [] : result }
        }
        return [] // Incomplete thread cannot authorize deletion.
    }
}
