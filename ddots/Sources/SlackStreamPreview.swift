import Foundation

extension StreamPreview {
    /// Overlay only the exact room/thread/profile; finalized Slack content always wins.
    static func applying(_ previews: [Self], to original: SlackThread, names: [String: String], now: Date = Date()) -> SlackThread {
        var thread = original
        let candidates = previews.filter { $0.room == thread.room && $0.thread == thread.ts && $0.valid(at: now.timeIntervalSince1970) }
        let latest = Dictionary(candidates.compactMap { p in p.profile.map { ($0, p) } }, uniquingKeysWith: { $0.updated > $1.updated ? $0 : $1 })
        for (profile, preview) in latest.sorted(by: { $0.key < $1.key }) {
            let current = original.messages.filter { !$0.fromUser && $0.profile == profile && $0.date.timeIntervalSince1970 >= preview.since }
            if current.contains(where: { !SlackText.isThinking($0.body) }) { continue }
            let placeholder = current.last
            var message = ChatMessage(id: placeholder?.id ?? "stream:" + preview.id, fromUser: false,
                                      speaker: placeholder?.speaker ?? names[profile] ?? profile,
                                      body: preview.displayedBody, date: placeholder?.date ?? Date(timeIntervalSince1970: preview.since), profile: profile)
            message.streaming = true
            if let index = thread.replies.firstIndex(where: { $0.id == message.id }) { thread.replies[index] = message }
            else { thread.replies.append(message) }
            thread.replyCount = max(thread.replyCount, thread.replies.count)
        }
        return thread
    }
}
