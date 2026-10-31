import AppKit

/// One comparison of shared inputs per native list update, not one deep filter per row.
/// The legacy path never consults this cache.
final class NativeThreadInputsCache {
    struct Key: Equatable {
        var conversationGeneration = DdotsConfig.shared.generation
        var dark: Bool, reduceMotion: Bool, isDdots: Bool
        var selected: String?, target: String?, picked: String?, flash: String?, highlighted: String?
        var copied: String?, copyWaiting: String?, branching: String?, confirmingDelete: String?
        var open: Set<String>, confirmed: Set<String>, expandedReplies: Set<String>, stopped: Set<String>
        var bells: [String: Bool], typing: [String: [TypingIndicator]]
        var removing: [String: SlackBridge.Removal]
        var workspace: String, search: [String?], find: [String?], vault: [String?]
        var members: [DdotsMember], avatars: [String: ProfileAvatar], palettes: [String: CharacterPalette]
        var events: [CalendarEntry], bubbleWidth: CGFloat
        var vaultSent: Set<String>, driveSent: Set<String>
        var driveDone: [String: Double], driveChosen: [String: String], pages: [String: Int]
        var thumbnails: [String: ObjectIdentifier], failed: Set<String>, busy: Set<String>
    }
    private var key: Key?
    private var values: [String: SlackThreadInputs] = [:]
    private var memos: [String: SlackModel.ThreadRenderMemo] = [:]
    private var aliasCache: [String: (revision: UInt64, aliases: [String])] = [:]
    private func scoped(_ key: Key, to memo: SlackModel.ThreadRenderMemo) -> Key {
        var value = key
        let id = memo.thread.id, messages = memo.messages, files = memo.files
        value.target = key.target == id ? id : nil
        value.picked = key.picked == id ? id : nil
        value.flash = key.flash.flatMap { $0 == id || messages.contains($0) ? $0 : nil }
        value.highlighted = key.highlighted.flatMap { messages.contains($0) ? $0 : nil }
        value.copied = key.copied.flatMap { $0 == "link-"+id || $0 == "copy-"+id ? $0 : nil }
        value.copyWaiting = key.copyWaiting == id ? id : nil
        value.branching = key.branching == id ? id : nil
        value.confirmingDelete = key.confirmingDelete == id ? id : nil
        value.open = key.open.contains(id) ? [id] : []
        value.stopped = key.stopped.contains(id) ? [id] : []
        value.confirmed = key.confirmed.intersection(messages)
        // A report's details shown after its buttons fold on their own ("<id>:detail").
        value.expandedReplies = key.expandedReplies.filter { messages.contains($0) || ($0.hasSuffix(":detail") && messages.contains(String($0.dropLast(7)))) }
        value.bells = key.bells[id].map { [id: $0] } ?? [:]
        value.typing = key.typing[id].map { [id: $0] } ?? [:]
        value.removing = key.removing[id].map { [id: $0] } ?? [:]
        value.find = key.find.first == id ? key.find : []
        value.driveChosen = key.driveChosen.filter { messages.contains($0.key) }
        value.pages = key.pages.filter { messages.contains($0.key) }
        value.thumbnails = key.thumbnails.filter { files.contains($0.key) }
        value.failed = key.failed.intersection(files); value.busy = key.busy.intersection(files)
        return value
    }
    /// Every place inside a thread a scroll can be asked to reach, kept until the thread changes.
    func aliases(_ memo: SlackModel.ThreadRenderMemo) -> [String] {
        if let cached = aliasCache[memo.thread.id], cached.revision == memo.revision { return cached.aliases }
        let aliases = [SlackModel.end(memo.thread.id), "slack-root:" + memo.thread.id] + memo.thread.messages.flatMap {
            [$0.id, "message:" + $0.id, "page-anchor:" + $0.id]
        }
        aliasCache[memo.thread.id] = (memo.revision, aliases)
        return aliases
    }
    func prepare(_ next: Key, ids: Set<String>) {
        if next != key {
            if let previous = key {
                values = values.filter { id, _ in
                    guard let memo = memos[id] else { return false }
                    return scoped(previous, to: memo) == scoped(next, to: memo)
                }
            } else { values.removeAll(keepingCapacity: true) }
            key = next
        }
        values = values.filter { ids.contains($0.key) }
        memos = memos.filter { ids.contains($0.key) }
        aliasCache = aliasCache.filter { ids.contains($0.key) }
    }
    func inputs(_ memo: SlackModel.ThreadRenderMemo, make: () -> SlackThreadInputs) -> SlackThreadInputs {
        if let value = values[memo.thread.id], value.threadRevision == memo.revision { return value }
        let value = make(); values[memo.thread.id] = value; memos[memo.thread.id] = memo; return value
    }
}
