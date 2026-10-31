import Foundation

extension StreamPreview {
    /// Overlay only the exact room/thread/profile; finalized Slack content always wins.
    static func applying(_ previews: [Self], to original: SlackThread, names: [String: String], now: Date = Date()) -> SlackThread {
        var thread = original
        let candidates = previews.filter { $0.room == thread.room && $0.thread == thread.ts && $0.valid(at: now.timeIntervalSince1970) }
        let latest = Dictionary(candidates.compactMap { p in p.profile.map { ($0, p) } }, uniquingKeysWith: { $0.updated > $1.updated ? $0 : $1 })
        for (profile, preview) in latest.sorted(by: { $0.key < $1.key }) {
            // Slack creates the thinking message before Hermes acquires its turn lease.
            // Editing that message into the final answer keeps its original timestamp.
            // Anchor to the user's request, not only to the later lease timestamp.
            let requestDate = original.messages.filter { $0.fromUser && $0.date.timeIntervalSince1970 <= preview.since }
                .map(\.date).max()
            let current = original.messages.filter { message in
                guard !message.fromUser && message.profile == profile else { return false }
                return message.date.timeIntervalSince1970 >= preview.since || requestDate.map { message.date > $0 } == true
            }
            if let final = current.last(where: { !SlackText.isThinking($0.body) }) {
                // Slack remains authoritative. Only its visible prefix is animated;
                // retain the final message ID instead of adding a second bubble.
                if let progress = preview.revealProgress, progress > 0, progress < 1,
                   let index = thread.replies.firstIndex(where: { $0.id == final.id }) {
                    let characters = Array(final.body)
                    thread.replies[index].body = StreamReveal.visiblePrefix(String(characters.prefix(max(1, Int(ceil(Double(characters.count) * progress))))))
                    thread.replies[index].streaming = true
                }
                continue
            }
            let placeholder = current.last
            var message = ChatMessage(id: placeholder?.id ?? "stream:" + preview.id, fromUser: false,
                                      speaker: placeholder?.speaker ?? names[profile] ?? profile,
                                      body: preview.status == "working" ? "◐ 생각 중...\n" + preview.body : preview.displayedBody,
                                      date: placeholder?.date ?? Date(timeIntervalSince1970: preview.since), profile: profile)
            message.streaming = preview.status != "working"
            if let index = thread.replies.firstIndex(where: { $0.id == message.id }) { thread.replies[index] = message }
            else { thread.replies.append(message) }
            thread.replyCount = max(thread.replyCount, thread.replies.count)
        }
        return thread
    }
}
