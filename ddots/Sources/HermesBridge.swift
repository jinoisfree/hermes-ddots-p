import Foundation
import SQLite3
import AppKit
import Carbon

/// What Hermes records about Slack threads: who is writing a reply now, and which threads it worked in lately.
struct SlackActivity: Equatable {
    struct Writer: Equatable { var profile: String; var name: String; var room: String; var thread: String; var since: Double }
    struct Recent: Equatable { var room: String; var thread: String; var at: Double }
    var writers: [Writer] = []
    var recent: [Recent] = []
}

/// All state.db connections are read-only. This object is confined to the app's serial monitor queue.
final class HermesBridge {
    enum Status: Equatable { case connected(stores: Int), unavailable(String) }
    struct Store { var profile: String; var name: String; var database: URL; var avatarURL: URL? = nil }
    struct PollResult { var status: Status; var messages: [ChatMessage]; var typing: [TypingIndicator] = []; var sessionToken = ""; var avatars: [String: ProfileAvatar] = [:]; var characters: [ChatCharacter] = []; var receipts: [ChatReceipt] = []; var projects: [ThreadProject] = [] }
    private struct Lease { var session: String; var acquired: Double; var expires: Double }
    private struct Cache {
        var stamp: String; var leases: [Lease]
        var capacity: Int; var schema: Int64; var identity: UInt64; var lastID: Int64; var messages: [ChatMessage]
    }
    static let source = "photon"
    let home: URL
    private var cache: [String: Cache] = [:]
    private let avatarCache: ProfileAvatarCache
    private var cachedStores: [Store] = []
    private var discoveryTime = Date.distantPast
    private var names: [String: (Date, String)] = [:]
    private(set) var rowsRead = 0
    private var activityCache: (stamp: String, window: TimeInterval, limit: Int, since: Double, until: Double, result: SlackActivity)?
    private(set) var activityReads = 0
    private static func databaseStamp(_ database: URL) -> String {
        [database.path, database.path + "-wal"].map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return "\(path):\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes?[.size] ?? 0):\(attributes?[.systemFileNumber] ?? 0)"
        }.joined(separator: "|")
    }
    init(home: URL? = nil, makesImages: Bool = true) {
        avatarCache = ProfileAvatarCache(makesImages: makesImages)
        self.home = home ?? HermesLocator.shared.locate() ?? HermesLocator.shared.fallbackHome
    }
    func stores() -> [Store] {
        if !cachedStores.isEmpty, Date().timeIntervalSince(discoveryTime) < 30 { return refreshedAvatars() }
        let files = FileManager.default
        let profiles = home.appendingPathComponent("profiles")
        let roots = [("default", home)] + ((try? files.contentsOfDirectory(atPath: profiles.path)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") && $0 != "default" }.map { ($0, profiles.appendingPathComponent($0)) }
        cachedStores = roots.compactMap { profile, root in
            let database = root.appendingPathComponent("state.db")
            guard files.fileExists(atPath: database.path) else { return nil }
            let stamp = ((try? files.attributesOfItem(atPath: root.appendingPathComponent("profile.yaml").path))?[.modificationDate] as? Date) ?? .distantPast
            if names[profile]?.0 != stamp { names[profile] = (stamp, Self.displayName(root: root) ?? (profile == "default" ? "Hermes" : profile)) }
            return Store(profile: profile, name: names[profile]!.1, database: database)
        }
        discoveryTime = Date()
        return refreshedAvatars()
    }
    private func refreshedAvatars() -> [Store] {
        cachedStores = cachedStores.map { store in
            var store = store
            store.avatarURL = ProfileAvatarCache.avatarURL(root: store.database.deletingLastPathComponent())
            return store
        }
        return cachedStores
    }
    static func displayName(root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("profile.yaml"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0.isNewline }) where line.hasPrefix("display_name:") {
            let value = line.dropFirst("display_name:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \t'\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }
    func poll(limit: Int = 200, now: Date = Date(), unreadSince: Date? = nil, includeMessages: Bool = true) -> PollResult {
        let found = stores(); rowsRead = 0
        var messages: [ChatMessage] = [], typing: [TypingIndicator] = [], tokens: [String] = []
        let avatars = Dictionary(uniqueKeysWithValues: found.map { ($0.profile, avatarCache.load(profile: $0.profile, root: $0.database.deletingLastPathComponent(), url: $0.avatarURL)) })
        if !includeMessages {
            // No message queries, leases, receipts or photon schema are needed for character metadata.
            return PollResult(status: found.isEmpty ? .unavailable("이 Mac에서 Hermes 기록을 찾지 못했어요.") : .connected(stores: found.count),
                messages: [], avatars: avatars, characters: ChatCharacter.ordered(found.map { ChatCharacter(id: $0.profile, name: $0.name) }), projects: projects())
        }
        var readable = 0
        cache = cache.filter { key, _ in found.contains { $0.profile == key } }
        for store in found {
            let stamp = [store.database.path,store.database.path + "-wal"].map { path -> String in
                let attributes = try? FileManager.default.attributesOfItem(atPath:path)
                return "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes?[.size] ?? 0):\(attributes?[.systemFileNumber] ?? 0)"
            }.joined(separator:"|")
            if let previous = cache[store.profile], previous.stamp == stamp, previous.capacity >= limit {
                let cached = Array(previous.messages.suffix(limit))
                messages += cached; readable += 1
                typing += Self.indicators(previous.leases,store:store,messages:cached,now:now)
                if let latest = cached.last { tokens.append(store.profile + ":" + latest.sessionID) }
                continue
            }
            guard let db = Self.open(store) else { cache[store.profile] = nil; continue }
            defer { sqlite3_close(db) }
            guard Self.valid(db) else { cache[store.profile] = nil; continue }
            let schema = Self.scalar(db, "PRAGMA schema_version")
            let maxID = Self.scalar(db, "SELECT COALESCE(MAX(id),0) FROM messages")
            let identity = ((try? FileManager.default.attributesOfItem(atPath: store.database.path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let previous = cache[store.profile]
            let incremental = previous.map { $0.capacity >= limit && $0.schema == schema && $0.identity == identity && maxID >= $0.lastID } ?? false
            let rows: [ChatMessage]?
            if incremental, let previous {
                rows = Self.query(db, store, clause: "AND m.id > ?", values: [.integer(previous.lastID)], limit: nil)
            } else { rows = Self.query(db, store, limit: limit) }
            guard let rows else { cache[store.profile] = nil; continue }
            rowsRead += rows.count
            var combined = ChatTimeline.merge((incremental ? previous!.messages : []) + rows, pending: [], limit: limit)
            // New empty assistant/user rows can change a cached user's interruption marker.
            Self.markInterruptions(db, messages: &combined)
            let leases = Self.leases(db)
            cache[store.profile] = Cache(stamp:stamp,leases:leases,capacity: limit, schema: schema, identity: identity, lastID: maxID, messages: combined)
            readable += 1; messages += combined
            typing += Self.indicators(leases, store: store, messages: combined, now: now)
            if let latest = combined.last { tokens.append(store.profile + ":" + latest.sessionID) }
        }
        let merged = ChatTimeline.merge(messages, pending: [], limit: limit)
        // A reply from any routed character resolves the fallback user signal.
        if typing.isEmpty, let last = merged.last, last.fromUser, now.timeIntervalSince(last.date) >= 0, now.timeIntervalSince(last.date) < 180 {
            typing = [TypingIndicator(id: "fallback", speaker: "")]
        }
        let status: Status = readable > 0 ? .connected(stores: readable) : .unavailable(found.isEmpty ? "이 Mac에서 Hermes 기록을 찾지 못했어요." : "Hermes 기록 형식을 읽을 수 없어요.")
        return PollResult(status: status, messages: merged, typing: typing, sessionToken: tokens.sorted().joined(separator: "|"), avatars: avatars, characters: ChatCharacter.ordered(found.map { ChatCharacter(id: $0.profile, name: $0.name) }), receipts: unreadSince.map { receipts(after: $0, stores: found) } ?? [], projects: projects())
    }

    private var projectCache: (stamp: String, rows: [ThreadProject])?
    func projects() -> [ThreadProject] {
        let file = home.appendingPathComponent("shared/project-threads.sqlite3")
        let stamp = Self.databaseStamp(file)
        if let previous = projectCache, previous.stamp == stamp { return previous.rows }
        guard let db = Self.open(Store(profile: "", name: "", database: file)) else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM projects ORDER BY json_extract(data,'$.updated_at') DESC LIMIT 100", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var rows: [ThreadProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let raw = String(cString: text)
            guard raw.utf8.count <= 2_000_000, var project = try? decoder.decode(ThreadProject.self, from: Data(raw.utf8)) else { continue }
            project.goal = String(project.goal.prefix(300))
            project.tasks = project.tasks.suffix(30).map { var t = $0; t.summary = String(t.summary.prefix(500)); return t }
            project.decisions = project.decisions.map { Array($0.suffix(10)) }
            project.facts = project.facts.map { Array($0.suffix(10)) }
            project.approvals = project.approvals.map { $0.filter { ["pending", "approved", "executing", "unknown"].contains($0.status) } }
            rows.append(project)
        }
        projectCache = (stamp, rows)
        return rows
    }
    func receipts(after date: Date) -> [ChatReceipt] { receipts(after: date, stores: stores()) }
    private func receipts(after date: Date, stores: [Store]) -> [ChatReceipt] {
        var result: [ChatReceipt] = []
        for store in stores {
            guard let db = Self.open(store) else { continue }; defer { sqlite3_close(db) }
            guard Self.valid(db) else { continue }
            let meta = Self.columns(db,"messages").contains("display_kind") ? "AND COALESCE(m.display_kind,'') != 'session_meta'" : ""
            let sql = "SELECT m.id,m.role,m.timestamp FROM messages m JOIN sessions s ON s.id=m.session_id WHERE s.source=? AND m.role IN ('user','assistant') AND m.tool_calls IS NULL AND m.content IS NOT NULL AND m.content<>'' AND m.timestamp>? " + meta
            guard let statement = Self.prepare(db,sql,[.text(Self.source),.real(date.timeIntervalSince1970)]) else { continue }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(ChatReceipt(id:store.profile+":"+String(sqlite3_column_int64(statement,0)),fromUser:String(cString:sqlite3_column_text(statement,1)) == "user",date:Date(timeIntervalSince1970:sqlite3_column_double(statement,2))))
            }
        }
        return result
    }
    static func open(_ store: Store) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(store.database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle); return nil
        }
        sqlite3_busy_timeout(db, 200)
        return db
    }
    private static func valid(_ db: OpaquePointer) -> Bool {
        columns(db, "messages").isSuperset(of: ["id", "session_id", "role", "content", "timestamp", "tool_calls"]) && columns(db, "sessions").isSuperset(of: ["id", "source"])
    }
    enum Value { case text(String), integer(Int64), real(Double) }
    private static func prepare(_ db: OpaquePointer, _ sql: String, _ values: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .text(let string): sqlite3_bind_text(statement, i, string, -1, transient)
            case .integer(let number): sqlite3_bind_int64(statement, i, number)
            case .real(let number): sqlite3_bind_double(statement, i, number)
            }
        }
        return statement
    }
    private static func scalar(_ db: OpaquePointer, _ sql: String) -> Int64 {
        guard let statement = prepare(db, sql, []) else { return -1 }; defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : -1
    }
    private static func query(_ db: OpaquePointer, _ store: Store, clause: String = "", values: [Value] = [], ascending: Bool = false, limit: Int?) -> [ChatMessage]? {
        guard valid(db) else { return nil }
        let meta = columns(db, "messages").contains("display_kind") ? "AND COALESCE(m.display_kind,'') != 'session_meta'" : ""
        let order = ascending ? "ASC" : "DESC"
        let sql = """
        SELECT m.id,m.role,m.content,m.timestamp,m.session_id FROM messages m JOIN sessions s ON s.id=m.session_id
        WHERE s.source=? AND m.role IN ('user','assistant') AND m.tool_calls IS NULL
        AND m.content IS NOT NULL AND m.content<>'' \(meta) \(clause)
        ORDER BY m.timestamp \(order),m.id \(order)
        """ + (limit == nil ? "" : " LIMIT ?")
        let arguments = [Value.text(source)] + values + (limit.map { [Value.integer(Int64(max(1,$0)))] } ?? [])
        guard let statement = prepare(db, sql, arguments) else { return nil }; defer { sqlite3_finalize(statement) }
        var rows: [ChatMessage] = []; var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let user = String(cString: sqlite3_column_text(statement, 1)) == "user"
            rows.append(ChatMessage(id: "\(store.profile):\(sqlite3_column_int64(statement, 0))", fromUser: user,
                speaker: user ? "" : store.name, body: user ? ChatText.userVisible(String(cString: sqlite3_column_text(statement, 2))) : String(cString: sqlite3_column_text(statement, 2)),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                sessionID: String(cString: sqlite3_column_text(statement, 4)), profile: store.profile))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { return nil }
        markInterruptions(db, messages: &rows)
        return rows
    }
    private static func markInterruptions(_ db: OpaquePointer, messages: inout [ChatMessage]) {
        let ids = messages.filter(\.fromUser).map(\.rowID)
        guard !ids.isEmpty else { return }
        // Only IDs and the empty-answer predicate leave SQLite; no hidden message bodies are read.
        let sql = """
        SELECT u.id FROM messages u
        JOIN messages a ON a.id=(SELECT id FROM messages WHERE session_id=u.session_id AND id>u.id ORDER BY id LIMIT 1)
        JOIN messages n ON n.id=(SELECT id FROM messages WHERE session_id=a.session_id AND id>a.id ORDER BY id LIMIT 1)
        WHERE u.id IN (\(ids.map { _ in "?" }.joined(separator: ","))) AND u.role='user'
        AND a.role='assistant' AND a.tool_calls IS NULL AND COALESCE(a.content,'')=''
        AND n.role='user'
        """
        guard let statement = prepare(db,sql,ids.map(Value.integer)) else { return }
        defer { sqlite3_finalize(statement) }
        var interrupted = Set<Int64>()
        while sqlite3_step(statement) == SQLITE_ROW { interrupted.insert(sqlite3_column_int64(statement,0)) }
        for i in messages.indices where messages[i].fromUser { messages[i].replyInterrupted = interrupted.contains(messages[i].rowID) }
    }
    static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        // Only compile-time table names reach this helper.
        guard let statement = prepare(db, "PRAGMA table_info(\(table))", []) else { return [] }; defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) } }
        return names
    }
    private static func leases(_ db: OpaquePointer) -> [Lease] {
        guard columns(db,"session_turn_leases").isSuperset(of: ["conversation_id","holder","acquired_at","expires_at"]) else { return [] }
        let sql = "SELECT l.conversation_id,l.acquired_at,l.expires_at FROM session_turn_leases l JOIN sessions s ON s.id=l.conversation_id WHERE s.source=?"
        guard let statement = prepare(db,sql,[.text(source)]) else { return [] }; defer { sqlite3_finalize(statement) }
        var result: [Lease] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Lease(session:String(cString:sqlite3_column_text(statement,0)),acquired:sqlite3_column_double(statement,1),expires:sqlite3_column_double(statement,2)))
        }
        return result
    }
    private static func indicators(_ leases: [Lease], store: Store, messages: [ChatMessage], now: Date) -> [TypingIndicator] {
        leases.compactMap { lease in
            guard lease.expires > now.timeIntervalSince1970 else { return nil }
            let answered = messages.contains { $0.sessionID == lease.session && !$0.fromUser && $0.date.timeIntervalSince1970 >= lease.acquired }
            return answered ? nil : TypingIndicator(id:store.profile + ":" + lease.session,speaker:store.name,profile:store.profile)
        }
    }
    /// Only room and thread identifiers and times leave SQLite here; no message text is read.
    func slackActivity(now: Date = Date(), window: TimeInterval = 2 * 86_400, limit: Int = 20) -> SlackActivity {
        let found = stores(), at = now.timeIntervalSince1970
        let stamp = found.map { $0.profile + ":" + $0.name + ":" + Self.databaseStamp($0.database) }.joined(separator: "|")
        if let cache = activityCache, cache.stamp == stamp, cache.window == window, cache.limit == limit,
           at >= cache.since, at < cache.until { return cache.result }
        var until = Double.infinity
        var readable = true
        var writers: [SlackActivity.Writer] = [], recent: [String: SlackActivity.Recent] = [:]
        for store in found {
            activityReads += 1
            guard let db = Self.open(store) else { readable = false; continue }; defer { sqlite3_close(db) }
            guard Self.valid(db) else { readable = false; continue }
            guard Self.columns(db, "sessions").isSuperset(of: ["chat_id", "thread_id"]) else { continue }
            let place = "s.source='slack' AND COALESCE(s.chat_id,'')<>'' AND COALESCE(s.thread_id,'')<>''"
            if Self.columns(db, "session_turn_leases").isSuperset(of: ["conversation_id", "acquired_at", "expires_at"]),
               let statement = Self.prepare(db, "SELECT s.chat_id,s.thread_id,l.acquired_at,l.expires_at FROM session_turn_leases l JOIN sessions s ON s.id=l.conversation_id WHERE \(place) AND l.expires_at>?", [.real(now.timeIntervalSince1970)]) {
                while sqlite3_step(statement) == SQLITE_ROW {
                    until = min(until, sqlite3_column_double(statement, 3))
                    writers.append(.init(profile: store.profile, name: store.name, room: String(cString: sqlite3_column_text(statement, 0)),
                                         thread: String(cString: sqlite3_column_text(statement, 1)), since: sqlite3_column_double(statement, 2)))
                }
                sqlite3_finalize(statement)
            }
            let sql = "SELECT s.chat_id,s.thread_id,MAX(m.timestamp) FROM sessions s JOIN messages m ON m.session_id=s.id WHERE \(place) GROUP BY s.chat_id,s.thread_id HAVING MAX(m.timestamp)>? ORDER BY 3 DESC LIMIT ?"
            guard let statement = Self.prepare(db, sql, [.real(now.timeIntervalSince1970 - window), .integer(Int64(limit))]) else { readable = false; continue }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let item = SlackActivity.Recent(room: String(cString: sqlite3_column_text(statement, 0)), thread: String(cString: sqlite3_column_text(statement, 1)), at: sqlite3_column_double(statement, 2))
                until = min(until, item.at + window)
                if (recent[item.room + ":" + item.thread]?.at ?? 0) < item.at { recent[item.room + ":" + item.thread] = item }
            }
        }
        let result = SlackActivity(writers: writers, recent: Array(recent.values.sorted { $0.at > $1.at }.prefix(limit)))
        activityCache = readable ? (stamp, window, limit, at, until, result) : nil
        return result
    }
    static func searchTerm(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }
    static func likePattern(_ text: String) -> String {
        "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    func search(_ text: String) -> [ChatMessage] {
        let term = Self.searchTerm(text); guard !term.isEmpty else { return [] }
        var result: [ChatMessage] = []
        for store in stores() {
            guard let db = Self.open(store) else { continue }; defer { sqlite3_close(db) }
            result += Self.query(db,store,clause: "AND m.content LIKE ? ESCAPE '\\'",values: [.text(Self.likePattern(term))],limit: 200) ?? []
        }
        return Array(result.sorted(by: { ChatTimeline.ordered($1,$0) }).prefix(200))
    }
    /// Cursor compares timestamp, profile, then row ID so equal timestamps never skip rows.
    private func page(around message: ChatMessage?, after: Bool, limit: Int) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for store in stores() {
            guard let db = Self.open(store) else { continue }; defer { sqlite3_close(db) }
            var clause = ""; var values: [Value] = []
            if let message {
                let op = after ? ">" : "<"
                clause = "AND (m.timestamp \(op) ? OR (m.timestamp=? AND (? \(op) ? OR (?=? AND m.id \(op) ?))))"
                values = [.real(message.date.timeIntervalSince1970),.real(message.date.timeIntervalSince1970),.text(store.profile),.text(message.profile),.text(store.profile),.text(message.profile),.integer(message.rowID)]
            }
            result += Self.query(db,store,clause: clause,values: values,ascending: after,limit: limit) ?? []
        }
        let ordered = result.sorted(by: ChatTimeline.ordered)
        return after ? Array(ordered.prefix(limit)) : Array(ordered.suffix(limit))
    }
    func older(before message: ChatMessage?, limit: Int = 40) -> [ChatMessage] { page(around: message,after: false,limit: limit) }
    func around(profile: String, messageID: Int64, count: Int = 20) -> [ChatMessage] {
        guard let store = stores().first(where: { $0.profile == profile }), let db = Self.open(store) else { return [] }
        defer { sqlite3_close(db) }
        guard let target = Self.query(db,store,clause:"AND m.id=?",values:[.integer(messageID)],limit:1)?.first else { return [] }
        return page(around: target,after: false,limit: count) + [target] + page(around: target,after: true,limit: count)
    }

    // MARK: Sending

    static func validHandle(_ input: String) -> String? {
        let handle = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "")
        let allowed = CharacterSet(charactersIn: "+@._-").union(.alphanumerics)
        guard (3...100).contains(handle.count), handle.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return handle
    }

    static let sendTimeout = 10
    /// The message goes out as a real iMessage, so it also appears in the thread on every other device.
    static func sendScript(text: String, handle: String) -> String {
        func literal(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // Without a limit a Messages that does not answer holds every send after it for two minutes.
        return """
            with timeout of \(sendTimeout) seconds
            tell application "Messages"
            set hermesAccount to 1st account whose service type = iMessage
            send \(literal(text)) to participant \(literal(handle)) of hermesAccount
            end tell
            end timeout
            """
    }

    struct SendFailure {
        let message: String
        let automationDenied: Bool
    }

    static func failure(code: Int, detail: String = "") -> SendFailure {
        if code == -1743 || code == -1744 {
            return SendFailure(message: "메시지 제어 권한이 필요해요. 자동화 설정에서 ddots의 ‘메시지’를 허용한 뒤 다시 보내 주세요.", automationDenied: true)
        }
        return SendFailure(message: "메시지를 보내지 못했어요. \(detail.isEmpty ? "오류 \(code)" : detail)", automationDenied: false)
    }

    struct MessagesAppPolicy: Equatable {
        var shouldLaunch: Bool
        var shouldHideAfterSend: Bool
    }
    static func messagesAppPolicy(isRunning: Bool, launchedByPet: Bool, isHidden: Bool) -> MessagesAppPolicy {
        MessagesAppPolicy(shouldLaunch: !isRunning, shouldHideAfterSend: isRunning && launchedByPet && !isHidden)
    }

    /// An already-running Messages must not receive a LaunchServices reopen request.
    static func send(text: String, handle: String, completion: @escaping (SendFailure?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { send(text: text, handle: handle, completion: completion) }; return
        }
        let identifier = "com.apple.MobileSMS"
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
        let policy = messagesAppPolicy(isRunning: existing != nil, launchedByPet: false, isHidden: existing?.isHidden ?? false)
        if !policy.shouldLaunch {
            authorizeAndSend(text: text, handle: handle, application: existing!, launchedByPet: false, completion: completion)
            return
        }
        guard let target = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            completion(failure(code: -600, detail: "메시지 앱을 찾지 못했어요.")); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                guard let application, error == nil else {
                    completion(failure(code: -600, detail: "메시지 앱을 열지 못했어요.")); return
                }
                waitForMessages(application, deadline: .now() + 3) { launchFailure in
                    if let launchFailure {
                        finishSend(launchFailure, application: application, launchedByPet: true, completion: completion)
                    } else {
                        authorizeAndSend(text: text, handle: handle, application: application, launchedByPet: true, completion: completion)
                    }
                }
            }
        }
    }

    /// Poll launch readiness without blocking the main run loop; never wait beyond three seconds.
    private static func waitForMessages(_ application: NSRunningApplication, deadline: DispatchTime,
                                        completion: @escaping (SendFailure?) -> Void) {
        if application.isTerminated { completion(failure(code: -600, detail: "메시지 앱이 종료됐어요.")); return }
        if application.isFinishedLaunching { completion(nil); return }
        guard DispatchTime.now() < deadline else {
            completion(failure(code: -1712, detail: "메시지 앱의 준비가 늦어지고 있어요. 잠시 후 다시 보내 주세요.")); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForMessages(application, deadline: deadline, completion: completion)
        }
    }

    private static func finishSend(_ error: SendFailure?, application: NSRunningApplication, launchedByPet: Bool,
                                   completion: @escaping (SendFailure?) -> Void) {
        let policy = messagesAppPolicy(isRunning: !application.isTerminated, launchedByPet: launchedByPet, isHidden: application.isHidden)
        if policy.shouldHideAfterSend { application.hide() }
        completion(error)
    }

    /// Sends run one at a time on their own queue: the permission check and the script can each block for seconds,
    /// and the main thread keeps drawing meanwhile. Only the result comes back to it.
    static let sendQueue = DispatchQueue(label: "io.github.hermes-ddots-p.ddots.messages-send", qos: .userInitiated)
    /// What a send does on that queue. The checks swap in a slow or failing one so nothing reaches Messages.
    static var sendRunner: (_ text: String, _ handle: String) -> SendFailure? = runSendScript

    static func runSendScript(text: String, handle: String) -> SendFailure? {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
        let permission = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, typeWildCard, typeWildCard, true)
        guard permission == noErr else { return failure(code: Int(permission)) }
        guard let script = NSAppleScript(source: sendScript(text: text, handle: handle)) else {
            return failure(code: -1, detail: "보내기 명령을 만들지 못했어요.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error.map { failure(code: ($0[NSAppleScript.errorNumber] as? Int) ?? -1,
                                   detail: ($0[NSAppleScript.errorMessage] as? String) ?? "") }
    }

    /// Runs the send on `sendQueue` and hands its result to `completion` on the main queue, once.
    static func perform(text: String, handle: String, completion: @escaping (SendFailure?) -> Void) {
        let runner = sendRunner
        sendQueue.async {
            let result = runner(text, handle)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func authorizeAndSend(text: String, handle: String, application: NSRunningApplication,
                                         launchedByPet: Bool, completion: @escaping (SendFailure?) -> Void) {
        perform(text: text, handle: handle) { result in
            finishSend(result, application: application, launchedByPet: launchedByPet, completion: completion)
        }
    }
}
