import Foundation

/// What was read from Slack, kept in one file on this Mac so that a start shows the rooms at once and asks Slack
/// only for what changed since. It holds no more than is on show: each room's listed lines and the replies under them.
/// Files are not in it, and it is never put in iCloud.
struct SlackCache: Codable {
    /// 2: posts with Block Kit layout keep their lines (re-read once instead of the one-line fallback).
    /// 3: block attachments are quoted under their coloured bars, titles are large and tables are kept (re-read once).
    static let version = 3
    static let fileName = "slack-cache.json"
    /// The file is kept under this size; the rooms read longest ago are left out first.
    static let sizeLimit = 20 * 1024 * 1024
    /// A room whose listing was not read for this long is left out.
    static let roomAge: TimeInterval = 30 * 86_400
    /// Written no more often than this.
    static let saveInterval: TimeInterval = 15

    var version = SlackCache.version
    var savedAt: Double = 0
    var state = SlackState()
    var rooms: [SlackRoom] = []
    var workspace = ""
    var memberIDs: [String: [String]] = [:]
    var imUsers: [String: String] = [:]
    /// Optional so caches written before account deletion was tracked still load.
    var deletedUsers: Set<String>?
    /// The stamps the reading goes by, as `room:ts`, so that a thread that has not changed is not read again.
    var fetched: [String: String] = [:]
    var first: [String: String] = [:]
    var broadcastStamp: [String: Double] = [:]
    var extraStamp: [String: Double] = [:]
    /// When each room's listing was last read.
    var readAt: [String: Double] = [:]

    /// Nil when there is no file, it cannot be read, or another version wrote it.
    static func read(_ url: URL) -> SlackCache? {
        guard let data = try? Data(contentsOf: url), var cache = try? JSONDecoder().decode(SlackCache.self, from: data), cache.version == version else { return nil }
        // Older releases stored only TalkTalk's fallback title. Re-read those threads once.
        for (room, threads) in cache.state.replies {
            for (ts, messages) in threads where messages.contains(where: { $0.text == "네이버 톡톡 처리 알림" }) {
                cache.fetched[room + ":" + ts] = "naver-blocks-refresh"
            }
        }
        return cache
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
    }

    private static func parts(_ key: String) -> (room: String, ts: String)? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    mutating func drop(_ room: String) {
        state.history[room] = nil; state.extra[room] = nil; state.replies[room] = nil; state.channelTimes[room] = nil
        readAt[room] = nil
        memberIDs[room] = nil; imUsers[room] = nil
        let own: (String) -> Bool = { $0.hasPrefix(room + ":") }
        fetched = fetched.filter { !own($0.key) }; first = first.filter { !own($0.key) }
        broadcastStamp = broadcastStamp.filter { !own($0.key) }; extraStamp = extraStamp.filter { !own($0.key) }
    }

    /// Leaves out what a start would not show: rooms no longer listed or not read for a long time, older threads whose
    /// line in the channel has left the listing, and replies whose first message is gone. `listed` is nil while the
    /// rooms have not been listed yet in this run; `recent` holds the older threads Hermes worked in lately.
    mutating func prune(listed: Set<String>?, recent: Set<String>, now: Double) {
        let held = Set(state.history.keys).union(state.extra.keys).union(state.replies.keys).union(state.channelTimes.keys)
        for room in held where listed.map({ !$0.contains(room) }) ?? false || state.history[room] == nil || now - (readAt[room] ?? now) > Self.roomAge { drop(room) }
        if let listed {
            rooms = rooms.filter { listed.contains($0.id) }
            memberIDs = memberIDs.filter { listed.contains($0.key) }; imUsers = imUsers.filter { listed.contains($0.key) }
        }
        for (room, lines) in state.history {
            let called = Set(lines.filter { !$0.isRoot }.compactMap(\.threadTS))
            state.extra[room] = state.extra[room]?.filter { called.contains($0.key) || recent.contains(room + ":" + $0.key) }
            state.channelTimes[room] = state.channelTimes[room]?.filter { called.contains($0.key) }
            let roots = Set(lines.filter(\.isRoot).map(\.ts)).union((state.extra[room] ?? [:]).keys)
            state.replies[room] = state.replies[room]?.filter { roots.contains($0.key) }
        }
        // A stamp without what it stands for would keep a thread from being read again.
        let replies = state.replies, extra = state.extra, history = state.history
        fetched = fetched.filter { key, _ in Self.parts(key).map { replies[$0.room]?[$0.ts] != nil } ?? false }
        first = first.filter { key, _ in Self.parts(key).map { place in history[place.room]?.contains { $0.ts == place.ts } ?? false } ?? false }
        broadcastStamp = broadcastStamp.filter { key, _ in Self.parts(key).map { extra[$0.room]?[$0.ts] != nil } ?? false }
        extraStamp = extraStamp.filter { key, _ in Self.parts(key).map { extra[$0.room]?[$0.ts] != nil } ?? false }
        // A name that could not be read is asked for again rather than kept as unknown.
        state.users = state.users.filter { $0.value != SlackBridge.unknownName }
    }

    /// The bytes to keep, with the rooms read longest ago left out until they fit.
    mutating func fitted(limit: Int = SlackCache.sizeLimit) -> Data? {
        state.history = state.history.mapValues { $0.filter { !SlackRetention.memoryOnly($0.text) } }
        state.extra = state.extra.mapValues { $0.filter { !SlackRetention.memoryOnly($0.value.text) } }
        for (room, threads) in state.replies {
            for (ts, messages) in threads where messages.contains(where: { SlackRetention.memoryOnly($0.text) }) {
                state.replies[room]?[ts] = messages.filter { !SlackRetention.memoryOnly($0.text) }
                fetched[room + ":" + ts] = nil
            }
        }
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(self) else { return nil }
        while data.count > limit, let oldest = state.history.keys.min(by: { (readAt[$0] ?? 0, $0) < (readAt[$1] ?? 0, $1) }) {
            drop(oldest)
            guard let smaller = try? encoder.encode(self) else { return nil }
            data = smaller
        }
        return data.count > limit ? nil : data
    }

    /// Readable by the user alone from the moment it exists, and left out of backups.
    static func write(_ data: Data, to url: URL) -> Bool {
        let files = FileManager.default, pending = url.appendingPathExtension("tmp")
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: pending)
        guard files.createFile(atPath: pending.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(pending.path, url.path) == 0 else { try? files.removeItem(at: pending); return false }
        var kept = url, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? kept.setResourceValues(values)
        return true
    }
}
