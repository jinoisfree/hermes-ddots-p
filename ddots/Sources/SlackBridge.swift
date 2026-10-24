import Foundation

/// Slack Web API calls made with the user's own token, so replies appear under the user's name.
struct SlackAPI {
    enum Failure: Error, Equatable { case network(String), api(String), rateLimited(Double) }
    typealias Transport = (_ method: String, _ parameters: [String: String]) -> Result<Data, Failure>
    /// Bytes by address: a file fetched with the token, or a file's bytes sent to the address Slack handed out for it.
    typealias Raw = (_ url: URL, _ body: Data?) -> Result<Data, Failure>
    let transport: Transport
    let raw: Raw
    init(transport: @escaping Transport, raw: @escaping Raw = { _, _ in .failure(.network("파일을 주고받을 수 없어요.")) }) {
        self.transport = transport; self.raw = raw
    }
    static func live(token: String) -> SlackAPI { SlackAPI(transport: http(token: token), raw: rawHTTP(token: token)) }

    func call(_ method: String, _ parameters: [String: String] = [:]) -> Result<[String: Any], Failure> {
        switch transport(method, parameters) {
        case .failure(let failure): return .failure(failure)
        case .success(let data):
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.network("응답을 읽지 못했어요.")) }
            if json["ok"] as? Bool == true { return .success(json) }
            let code = json["error"] as? String ?? "unknown_error"
            if code == "ratelimited" { return .failure(.rateLimited(30)) }
            return .failure(.api(code == "missing_scope" ? "missing_scope:" + (json["needed"] as? String ?? "") : code))
        }
    }

    static func message(_ failure: Failure) -> String {
        switch failure {
        case .network(let detail): return "슬랙에 연결하지 못했어요. \(detail)"
        case .rateLimited: return "슬랙 요청이 잠시 제한됐어요. 곧 다시 확인할게요."
        case .api(let code):
            if ["invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive"].contains(code) {
                return "슬랙 토큰이 유효하지 않아요. 메뉴의 ‘슬랙 연결…’에서 다시 넣어 주세요."
            }
            if code.hasPrefix("missing_scope") { return "슬랙 권한이 부족해요: \(code.dropFirst("missing_scope:".count))" }
            if code == "not_in_channel" || code == "channel_not_found" { return "이 방에 참여하고 있지 않아요." }
            return "슬랙 오류: \(code)"
        }
    }

    static func validToken(_ input: String) -> String? {
        SlackConnect.tokenCandidate(input)
    }

    /// True for an address on Slack's own servers, reached safely. `evilslack.com` ends in "slack.com" too and is not one.
    static func takesToken(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "slack.com" || host.hasSuffix(".slack.com")
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func rawHTTP(token: String) -> Raw {
        { url, body in
            var request = URLRequest(url: url, timeoutInterval: 120)
            if let body {
                request.httpMethod = "POST"; request.httpBody = body
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            } else if takesToken(url) {
                // The token goes only to Slack's own file servers.
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            }
            let done = DispatchSemaphore(value: 0)
            var result: Result<Data, Failure> = .failure(.network("응답이 없어요."))
            session.dataTask(with: request) { data, response, error in
                defer { done.signal() }
                if let error { result = .failure(.network(error.localizedDescription)); return }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                    result = .failure(.network("파일 서버가 요청을 받지 않았어요.")); return
                }
                // Without permission Slack answers a file request with its sign-in page instead of the file.
                if body == nil, http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true {
                    result = .failure(.api("missing_scope:files:read")); return
                }
                result = .success(data)
            }.resume()
            done.wait()
            return result
        }
    }

    static func http(token: String) -> Transport {
        { method, parameters in
            guard let url = URL(string: "https://slack.com/api/" + method) else { return .failure(.network("")) }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            var form = URLComponents(); form.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" and ";" alone, which a form body would read as a space or a separator.
            request.httpBody = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: ";", with: "%3B").data(using: .utf8)
            let done = DispatchSemaphore(value: 0)
            var result: Result<Data, Failure> = .failure(.network("응답이 없어요."))
            session.dataTask(with: request) { data, response, error in
                defer { done.signal() }
                if let error { result = .failure(.network(error.localizedDescription)); return }
                if let http = response as? HTTPURLResponse, http.statusCode == 429 {
                    result = .failure(.rateLimited(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30)); return
                }
                if let data { result = .success(data) }
            }.resume()
            done.wait()
            return result
        }
    }
}

/// Reads rooms and threads a little at a time. Confined to the Slack queue.
final class SlackBridge {
    enum Status: Equatable { case connecting, connected, failed(String) }
    struct Request {
        var active: String?
        var open = false
        /// Rooms shown together as ddots while the window shows them; they are read in turn.
        var watch: [String] = []
        /// Rooms to read back through for the record kept on disk, each with the time its record is known to be whole up to.
        var scan: [String: Double] = [:]
        /// Threads the user opened, as `room:ts`.
        var wanted = Set<String>()
        var limits: [String: Int] = [:]
        /// Threads Hermes worked in lately, as `room:ts` with the time of the last activity.
        var recent: [String: Double] = [:]
        /// Rooms taken off the list; they are not read.
        var skipped = Set<String>()
        var characters: [ChatCharacter] = []
        var readRooms = Set<String>()
        var readThreads = Set<String>()
        var localRead: [String: Double] = [:]
        var localThreads: [String: Double] = [:]
        var writesRead = false
    }
    struct Snapshot: Equatable {
        var roomRead: [String: Double] = [:]
        var threadRead: [String: Double] = [:]
        var threadUnfollowed = Set<String>()
        var ownRead: [String: Double] = [:]
        var status = Status.connecting
        var rooms: [SlackRoom] = []
        /// Channels put away in Slack that the user is still in. They are not read; they can be brought back.
        var archived: [SlackRoom] = []
        var threads: [String: [SlackThread]] = [:]
        var more: [String: Bool] = [:]
        /// Everyone in each room except the user.
        var members: [String: [SlackMember]] = [:]
        /// The workspace's own address, as Slack reports it with the token's owner. A thread's link is built on it.
        var workspace = ""
        var me = ""
        var users: [String: String] = [:]
        /// What Slack refuses for one room alone, by room, said in the user's words. The other rooms are read as usual.
        var problems: [String: String] = [:]
        /// Threads being deleted, by thread id, with how many of their messages are gone and how many there were.
        var removing: [String: Removal] = [:]
        /// Threads whose deleting has just ended, by thread id: nil in the value for done, else why it stopped.
        var removed: [String: String?] = [:]
        /// Schema names only, for change attribution without logging private values.
        func changedFields(from old: Self) -> [String] {
            var fields: [String] = []
            if roomRead != old.roomRead { fields.append("roomRead") }
            if threadRead != old.threadRead { fields.append("threadRead") }
            if threadUnfollowed != old.threadUnfollowed { fields.append("threadUnfollowed") }
            if ownRead != old.ownRead { fields.append("ownRead") }
            if status != old.status { fields.append("status") }
            if rooms != old.rooms { fields.append("rooms") }
            if archived != old.archived { fields.append("archived") }
            if threads != old.threads { fields.append("threads") }
            if more != old.more { fields.append("more") }
            if members != old.members { fields.append("members") }
            if workspace != old.workspace { fields.append("workspace") }
            if me != old.me { fields.append("me") }
            if users != old.users { fields.append("users") }
            if problems != old.problems { fields.append("problems") }
            if removing != old.removing { fields.append("removing") }
            if removed != old.removed { fields.append("removed") }
            return fields
        }
    }
    struct Removal: Equatable {
        var done: Int
        var total: Int
    }
    static let pageSize = 40
    static let activeInterval: TimeInterval = 3
    /// A thread a character is answering in is read this often; the room's own listing keeps the slower pace.
    static let liveInterval: TimeInterval = 1.5
    static let idleInterval: TimeInterval = 30
    /// One of the watched rooms is read this often, so each of five comes round every ten seconds.
    static let watchInterval: TimeInterval = 2
    static let eagerThreads = 15
    /// Kept low so that reading every thread of a busy room stays inside Slack's per-minute allowance.
    static let repliesPerSync = 2
    /// Threads of the rooms on screen are read a little faster, so a thread shows its last line soon after the room opens.
    static let shownRepliesPerSync = 4
    static let urgentPerSync = 3
    /// How long after its last line a thread is still watched closely.
    static let liveWindow: TimeInterval = 120
    /// A watched thread where nothing has changed for `settleWindow` is read at this slower pace for the rest of
    /// `liveWindow`. An answer still being written keeps changing, so it stays at `liveInterval`.
    static let calmInterval: TimeInterval = 5
    static let settleWindow: TimeInterval = 10
    /// Total calls per minute; each competing class leaves this many for the other.
    static let callsPerMinute = 45
    static let reservedCalls = 15
    /// Listings of rooms per minute in all, under what Slack allows one app. Rooms nobody is looking at and the
    /// reading back for the record stop at `backgroundHistory`, so a room on screen is always read at its own pace.
    static let historyPerMinute = 46
    static let backgroundHistory = 22
    /// After Slack refuses for pace every allowance is halved, down to `slowestPace`, and comes back a step at a
    /// time for each `paceRest` without another refusal, but not to the pace that was refused until `paceMemory`
    /// has passed. Another Mac reading with the same token shares the allowance, and this is how the two settle.
    static let slowestPace = 0.25
    static let paceStep = 0.25
    static let paceRest: TimeInterval = 600
    static let paceMemory: TimeInterval = 6 * 3600
    /// Slack counts each method on its own, and a refusal says how long to wait for that method alone. Listings and
    /// thread readings each wait out their own refusal while the other goes on, and each spends its minute a little
    /// at a time: a few at once at most, then one as each comes due, so one pass never asks for the whole minute.
    static let gated: [String: (perMinute: Int, burst: Double)] = ["conversations.history": (historyPerMinute, 4), "conversations.replies": (callsPerMinute, 6)]
    static let retryInterval: TimeInterval = 15
    static let starveWindow: TimeInterval = 10
    /// A scan for the record takes one page of a room this often, so it never crowds what is on screen.
    static let scanInterval: TimeInterval = 6
    static let scanPages = 50
    static let unknownName = "알 수 없음"
    /// A "생각 중" line this old has probably lost its answer. Its thread is still looked at, in case the answer is
    /// only slow, but at `lingerInterval`, and once the line is a day old at `longLingerInterval`.
    static let thinkingWindow: TimeInterval = 600
    static let lingerInterval: TimeInterval = 60
    static let longLingerInterval: TimeInterval = 600
    /// A room Slack refuses on its own account is left alone this long before it is tried again.
    static let roomRest: TimeInterval = 300
    /// A name that could not be read is asked for again after this long, then at twice the wait each time up to the longest.
    static let nameWait: TimeInterval = 60
    static let longestNameWait: TimeInterval = 3600
    /// Rooms are listed a page at a time; this many pages is more rooms than anyone is in.
    static let roomPages = 10
    /// What Slack answers when the fault is with the one room asked about, not with the token or the network.
    static func roomOnly(_ code: String) -> Bool {
        ["channel_not_found", "not_in_channel", "is_archived", "no_permission", "access_denied", "method_not_supported_for_channel_type"].contains(code) || code.hasPrefix("missing_scope")
    }

    private let api: SlackAPI
    private(set) var state = SlackState()
    private var snapshot = Snapshot()
    private var roomsAt = Date.distantPast
    private var fetchedAt: [String: Date] = [:]
    private var watchedAt = Date.distantPast
    /// Reading back through a room: where the paging has got to, and the threads found that hold something newer.
    private struct Scan { var since: Double; var started: Double; var cursor = ""; var pages = 0; var paged = false; var threads: [String] = [] }
    private var scans: [String: Scan] = [:]
    private var scanFinished: [String: Double] = [:]
    private var scanPageAt = Date.distantPast
    private var scanned: [String: [ChatMessage]] = [:]
    private var scannedThrough: [String: Double] = [:]
    /// What the scans have found since this was last asked, and the rooms now read through with the time each scan began.
    func takeScanned() -> (messages: [String: [ChatMessage]], through: [String: Double]) {
        defer { scanned = [:]; scannedThrough = [:] }
        return (scanned, scannedThrough)
    }
    private var loadedLimit: [String: Int] = [:]
    /// The newest-reply stamp each thread had when its replies were last read.
    private var fetched: [String: String] = [:]
    /// The channel broadcast that last caused an older thread to be read.
    private var broadcastStamp: [String: Double] = [:]
    private var candidateSeen: [String: Date] = [:]
    private var candidateRead: [String: Date] = [:]
    /// The stamp each thread had when it was first seen, to notice replies that arrive later.
    private var first: [String: String] = [:]
    private var imUsers: [String: String] = [:]
    private var deletedUsers = Set<String>()
    /// The activity time each older thread had when it was last read.
    private var extraStamp: [String: Double] = [:]
    private var memberIDs: [String: [String]] = [:]
    private var dirty = Set<String>()
    private var characters: [ChatCharacter] = []
    private var pausedUntil = Date.distantPast
    /// Rooms left alone for a while after Slack refused them, with when each is tried again.
    private var resting: [String: Date] = [:]
    /// True when the call just made failed for its room or thread alone, so the pass goes on without it.
    private var roomAlone = false
    private var lastCode = ""
    /// Names that could not be read, with how often each was tried and when it is asked for again.
    private var nameRetry: [String: (tries: Int, next: Date)] = [:]
    private var repliesAt: [String: Date] = [:]
    /// When a reading last found each thread different from what was held.
    private var changedAt: [String: Date] = [:]
    private(set) var selfPosts: [String: [String]] = [:]
    private var historyStructure: [String: [String]] = [:]
    private var extraRead: [String: [String: String]] = [:]
    private var skippedBudget: [String: Int] = [:]
    private var skippedCalls: [String: Int] = [:]

    private var roomReadAt: [String: Date] = [:]
    private var roomReadReceived: [String: Date] = [:]
    private var threadReadAt: [String: Date] = [:]
    private var readRefreshes: [Date] = []
    private var markAt: [String: Date] = [:]
    private var sentMarks: [String: Double] = [:]
    private var writeWait: [String: Date] = [:]
    private var writeState: [String: String] = [:]
    private var lastWrite: (method: String, at: Date, result: String)?
    private var writeError: [String: String] = [:]
    private var disabledWrites = Set<String>()
    private var keyWriteWait: [String: Date] = [:]
    private var infoWait = Date.distantPast
    private var infoAt = Date.distantPast
    /// One gated method: until when Slack said to wait, what is left to spend now, and how fast it is spent.
    private struct Gate {
        var until = Date.distantPast
        var tokens: Double
        var filledAt = Date.distantPast
        var pace = 1.0, pacedAt = Date.distantPast, fastest = 1.0, fastestAt = Date.distantPast
        var refusedAt = Date.distantPast
    }
    private var gates = Dictionary(uniqueKeysWithValues: SlackBridge.gated.map { ($0.key, Gate(tokens: $0.value.burst)) })
    /// True when the call just asked for was held back, before or by Slack: nothing was read and nothing is to be counted as read.
    private var deferred = false
    /// Each refusal for pace in the last hour: what was asked, when, and how long Slack said to wait.
    private var refusals: [(method: String, at: Date, wait: Double)] = []
    func pace(_ method: String) -> Double { gates[method]?.pace ?? 1 }

    private func refused(_ method: String, wait: Double, at: Date? = nil) {
        let at = at ?? clock
        // Refusals that come together are one: Slack is still counting what was asked before the first.
        if var gate = gates[method], at.timeIntervalSince(gate.refusedAt) >= 60 {
            gate.fastest = max(Self.slowestPace, gate.pace - Self.paceStep); gate.fastestAt = at
            gate.pace = max(Self.slowestPace, gate.pace / 2); gate.pacedAt = at; gate.refusedAt = at
            gates[method] = gate
        }
        refusals.append((method, at, wait))
        refusals.removeAll { at.timeIntervalSince($0.at) >= 3600 }
    }
    private func allowed(_ perMinute: Int, _ method: String) -> Int { max(1, Int(Double(perMinute) * pace(method))) }

    /// Whether a gated method may be asked for at `at`: its wait is over and something is left to spend. What is not on
    /// screen leaves one in hand, so a room or a thread being looked at is not kept waiting for the next to come due,
    /// unless it has had nothing for `starveWindow`: then it takes its turn, so nothing in the background waits for good.
    private func gateOpen(_ method: String, _ at: Date, need: Double = 1) -> Bool {
        guard var gate = gates[method], let rule = Self.gated[method] else { return true }
        guard at >= gate.until else { return false }
        if at > gate.filledAt {
            gate.tokens = min(rule.burst, gate.tokens + at.timeIntervalSince(gate.filledAt) * Double(allowed(rule.perMinute, method)) / 60)
            gate.filledAt = at; gates[method] = gate
        }
        return gate.tokens >= need
    }
    /// Slack said to wait: counted from when its answer came, not from when the pass began.
    private func limit(_ method: String, _ seconds: Double) {
        let at = observedAt
        refused(method, wait: seconds, at: at)
        guard var gate = gates[method] else { return }
        // One may be asked for when the wait is over; the rest comes back at the method's pace.
        gate.until = max(gate.until, at.addingTimeInterval(max(1, seconds)))
        gate.tokens = 1; gate.filledAt = gate.until
        gates[method] = gate
    }
    /// A call that passes through the gates. Nil when it was held back without asking.
    private func send(_ method: String, _ parameters: [String: String]) -> Result<[String: Any], SlackAPI.Failure>? {
        if gates[method] != nil {
            guard gateOpen(method, observedAt) else { return nil }
            gates[method]?.tokens -= 1
        }
        let result = api.call(method, parameters)
        if case .failure(.rateLimited(let seconds)) = result, gates[method] != nil { limit(method, seconds) }
        return result
    }
    /// What the user is told while a method still waits out its refusal, whatever else is read meanwhile.
    private func limitStatus(_ at: Date) -> Status? {
        gates.values.contains { $0.until > at } ? .failed(SlackAPI.message(.rateLimited(0))) : nil
    }

    private func receiveThreadRead(_ json: [String: Any], room: String, ts: String) {
        threadReadAt[room + ":" + ts] = clock
        guard let parent = (json["messages"] as? [[String: Any]])?.first, parent["ts"] as? String == ts else { return }
        let key = "slack:" + room + ":" + ts
        if parent["last_read"] == nil {
            snapshot.threadRead[key] = nil; snapshot.threadUnfollowed.insert(key)
        } else if let raw = parent["last_read"] as? String, let value = Double(raw), value.isFinite {
            snapshot.threadRead[key] = value; snapshot.threadUnfollowed.remove(key)
        }
    }

    private func syncRead(_ request: Request, known: Set<String>, waiting: Bool, now: Date) -> Bool {
        var outgoing: [String: SlackMessage] = [:]
        for (room, through) in request.localRead where request.writesRead {
            let flow = (state.history[room] ?? []).filter { $0.isRoot || $0.broadcast }
                + Array((state.extra[room] ?? [:]).values)
                + (state.replies[room]?.values.flatMap { $0 }.filter(\.broadcast) ?? [])
            outgoing[room] = flow.filter { $0.time <= through }.max { $0.time < $1.time }
        }
        let localRooms = Set(request.localRead.keys.filter { request.writesRead && (snapshot.roomRead[$0] == nil || (outgoing[$0]?.time ?? 0) > (snapshot.roomRead[$0] ?? 0)) })
        let rooms = request.readRooms.union(localRooms).intersection(known).sorted {
            if localRooms.contains($0) != localRooms.contains($1) { return localRooms.contains($0) }
            if (snapshot.roomRead[$0] == nil) != (snapshot.roomRead[$1] == nil) { return snapshot.roomRead[$0] == nil }
            return (roomReadAt[$0] ?? .distantPast, $0) < (roomReadAt[$1] ?? .distantPast, $1)
        }
        for room in rooms.filter({ now.timeIntervalSince(roomReadAt[$0] ?? .distantPast) >= 10 }).prefix(2) {
            guard now >= infoWait, now.timeIntervalSince(infoAt) >= 5 else { break }
            infoAt = now
            roomReadAt[room] = now; calls.append("conversations.info")
            switch api.call("conversations.info", ["channel": room]) {
            case .success(let json):
                if let channel = json["channel"] as? [String: Any], let raw = channel["last_read"] as? String,
                   let value = Double(raw), value.isFinite {
                    snapshot.roomRead[room] = value; roomReadReceived[room] = now
                }
            case .failure(.rateLimited(let seconds)): infoWait = now.addingTimeInterval(max(1, seconds)); refused("conversations.info", wait: seconds)
            case .failure: break
            }
        }
        readRefreshes.removeAll { now.timeIntervalSince($0) >= 60 }
        let unknown = Set(request.localThreads.keys.filter { request.writesRead && snapshot.threadRead["slack:" + $0] == nil && !snapshot.threadUnfollowed.contains("slack:" + $0) })
        let threads = request.readThreads.union(unknown).sorted {
            if unknown.contains($0) != unknown.contains($1) { return unknown.contains($0) }
            return (threadReadAt[$0] ?? .distantPast, $0) < (threadReadAt[$1] ?? .distantPast, $1)
        }
        for key in threads {
            guard !waiting, readRefreshes.count < 4, roomForCall(now), now.timeIntervalSince(threadReadAt[key] ?? .distantPast) >= 20 else { continue }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, known.contains(parts[0]) else { continue }
            let before = threadReadAt[key]
            threadReadAt[key] = now; readRefreshes.append(now)
            if !loadReplies(parts[0], parts[1]) { return false }
            if deferred { threadReadAt[key] = before; readRefreshes.removeLast() }
            break
        }
        guard request.writesRead else { return true }
        var budget = 2
        for room in request.localRead.keys.sorted() where known.contains(room) {
            guard let read = snapshot.roomRead[room], let received = roomReadReceived[room], now.timeIntervalSince(received) <= 30 else { continue }
            guard let newest = outgoing[room], newest.time > read else { continue }
            mark("conversations.mark", key: room, parameters: ["channel": room, "ts": newest.ts], now: now, budget: &budget)
        }
        for (key, through) in request.localThreads.sorted(by: { $0.key < $1.key }) {
            guard let read = snapshot.threadRead["slack:" + key], !snapshot.threadUnfollowed.contains("slack:" + key) else { continue }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, known.contains(parts[0]) else { continue }
            let room = parts[0], ts = parts[1]
            let root = state.history[room]?.first { $0.ts == ts } ?? state.extra[room]?[ts]
            let stamps = (state.replies[room]?[ts] ?? []).map(\.ts) + [root?.latestReply].compactMap { $0 }
            guard let newest = stamps.filter({ (Double($0) ?? 0) <= through }).max(by: { (Double($0) ?? 0) < (Double($1) ?? 0) }),
                  (Double(newest) ?? 0) > read else { continue }
            mark("subscriptions.thread.mark", key: key, parameters: ["channel": room, "thread_ts": ts, "ts": newest, "read": "1"], now: now, budget: &budget)
        }
        return true
    }

    private func mark(_ method: String, key: String, parameters: [String: String], now: Date, budget: inout Int) {
        let stamp = Double(parameters["ts"] ?? "") ?? 0
        guard budget > 0, !disabledWrites.contains(method), now >= (writeWait[method] ?? .distantPast),
              now >= (keyWriteWait[key] ?? .distantPast), now.timeIntervalSince(markAt[key] ?? .distantPast) >= 5,
              stamp > (sentMarks[key] ?? 0) else { return }
        budget -= 1; markAt[key] = now; calls.append(method)
        defer { lastWrite = (method, now, writeState[method] ?? "unknown") }
        switch api.call(method, parameters) {
        case .success:
            sentMarks[key] = stamp; writeState[method] = "working" + (writeError[method].map { " last_error=" + $0 } ?? "")
            snapshot.ownRead[method == "conversations.mark" ? key : "slack:" + key] = stamp
            if method == "conversations.mark" { snapshot.roomRead[key] = max(snapshot.roomRead[key] ?? 0, stamp) }
            else { snapshot.threadRead["slack:" + key] = max(snapshot.threadRead["slack:" + key] ?? 0, stamp) }
        case .failure(.rateLimited(let seconds)):
            writeWait[method] = now.addingTimeInterval(max(1, seconds)); writeState[method] = "rate_limited"
            refused(method, wait: seconds)
        case .failure(.api(let code)):
            writeState[method] = code; writeError[method] = code
            if code.hasPrefix("missing_scope") { writeWait[method] = now.addingTimeInterval(600) }
            else if ["unknown_method", "not_allowed_token_type", "invalid_auth", "not_authed", "token_revoked", "account_inactive"].contains(code) { disabledWrites.insert(method) }
            else { keyWriteWait[key] = now.addingTimeInterval(600) }
        case .failure(.network):
            writeWait[method] = now.addingTimeInterval(Self.retryInterval); writeState[method] = "network"
        }
    }

    /// Called on the Slack queue. Only stamps, flags and fixed state names leave it.
    func diagnostics(room: String) -> String {
        let lastAttempt = lastWrite.map { "read sync last: method=\($0.method) result=\($0.result) at=\($0.at.timeIntervalSince1970)\n" } ?? ""
        if retention.cacheExcluded.contains(room) { return "room contents not kept\n" + lastAttempt }
        let threads = state.threads(room: room, characters: characters)
        let roots = Set((state.history[room] ?? []).filter(\.isRoot).map(\.ts))
        let candidates = Set((state.channelTimes[room] ?? [:]).keys).union((extraRead[room] ?? [:]).keys).subtracting(roots)
        let reads = recentCalls.filter { $0.method == "conversations.replies" && clock.timeIntervalSince($0.at) < 60 }
        var lines = ["my recent posts in the shown room (newest first): marks Slack put on each"] + (selfPosts[room] ?? [])
        lines += ["history room=\(room)"] + (historyStructure[room] ?? ["not-read"])
        lines += ["threads (position order)"] + threads.map { thread in
            "ts=\(thread.ts) position=\(thread.position.timeIntervalSince1970) replies=\(thread.replies.count) reply_count=\(thread.replyCount) loaded=\(thread.loaded) extra=\(!roots.contains(thread.ts) && state.extra[room]?[thread.ts] != nil)"
        }
        lines += ["extra reads: skipped_budget=\(skippedBudget[room] ?? 0) skipped_calls=\(skippedCalls[room] ?? 0) replies_last_minute=\(reads.count) urgent=\(reads.filter(\.urgent).count) nonurgent=\(reads.filter { !$0.urgent }.count)"]
        let called = Set((state.history[room] ?? []).filter { !$0.isRoot }.compactMap(\.threadTS))
        lines += candidates.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }.map { ts in
            let key = room + ":" + ts
            let newer = (state.channelTimes[room]?[ts] ?? 0) > (broadcastStamp[key] ?? 0)
            let status = extraRead[room]?[ts] ?? (state.extra[room]?[ts] != nil ? "kept" : "waiting")
            // A thread whose line in the channel has left the listing is no longer asked for.
            if !called.contains(ts), status == "waiting" || (newer && status != "thread_not_found") { return "ts=\(ts) status=left_history" }
            // One that came with what was kept was never waited for.
            if status == "kept", !newer { return "ts=\(ts) status=kept" }
            let seconds = max(0, (candidateRead[key] ?? observedAt).timeIntervalSince(candidateSeen[key] ?? observedAt))
            return "ts=\(ts) status=\(newer && ["read", "kept"].contains(status) ? "waiting" : status) delay_seconds=\(String(format: "%.1f", seconds))"
        }
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        lines += ["start: \(cacheNote) cache_bytes=\(cacheBytes) open=\(lastOpen) shown=\(lastShown.contains(room)) threads_after_seconds=\(seconds(firstThreads[room])) older_thread_after_seconds=\(seconds(firstExtra[room]))"]
        lines += ["urgent threads (last minute, top ten)"]
        let groups = Dictionary(grouping: reads.filter(\.urgent), by: { $0.room + ":" + $0.ts })
        lines += groups.sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }.prefix(10).map { key, calls in
            let reasons = Dictionary(grouping: calls, by: \.reason).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.count)" }.joined(separator: ",")
            return "thread=\(key) calls=\(calls.count) reasons=\(reasons)"
        }
        if !lastAttempt.isEmpty { lines.append(lastAttempt.trimmingCharacters(in: .newlines)) }
        let listings = recentCalls.filter { $0.method == "conversations.history" && clock.timeIntervalSince($0.at) < 60 }
        refusals.removeAll { clock.timeIntervalSince($0.at) >= 3600 }
        let last = refusals.last.map { " last=\($0.method) at=\($0.at.timeIntervalSince1970) wait=\($0.wait)" } ?? ""
        let byMethod = Dictionary(grouping: refusals, by: \.method).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.count)" }.joined(separator: ",")
        let history = gates["conversations.history"], replies = gates["conversations.replies"]
        func waiting(_ gate: Gate?) -> String { gate.map { $0.until > observedAt ? String(format: "%.1f", $0.until.timeIntervalSince(observedAt)) : "0" } ?? "0" }
        lines += ["pace: level=\(history?.pace ?? 1) history_last_minute=\(listings.count) shown=\(listings.filter(\.urgent).count) fastest=\(history?.fastest ?? 1) refused_last_hour=\(refusals.count)\(byMethod.isEmpty ? "" : " " + byMethod)\(last)"
                  + " replies_level=\(replies?.pace ?? 1) history_wait=\(waiting(history)) replies_wait=\(waiting(replies))"]
        lines += pageLog.isEmpty ? [] : ["page clicks (structure only)"] + pageLog
        lines += ["read sync: room_write=\(writeState["conversations.mark"] ?? "not_attempted") required=channels:write,groups:write,im:write thread_write=\(writeState["subscriptions.thread.mark"] ?? "not_attempted") room_read=\(snapshot.roomRead[room] == nil ? "unknown" : "known") unfollowed=\(snapshot.threadUnfollowed.filter { $0.hasPrefix("slack:" + room + ":") }.count) room_received_at=\(roomReadReceived[room]?.timeIntervalSince1970 ?? 0) threads=\(snapshot.threadRead.keys.filter { $0.hasPrefix("slack:" + room + ":") }.count)"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func structure(_ post: [String: Any]) -> String {
        func stamp(_ key: String) -> String {
            guard let value = post[key] as? String else { return "-" }
            return value.count <= 32 && !value.isEmpty && value.allSatisfy { "0123456789.".contains($0) } ? value : "invalid"
        }
        let subtype = post["subtype"] as? String ?? "-"
        let safeSubtype = subtype.count <= 64 && subtype.allSatisfy { "abcdefghijklmnopqrstuvwxyz_-".contains($0) } ? subtype : "invalid"
        let flags = ["edited", "root", "bot_id", "attachments"].map { "\($0)=\(post[$0] != nil)" }.joined(separator: " ")
        return "ts=\(stamp("ts")) thread_ts=\(stamp("thread_ts")) subtype=\(safeSubtype) reply_count=\(post["reply_count"] as? Int ?? 0) latest_reply=\(stamp("latest_reply")) \(flags) discarded=\(SlackMessage(json: post) == nil)"
    }
    private var recentCalls: [(method: String, at: Date, urgent: Bool, room: String, ts: String, reason: String)] = []
    private var clock = Date()
    /// Seconds since the Mac started; a test hands in its own, to stand for a slow answer.
    private let uptime: () -> TimeInterval
    private lazy var syncStarted = uptime()
    private var observedAt: Date { clock.addingTimeInterval(max(0, uptime() - syncStarted)) }
    private(set) var calls: [String] = []

    /// A thread being deleted from Slack: the stamps still to go, the first message last.
    /// While `left` is nil its messages are still being gathered, a page at a time: what was found, mine or not, and where the next page starts.
    private struct Deleting {
        var room: String; var ts: String; var left: [String]?; var total = 0; var tries = 0
        var found: [(ts: String, mine: Bool)] = []; var cursor = ""; var pages = 0
    }
    private var deleting: [Deleting] = []
    private var deletedAt = Date.distantPast
    private var deletingPausedUntil = Date.distantPast
    /// Slack allows about fifty deletions a minute; one at this pace stays under it.
    static let deleteInterval: TimeInterval = 1.3
    static let deleteTries = 5
    static let deletePages = 10

    /// Deletes a thread from Slack, every reply and then its first message, a message at a time over the passes
    /// that follow. Slack lets a person delete their own messages, and an admin anyone's; a message that may not
    /// be deleted stops it, and others' messages are tried first so that it stops before anything is gone.
    func delete(room: String, ts: String, singleOnly: Bool = false) {
        if singleOnly {
            guard !state.me.isEmpty,
                  snapshot.threads[room]?.contains(where: { $0.ts == ts && $0.root.fromUser }) == true else { return }
        }
        guard !deleting.contains(where: { $0.room == room && $0.ts == ts }) else { return }
        deleting.append(Deleting(room: room, ts: ts, left: singleOnly ? [ts] : nil, total: singleOnly ? 1 : 0))
        snapshot.removing["slack:\(room):\(ts)"] = Removal(done: 0, total: 0)
        snapshot.removed["slack:\(room):\(ts)"] = nil
    }

    /// One step of the deleting under way. Its failures are its own: the reading of rooms goes on.
    private func advanceDeleting(now: Date) {
        guard var job = deleting.first, now >= deletingPausedUntil else { return }
        let id = "slack:\(job.room):\(job.ts)"
        func end(_ reason: String?) {
            deleting.removeFirst(); snapshot.removing[id] = nil; snapshot.removed[id] = .some(reason)
            if reason == nil {
                state.history[job.room]?.removeAll { $0.ts == job.ts || $0.threadTS == job.ts }
                state.extra[job.room]?[job.ts] = nil; state.replies[job.room]?[job.ts] = nil; state.channelTimes[job.room]?[job.ts] = nil
                let key = job.room + ":" + job.ts
                fetched[key] = nil; first[key] = nil; broadcastStamp[key] = nil; extraStamp[key] = nil
            }
            // What is left of it is read again, so the room shows what Slack now holds.
            fetched[job.room + ":" + job.ts] = nil
            dirty.insert(job.room)
        }
        func failed(_ failure: SlackAPI.Failure) {
            switch failure {
            case .rateLimited(let seconds): deletingPausedUntil = observedAt.addingTimeInterval(max(1, seconds))
            case .network:
                job.tries += 1; deleting[0] = job
                if job.tries >= Self.deleteTries { end("슬랙에 연결하지 못해 삭제를 멈췄어요. 남은 글은 그대로 있어요.") } else { deletingPausedUntil = now.addingTimeInterval(5) }
            case .api(let code):
                if code == "cant_delete_message" { end("내 계정으로 지울 수 없는 글이 있어 삭제를 멈췄어요. 다른 사람이나 앱이 쓴 글은 워크스페이스 관리자만 지울 수 있어요.") }
                else { end("삭제를 멈췄어요. " + SlackAPI.message(failure)) }
            }
        }
        guard var left = job.left else {
            // Everything in the thread, read afresh: what was read before may be short of it. Each page read is kept, so a
            // reading held back or refused goes on from the next page when its turn comes, never from the first.
            repeat {
                var parameters = ["channel": job.room, "ts": job.ts, "limit": "200"]
                if !job.cursor.isEmpty { parameters["cursor"] = job.cursor }
                // Reading the thread waits with every other reading of threads.
                guard let result = send("conversations.replies", parameters) else { return }
                calls.append("conversations.replies")
                switch result {
                case .failure(.api("thread_not_found")): job.found = []; job.cursor = ""
                case .failure(let failure): failed(failure); return
                case .success(let json):
                    var seen = Set(job.found.map(\.ts))
                    for raw in json["messages"] as? [[String: Any]] ?? [] {
                        guard let ts = raw["ts"] as? String, seen.insert(ts).inserted else { continue }
                        job.found.append((ts, raw["user"] as? String == state.me && raw["bot_id"] == nil))
                    }
                    job.cursor = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
                }
                job.pages += 1; job.tries = 0
                deleting[0] = job
            } while !job.cursor.isEmpty && job.pages < Self.deletePages
            // A thread longer than can be read is not deleted at all: deleting part of it, or its first message, would leave the rest adrift.
            guard job.cursor.isEmpty else { end("스레드가 너무 길어 삭제를 멈췄어요. 지운 글은 없어요."); return }
            let found = job.found
            let replies = found.filter { $0.ts != job.ts }.sorted { (Double($0.ts) ?? 0) > (Double($1.ts) ?? 0) }
            job.left = replies.filter { !$0.mine }.map(\.ts) + replies.filter(\.mine).map(\.ts) + [job.ts]
            job.total = job.left?.count ?? 0
            deleting[0] = job
            snapshot.removing[id] = Removal(done: 0, total: job.total)
            return
        }
        guard now.timeIntervalSince(deletedAt) >= Self.deleteInterval else { return }
        guard let next = left.first else { end(nil); return }
        deletedAt = now
        calls.append("chat.delete")
        switch api.call("chat.delete", ["channel": job.room, "ts": next]) {
        case .failure(.api("message_not_found")), .success:
            left.removeFirst(); job.left = left; job.tries = 0; deleting[0] = job
            snapshot.removing[id] = Removal(done: job.total - left.count, total: job.total)
            if left.isEmpty { end(nil) }
        case .failure(let failure): failed(failure)
        }
    }

    /// Where what was read is kept between runs; nil keeps nothing.
    private let cacheURL: URL?
    private var cacheChanged = false
    private var cacheSavedAt = Date.distantPast
    private var cacheNote = "cache=none"
    private var cacheBytes = 0
    /// When each room's listing was last read, kept with the cache.
    private var readAt: [String: Double] = [:]
    /// True once Slack has said whose token this is. What a last run kept is shown before that, but not written again.
    private var verified = false
    private var recentKeys = Set<String>()
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private var firstThreads: [String: Double] = [:]
    private var firstExtra: [String: Double] = [:]
    private var configGeneration = -1
    private var lastOpen = false
    private var lastShown = Set<String>()

    let retention: SlackRetention
    init(api: SlackAPI, cache: URL? = nil, retention: SlackRetention = SlackRetention(), uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.api = api; cacheURL = cache; self.retention = retention; self.uptime = uptime
    }

    func removeUnkeptCache() {
        retention.locked {
            guard !retention.cacheExcluded.isEmpty else { return }
            guard let cacheURL else { return }
            guard var cache = SlackCache.read(cacheURL) else {
                if !retention.cacheExcluded.isEmpty { SlackCache.delete(cacheURL) }
                return
            }
            for room in retention.cacheExcluded { cache.drop(room) }
            if let data = cache.fitted(), SlackCache.write(data, to: cacheURL) { return }
            SlackCache.delete(cacheURL)
        }
    }

    /// Fills in what the last run kept, so the rooms can be shown before Slack is asked anything. Each room's listing
    /// is still read as usual, and only a thread whose newest reply has changed since is read again.
    func restore(characters: [ChatCharacter], now: Date = Date()) -> Snapshot? {
        removeUnkeptCache()
        guard let cacheURL, let cache = SlackCache.read(cacheURL), !cache.state.me.isEmpty else { return nil }
        state = cache.state; fetched = cache.fetched; first = cache.first
        broadcastStamp = cache.broadcastStamp; extraStamp = cache.extraStamp
        memberIDs = cache.memberIDs; imUsers = cache.imUsers; readAt = cache.readAt
        deletedUsers = cache.deletedUsers ?? []
        snapshot.rooms = cache.rooms; snapshot.workspace = cache.workspace
        self.characters = characters
        rebuildMembers()
        for room in snapshot.rooms.map(\.id) where state.history[room] != nil { snapshot.threads[room] = state.threads(room: room, characters: characters) }
        cacheSavedAt = now
        cacheBytes = (try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        cacheNote = "cache=restored age_seconds=\(Int(max(0, now.timeIntervalSince1970 - cache.savedAt))) rooms=\(snapshot.threads.count) threads=\(snapshot.threads.values.reduce(0) { $0 + $1.count })"
        noteShown()
        return snapshot
    }

    /// What was kept belongs to whoever was connected when it was written.
    private func forget() {
        thinkingMemo = SlackThinkingMemo(); watchedPass = nil
        state = SlackState(); fetched = [:]; first = [:]; broadcastStamp = [:]; extraStamp = [:]
        memberIDs = [:]; imUsers = [:]; deletedUsers = []; nameRetry = [:]; readAt = [:]; dirty = []
        snapshot = Snapshot(); roomsAt = .distantPast
        firstThreads = [:]; firstExtra = [:]
        cacheChanged = false; cacheNote = "cache=discarded"; cacheBytes = 0
        if let cacheURL { SlackCache.delete(cacheURL) }
    }

    /// Writes what is on show, when it has changed and not too soon after the last time.
    private func keep(now: Date, force: Bool = false) {
        retention.locked {
        guard let cacheURL, verified, cacheChanged, !state.me.isEmpty, force || now.timeIntervalSince(cacheSavedAt) >= SlackCache.saveInterval else { return }
        var cache = SlackCache(savedAt: now.timeIntervalSince1970, state: state, rooms: snapshot.rooms, workspace: snapshot.workspace,
                               memberIDs: memberIDs, imUsers: imUsers, deletedUsers: deletedUsers, fetched: fetched, first: first,
                               broadcastStamp: broadcastStamp, extraStamp: extraStamp, readAt: readAt)
        cache.prune(listed: roomsAt == .distantPast ? nil : Set(snapshot.rooms.map(\.id)), recent: recentKeys, now: now.timeIntervalSince1970)
        for room in retention.cacheExcluded { cache.drop(room) }
        cacheSavedAt = now
        guard let data = cache.fitted(), SlackCache.write(data, to: cacheURL) else { return }
        cacheChanged = false; cacheBytes = data.count
        }
    }

    /// Called on the Slack queue as the app closes.
    func flush(now: Date = Date()) { keep(now: now, force: true) }

    /// How long after this connection began each room first had threads to show, and a thread older than its listing.
    private func noteShown() {
        let elapsed = ProcessInfo.processInfo.systemUptime - createdAt
        for (room, threads) in snapshot.threads where !threads.isEmpty {
            if firstThreads[room] == nil { firstThreads[room] = elapsed }
            if firstExtra[room] == nil, let older = state.extra[room], threads.contains(where: { older[$0.ts] != nil }) { firstExtra[room] = elapsed }
        }
    }

    /// `room` is the room the call is about. A failure that is that room's alone rests the room and lets the pass go on.
    private func call(_ method: String, _ parameters: [String: String] = [:], room: String? = nil, urgentReason: String = "") -> [String: Any]? {
        roomAlone = false; lastCode = ""; deferred = false
        // A method still waiting out its refusal, or with nothing left to spend, is asked for on a later pass; the pass goes on.
        guard let result = send(method, parameters) else { deferred = true; roomAlone = true; return nil }
        calls.append(method); recentCalls.append((method, clock, !urgentReason.isEmpty, room ?? "", parameters["ts"] ?? "", urgentReason))
        switch result {
        case .success(let json): return json
        case .failure(.rateLimited) where gates[method] != nil:
            // Only this method waits; what was being read is left as it was, to be read when the wait is over.
            deferred = true; roomAlone = true; lastCode = "ratelimited"; return nil
        case .failure(let failure):
            if let room, case .api(let code) = failure {
                lastCode = code
                // A thread that is gone is its own matter; the room it was in is fine.
                if code == "thread_not_found" { roomAlone = true; return nil }
                if Self.roomOnly(code) {
                    roomAlone = true
                    resting[room] = clock.addingTimeInterval(Self.roomRest)
                    snapshot.problems[room] = SlackAPI.message(failure)
                    return nil
                }
            }
            // A refused token or a dead network is retried slowly rather than on every pass.
            if case .rateLimited(let seconds) = failure { pausedUntil = clock.addingTimeInterval(max(1, seconds)); refused(method, wait: seconds) }
            else { pausedUntil = clock.addingTimeInterval(Self.retryInterval) }
            snapshot.status = .failed(SlackAPI.message(failure)); return nil
        }
    }

    func sync(_ request: Request, now: Date = Date()) -> Snapshot {
        calls = []; clock = now; syncStarted = uptime()
        // How each deleting ended is handed over once.
        snapshot.removed = [:]
        guard now >= pausedUntil else { return snapshot }
        recentCalls.removeAll { now.timeIntervalSince($0.at) >= 60 }
        for (method, var gate) in gates {
            if gate.fastest < 1, now.timeIntervalSince(gate.fastestAt) >= Self.paceMemory { gate.fastest = min(1, gate.fastest + Self.paceStep); gate.fastestAt = now }
            if gate.pace < gate.fastest, now.timeIntervalSince(gate.pacedAt) >= Self.paceRest { gate.pace = min(gate.fastest, gate.pace + Self.paceStep); gate.pacedAt = now }
            gates[method] = gate
        }
        recentKeys = Set(request.recent.keys)
        let finished = pass(request, now: now)
        // What was read before a call failed is shown all the same.
        // A room that has not been read yet has no threads to show; listing it as empty would pass for a room with nothing in it.
        for room in dirty where state.history[room] != nil { snapshot.threads[room] = state.threads(room: room, characters: characters) }
        if !dirty.isEmpty { cacheChanged = true }
        dirty = []
        // A method still waiting keeps its notice however much else was read; when the wait is over the next round clears it.
        // A round cut short by something else keeps that reason; one cut short with nothing said says the wait.
        var told = false
        if case .failed = snapshot.status { told = true }
        if let limited = limitStatus(observedAt), finished || !told { snapshot.status = limited }
        else if finished, !fetchedAt.isEmpty { snapshot.status = .connected }
        noteShown()
        keep(now: now)
        return snapshot
    }

    /// One round of reading. False when a call failed in a way that ends the round: the token, the network, a rate limit.
    private var thinkingMemo = SlackThinkingMemo()
    private var watchedPass: [String: [(ts: String, every: TimeInterval, reason: String)]]?
    private func pass(_ request: Request, now: Date) -> Bool {
        watchedPass = [:]
        defer { watchedPass = nil }
        skippedBudget = [:]; skippedCalls = [:]
        if state.me.isEmpty || !verified {
            guard let identity = call("auth.test"), let me = identity["user_id"] as? String else { return false }
            if !state.me.isEmpty, state.me != me { forget() }
            state.me = me; snapshot.me = me; verified = true
            snapshot.workspace = identity["url"] as? String ?? ""
        }
        if roomsAt == .distantPast || now.timeIntervalSince(roomsAt) >= 300 { guard loadRooms(now: now) else { return false } }
        advanceDeleting(now: now)
        DdotsConfig.shared.refresh(force: false)
        if characters != request.characters || configGeneration != DdotsConfig.shared.generation {
            configGeneration = DdotsConfig.shared.generation
            characters = request.characters; dirty.formUnion(snapshot.rooms.map(\.id)); rebuildMembers()
        }

        // A room that is resting after Slack refused it is passed over until its rest is done.
        var known = Set(snapshot.rooms.map(\.id).filter { (resting[$0] ?? .distantPast) <= now })
        var due: [String] = [], background = Set<String>()
        if request.open, let active = request.active, known.contains(active) {
            let grown = (request.limits[active] ?? Self.pageSize) > (loadedLimit[active] ?? 0)
            if grown || now.timeIntervalSince(fetchedAt[active] ?? .distantPast) >= Self.activeInterval { due.append(active) }
        }
        // Watched rooms take turns, so the pace of requests does not grow with their number.
        // One that has never been read, or was asked for further back, does not wait for its turn.
        let watched = request.watch.filter { known.contains($0) && !due.contains($0) }
        let eager = watched.filter { fetchedAt[$0] == nil || (request.limits[$0] ?? Self.pageSize) > (loadedLimit[$0] ?? 0) }
        if !eager.isEmpty { due += eager.prefix(2); watchedAt = now }
        // A room watched alone is read no more often than the one chosen would be.
        else if now.timeIntervalSince(watchedAt) >= Self.watchInterval,
                let next = watched.min(by: { (fetchedAt[$0] ?? .distantPast) < (fetchedAt[$1] ?? .distantPast) }),
                now.timeIntervalSince(fetchedAt[next] ?? .distantPast) >= Self.activeInterval { due.append(next); watchedAt = now }
        // A room where a character is answering is watched at the same pace, whichever room is on screen.
        for room in snapshot.rooms.map(\.id) where known.contains(room) && !due.contains(room) && !request.skipped.contains(room) && due.count < 3 {
            if !liveThreads(room, now: now).isEmpty, now.timeIntervalSince(fetchedAt[room] ?? .distantPast) >= Self.activeInterval { due.append(room) }
        }
        // One other room per pass keeps the request rate flat however many rooms there are.
        if let stale = snapshot.rooms.map(\.id).filter({ known.contains($0) && !request.skipped.contains($0) && !due.contains($0) && now.timeIntervalSince(fetchedAt[$0] ?? .distantPast) >= Self.idleInterval })
            .min(by: { (fetchedAt[$0] ?? .distantPast) < (fetchedAt[$1] ?? .distantPast) }) { due.append(stale); background.insert(stale) }
        // A room that finds no allowance left is read on a later pass.
        for room in due where roomForHistory(now, shown: !background.contains(room)) {
            guard loadHistory(room, limit: request.limits[room] ?? Self.pageSize, now: now, shown: !background.contains(room)) else { return false }
        }
        // A room refused just now is not asked about again in the same round.
        known.subtract(resting.filter { $0.value > now }.keys)

        var budget = Self.repliesPerSync
        // The rooms on screen come before the others: the one chosen, and the ones ddots shows together.
        var front: [String] = []
        for room in (request.active.map { [$0] } ?? []) + request.watch where known.contains(room) && !front.contains(room) { front.append(room) }
        let order = front + snapshot.rooms.map(\.id).filter { !front.contains($0) }
        let shown = (request.open ? request.active.map { [$0] } ?? [] : []) + request.watch
        lastOpen = request.open; lastShown = Set(shown)
        let pending = front.filter(shown.contains).contains { !staleThreads($0, wanted: request.wanted, eager: Int.max).isEmpty || !channelCandidates($0).isEmpty }
        // First the threads where something is happening: a reply that changed, a thread the user opened, and
        // a thread a character is answering in. An answer replaces its "생각 중" line in place, which the room's
        // listing does not show as a change, so such a thread is read again on every pass until it settles.
        var urgent = Self.urgentPerSync
        for room in order where known.contains(room) && urgent > 0 {
            let watched = watchedThreads(room, now: now)
            let changed = staleThreads(room, wanted: request.wanted, eager: 0)
            for ts in changed + watched.map(\.ts).filter({ !changed.contains($0) }) where urgent > 0 {
                let key = room + ":" + ts
                let every = watched.first { $0.ts == ts }?.every ?? Self.liveInterval
                if !changed.contains(ts), now.timeIntervalSince(repliesAt[key] ?? .distantPast) < every { continue }
                guard roomForCall(now, urgent: true, waiting: pending) else { break }
                urgent -= 1
                guard loadReplies(room, ts, urgentReason: changed.contains(ts) ? "changed" : watched.first { $0.ts == ts }?.reason ?? "live") else { return false }
                if !deferred { repliesAt[key] = now }
            }
        }
        // Then every thread of what is on screen, newest first whichever of its rooms holds it. Until a thread's
        // replies are read only their number can be shown, so the lines being looked at fill in before anything else.
        var shownBudget = Self.shownRepliesPerSync
        let waiting = front.filter(shown.contains).flatMap { room in
            staleThreads(room, wanted: request.wanted, eager: Int.max).map { (room: room, ts: $0, time: Double($0) ?? 0, extra: false) }
                + channelCandidates(room).map { (room: room, ts: $0.ts, time: $0.stamp, extra: true) }
        }.sorted { ($0.time, $0.room, $0.ts) > ($1.time, $1.room, $1.ts) }
        for item in waiting {
            if item.extra {
                guard readCandidate(item.room, item.ts, stamp: item.time, recent: request.recent, budget: &shownBudget, now: now) else { return false }
            } else {
                guard shownBudget > 0, roomForCall(now) else { continue }
                shownBudget -= 1
                guard loadReplies(item.room, item.ts) else { return false }
                if !deferred { repliesAt[item.room + ":" + item.ts] = now }
            }
        }
        // Then the rest, a little at a time, so that reading a whole room never crowds out what is live.
        for room in order where known.contains(room) {
            // A reply shown in the channel under a first message older than the listing brings that thread into view,
            // so it is read before the room's other threads, whether or not the window is open.
            if !shown.contains(room) {
                for item in channelCandidates(room) {
                    guard readCandidate(room, item.ts, stamp: item.stamp, recent: request.recent, budget: &budget, now: now) else { return false }
                }
            }
            // Every thread of the room on screen is read, since its notice counts what is still open in each.
            let whole = (room == request.active && request.open) || request.watch.contains(room)
            for ts in staleThreads(room, wanted: request.wanted, eager: whole ? Int.max : Self.eagerThreads) {
                guard budget > 0, roomForCall(now) else { break }
                budget -= 1
                guard loadReplies(room, ts) else { return false }
                if !deferred { repliesAt[room + ":" + ts] = now }
            }
        }
        // Other older threads are found when Hermes records new activity in them.
        for (key, at) in request.recent.sorted(by: { $0.value > $1.value }) where (extraStamp[key] ?? 0) < at {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, known.contains(parts[0]), state.history[parts[0]] != nil else { continue }
            if state.history[parts[0]]?.contains(where: { $0.isRoot && $0.ts == parts[1] }) == true || repliesAt[key] == now { extraStamp[key] = at; continue }
            if channelCandidates(parts[0]).contains(where: { $0.ts == parts[1] }) { continue }
            extraRead[parts[0], default: [:]][parts[1]] = "waiting"
            if budget <= 0 { skippedBudget[parts[0], default: 0] += 1; continue }
            if !roomForCall(now) { skippedCalls[parts[0], default: 0] += 1; continue }
            budget -= 1
            guard loadExtra(parts[0], parts[1]) else { return false }
            guard resting[parts[0]] == nil, !deferred else { continue }
            repliesAt[key] = now; extraStamp[key] = at
        }
        guard advanceScans(request, known: known, now: now) else { return false }
        let waitingRead = shown.contains { !staleThreads($0, wanted: request.wanted, eager: Int.max).isEmpty || !channelCandidates($0).isEmpty }
        guard syncRead(request, known: known, waiting: waitingRead, now: now) else { return false }
        var names = 5
        for room in order where known.contains(room) {
            for user in state.unknownUsers(room: room) where names > 0 {
                names -= 1
                guard resolve(user) else { return false }
                dirty.insert(room)
            }
        }
        // A name that could not be read is asked for again, so nobody is left out for a failure that passed.
        for user in nameRetry.filter({ $0.value.next <= now }).keys.sorted() where names > 0 {
            names -= 1
            guard resolve(user) else { return false }
            if state.users[user] != Self.unknownName { rebuildMembers(); dirty.formUnion(snapshot.rooms.map(\.id)) }
        }
        return true
    }

    private func channelCandidates(_ room: String) -> [(ts: String, stamp: Double)] {
        let history = state.history[room] ?? []
        let roots = Set(history.filter(\.isRoot).map(\.ts))
        return Dictionary(grouping: history.filter { !$0.isRoot }, by: { $0.threadTS ?? "" }).compactMap { ts, lines in
            let stamp = lines.map(\.time).max() ?? 0
            guard !roots.contains(ts), stamp > (broadcastStamp[room + ":" + ts] ?? 0) else { return nil }
            return (ts: ts, stamp: stamp)
        }.sorted { ($0.stamp, $0.ts) > ($1.stamp, $1.ts) }
    }

    /// Both queues share receipts, including missing threads, and never read a candidate twice in one pass.
    private func readCandidate(_ room: String, _ ts: String, stamp: Double, recent: [String: Double], budget: inout Int, now: Date) -> Bool {
        let key = room + ":" + ts
        if candidateSeen[key] == nil { candidateSeen[key] = observedAt }
        if repliesAt[key] != now {
            extraRead[room, default: [:]][ts] = "waiting"
            if budget <= 0 { skippedBudget[room, default: 0] += 1; return true }
            if !roomForCall(now) { skippedCalls[room, default: 0] += 1; return true }
            budget -= 1
            guard loadExtra(room, ts) else { return false }
            guard resting[room] == nil, !deferred else { return true }
            repliesAt[key] = now
        }
        if extraRead[room]?[ts] == nil { extraRead[room, default: [:]][ts] = "read" }
        if ["read", "thread_not_found"].contains(extraRead[room]?[ts] ?? ""), candidateRead[key] == nil { candidateRead[key] = observedAt }
        broadcastStamp[key] = stamp
        if let at = recent[key] { extraStamp[key] = at }
        return true
    }

    /// Reads a little further back through one room for the record. A room's listing gives only first messages, each with
    /// the stamp of its newest reply, so every first message Slack still shows is looked at and only threads that hold
    /// something newer than `since` are opened. False when a call failed and the pass should end.
    private func advanceScans(_ request: Request, known: Set<String>, now: Date) -> Bool {
        for (room, since) in request.scan where scans[room] == nil && scanFinished[room] != since && known.contains(room) {
            scans[room] = Scan(since: since, started: now.timeIntervalSince1970)
        }
        guard let room = scans.keys.sorted().first(where: known.contains), var scan = scans[room] else { return true }
        defer { if scans[room] != nil { scans[room] = scan } }
        var budget = Self.repliesPerSync
        while budget > 0, let ts = scan.threads.first, roomForCall(now) {
            guard let json = call("conversations.replies", ["channel": room, "ts": ts, "limit": "200"], room: room) else {
                // A thread that is gone has nothing to hand over; the scan goes on to the next.
                if lastCode == "thread_not_found" { scan.threads.removeFirst(); budget -= 1; continue }
                return roomAlone
            }
            receiveThreadRead(json, room: room, ts: ts)
            let found = (json["messages"] as? [[String: Any]] ?? []).compactMap(SlackMessage.init(json:)).filter { $0.time > scan.since }
            scanned[room, default: []] += found.map { state.chat($0, room: room, characters: characters) }
            scan.threads.removeFirst(); budget -= 1
        }
        if !scan.paged, now.timeIntervalSince(scanPageAt) >= Self.scanInterval, roomForHistory(now, shown: false) {
            var parameters = ["channel": room, "limit": "200"]
            if !scan.cursor.isEmpty { parameters["cursor"] = scan.cursor }
            guard let json = call("conversations.history", parameters, room: room) else { return roomAlone }
            scanPageAt = now; scan.pages += 1
            for raw in json["messages"] as? [[String: Any]] ?? [] {
                guard let ts = raw["ts"] as? String else { continue }
                // A first message that is only housekeeping is not kept, but what was said under it is.
                if let message = SlackMessage(json: raw), message.isRoot, message.time > scan.since {
                    scanned[room, default: []].append(state.chat(message, room: room, characters: characters))
                }
                let replies = raw["reply_count"] as? Int ?? 0, newest = Double(raw["latest_reply"] as? String ?? "") ?? 0
                if replies > 0, newest > scan.since, (raw["thread_ts"] as? String ?? ts) == ts { scan.threads.append(ts) }
            }
            scan.cursor = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            scan.paged = scan.cursor.isEmpty || json["has_more"] as? Bool != true || scan.pages >= Self.scanPages
        }
        if scan.paged, scan.threads.isEmpty {
            scannedThrough[room] = scan.started; scanFinished[room] = scan.since; scans[room] = nil
        }
        return true
    }

    private func loadRooms(now: Date) -> Bool {
        var listed: [[String: Any]] = [], cursor = "", pages = 0
        repeat {
            // Archived channels come too, to be offered back; they are set apart below and never read.
            var parameters = ["types": "public_channel,private_channel,im", "exclude_archived": "false", "limit": "200"]
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            guard let json = call("users.conversations", parameters) else { return false }
            listed += json["channels"] as? [[String: Any]] ?? []
            cursor = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            pages += 1
        } while !cursor.isEmpty && pages < Self.roomPages
        roomsAt = now
        var rooms: [SlackRoom] = [], archived: [SlackRoom] = []
        var checkedUsers = Set<String>()
        for channel in listed {
            guard let id = channel["id"] as? String else { continue }
            if channel["is_archived"] as? Bool == true {
                if channel["is_im"] as? Bool != true { archived.append(SlackRoom(id: id, name: channel["name"] as? String ?? id)) }
                continue
            }
            if channel["is_im"] as? Bool == true {
                let user = channel["user"] as? String ?? ""
                if user.isEmpty || user == "USLACKBOT" || user == state.me { continue }
                imUsers[id] = user
                // A cached name says nothing about whether the app or account still exists.
                // Recheck DM partners whenever rooms are listed (at start and every five minutes).
                if checkedUsers.insert(user).inserted, !resolve(user) { roomsAt = .distantPast; rebuildMembers(); return false }
                if deletedUsers.contains(user) { continue }
                rooms.append(SlackRoom(id: id, name: state.users[user] ?? "개인 대화", direct: true))
            } else {
                rooms.append(SlackRoom(id: id, name: channel["name"] as? String ?? id))
            }
        }
        snapshot.rooms = rooms.filter { !$0.direct }.sorted { $0.name < $1.name } + rooms.filter(\.direct).sorted { $0.name < $1.name }
        cacheChanged = true
        snapshot.archived = archived.sorted { $0.name < $1.name }
        let listedIDs = Set(rooms.map(\.id))
        snapshot.problems = snapshot.problems.filter { listedIDs.contains($0.key) }
        for room in snapshot.rooms {
            if room.direct { memberIDs[room.id] = imUsers[room.id].map { [$0] } ?? [] }
            else {
                calls.append("conversations.members")
                // A room whose members cannot be listed still shows its conversation.
                switch api.call("conversations.members", ["channel": room.id, "limit": "200"]) {
                case .success(let json):
                    memberIDs[room.id] = (json["members"] as? [String] ?? []).filter { $0 != state.me && $0 != "USLACKBOT" }
                case .failure(.rateLimited(let seconds)):
                    pausedUntil = now.addingTimeInterval(max(1, seconds)); roomsAt = .distantPast
                    refused("conversations.members", wait: seconds); return false
                case .failure: break
                }
            }
            for user in memberIDs[room.id] ?? [] where state.users[user] == nil { guard resolve(user) else { return false } }
        }
        rebuildMembers()
        return true
    }

    private func rebuildMembers() {
        let gone = Set(imUsers.compactMap { deletedUsers.contains($0.value) ? $0.key : nil })
        snapshot.rooms.removeAll { gone.contains($0.id) }
        for room in gone { snapshot.threads[room] = nil; snapshot.problems[room] = nil }
        dirty.subtract(gone)
        snapshot.me = state.me
        snapshot.users = state.users
        snapshot.members = memberIDs.mapValues { ids in
            SlackMember.ordered(ids.compactMap { id in
                guard !deletedUsers.contains(id), let name = state.users[id], name != Self.unknownName else { return nil }
                let profile = DdotsConfig.shared.matching(name, user: id) ?? SlackSpeakers.profile(name, characters: characters)
                return SlackMember(profile: profile, name: characters.first { $0.id == profile }?.name ?? name, user: id)
            })
        }
        // A direct conversation with a character is listed under the character's name too.
        for index in snapshot.rooms.indices where snapshot.rooms[index].direct {
            guard let user = imUsers[snapshot.rooms[index].id], let name = state.users[user] else { continue }
            let profile = SlackSpeakers.profile(name, characters: characters)
            snapshot.rooms[index].name = characters.first { $0.id == profile }?.name ?? name
        }
    }

    private func receiveDeletion(_ user: String, deleted: Bool) {
        let changed = deleted ? deletedUsers.insert(user).inserted : deletedUsers.remove(user) != nil
        if changed { cacheChanged = true }
    }

    /// A name that cannot be read must not stop the conversation itself from loading.
    private func resolve(_ user: String) -> Bool {
        calls.append("users.info")
        switch api.call("users.info", ["user": user]) {
        case .failure(.rateLimited(let seconds)):
            pausedUntil = clock.addingTimeInterval(max(1, seconds)); refused("users.info", wait: seconds); return false
        case .failure(let failure):
            if state.users[user] == nil { state.users[user] = Self.unknownName }
            if case .api(let code) = failure, ["user_not_found", "users_not_found"].contains(code) { receiveDeletion(user, deleted: true) }
            // Slack saying there is no such person is final. Anything else may pass, so the name is asked for again later.
            if case .api(let code) = failure, ["user_not_found", "user_not_visible", "users_not_found"].contains(code) { nameRetry[user] = nil }
            else {
                let tries = (nameRetry[user]?.tries ?? 0) + 1
                nameRetry[user] = (tries, clock.addingTimeInterval(min(Self.longestNameWait, Self.nameWait * pow(2, Double(tries - 1)))))
            }
        case .success(let json):
            let info = json["user"] as? [String: Any] ?? [:]
            if let deleted = info["deleted"] as? Bool { receiveDeletion(user, deleted: deleted) }
            let profile = info["profile"] as? [String: Any] ?? [:]
            let candidates = [profile["display_name"], info["real_name"], profile["real_name"], info["name"]].compactMap { $0 as? String }
            state.users[user] = candidates.first { !$0.isEmpty } ?? user
            nameRetry[user] = nil
        }
        return true
    }

    // MARK: Rooms made, filled and put away from the window. Each is one call or two, asked for by the user.

    /// Someone in the workspace who can be asked into a room: a person, or an app such as a Hermes character.
    struct Person: Identifiable, Equatable {
        var id: String
        var name: String
        /// The character this is, or empty for anyone else.
        var profile = ""
        var bot = false
        var handle = ""
        var agent: Bool { bot || !profile.isEmpty }
    }
    static let peoplePages = 5

    /// Everyone in the workspace but the user and Slack's own bot: characters first, then other apps, then people.
    func people() -> Result<[Person], SlackAPI.Failure> {
        defer { rebuildMembers() }
        var found: [Person] = [], cursor = "", pages = 0
        repeat {
            var parameters = ["limit": "200"]
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            calls.append("users.list")
            switch api.call("users.list", parameters) {
            case .failure(let failure): return .failure(failure)
            case .success(let json):
                for user in json["members"] as? [[String: Any]] ?? [] {
                    guard let id = user["id"] as? String, id != state.me, id != "USLACKBOT" else { continue }
                    if let deleted = user["deleted"] as? Bool { receiveDeletion(id, deleted: deleted) }
                    if deletedUsers.contains(id) { continue }
                    let profile = user["profile"] as? [String: Any] ?? [:]
                    let name = [profile["display_name"], user["real_name"], profile["real_name"], user["name"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? id
                    let character = SlackSpeakers.profile(name, characters: characters)
                    found.append(Person(id: id, name: characters.first { $0.id == character }?.name ?? name, profile: character, bot: user["is_bot"] as? Bool == true, handle: user["name"] as? String ?? ""))
                }
                cursor = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            }
            pages += 1
        } while !cursor.isEmpty && pages < Self.peoplePages
        let order = ChatCharacter.preferred
        func rank(_ person: Person) -> Int {
            if !person.profile.isEmpty { return order.firstIndex(of: person.profile) ?? order.count }
            return person.bot ? order.count + 1 : order.count + 2
        }
        return .success(found.sorted { (rank($0), $0.name) < (rank($1), $1.name) })
    }

    /// What Slack takes as a channel name: lower case, no spaces, at most 80 characters of letters, numbers, `-` and `_`.
    static func channelName(_ typed: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix("#") { name.removeFirst() }
        let words = name.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: "-")
        let kept = words.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return String(String(String.UnicodeScalarView(kept)).prefix(80))
    }

    /// What a refusal to make, fill or put away a room means, in the user's words.
    static func roomMessage(_ failure: SlackAPI.Failure) -> String {
        guard case .api(let code) = failure else { return SlackAPI.message(failure) }
        switch code {
        case "name_taken": return "같은 이름의 방이 이미 있어요. 보관된 방일 수도 있어요."
        case "invalid_name_required": return "방 이름을 넣어 주세요."
        case "invalid_name_maxlength": return "방 이름은 80자까지 쓸 수 있어요."
        case "invalid_name", "invalid_name_specials", "invalid_name_punctuation": return "방 이름에는 글자, 숫자, -, _만 쓸 수 있어요."
        case "restricted_action", "user_is_restricted", "not_authorized": return "워크스페이스 설정상 이 작업은 관리자만 할 수 있어요."
        case "cant_archive_general", "cant_archive_required": return "워크스페이스 기본 방은 보관할 수 없어요."
        case "cant_invite": return "초대할 수 없는 사람이 있어요."
        default: return SlackAPI.message(failure)
        }
    }

    /// Makes a channel and asks people into it. A room made whose inviting failed is still given back, with what went wrong.
    func createRoom(name: String, isPrivate: Bool, inviting users: [String]) -> (room: SlackRoom?, problem: String?) {
        calls.append("conversations.create")
        switch api.call("conversations.create", ["name": name, "is_private": isPrivate ? "true" : "false"]) {
        case .failure(let failure): return (nil, Self.roomMessage(failure))
        case .success(let json):
            guard let channel = json["channel"] as? [String: Any], let id = channel["id"] as? String else { return (nil, "슬랙이 새 방을 알려 주지 않았어요.") }
            let room = SlackRoom(id: id, name: channel["name"] as? String ?? name)
            if !snapshot.rooms.contains(where: { $0.id == id }) {
                let channels = (snapshot.rooms.filter { !$0.direct } + [room]).sorted { $0.name < $1.name }
                snapshot.rooms = channels + snapshot.rooms.filter(\.direct)
            }
            memberIDs[id] = memberIDs[id] ?? []
            rebuildMembers()
            roomsAt = .distantPast
            return (room, invite(room: id, users: users).map { "방은 만들었지만 초대하지 못했어요. " + $0 })
        }
    }

    /// Asks people into a channel. Nil when they are in it, else why not.
    func invite(room: String, users: [String]) -> String? {
        let users = users.filter { !$0.isEmpty && $0 != state.me }
        guard !users.isEmpty else { return nil }
        calls.append("conversations.invite")
        // With `force` the ones who can be asked in are, even when another of them cannot.
        switch api.call("conversations.invite", ["channel": room, "users": users.joined(separator: ","), "force": "true"]) {
        case .failure(.api("already_in_channel")): break
        case .failure(let failure): return Self.roomMessage(failure)
        case .success: break
        }
        memberIDs[room] = (memberIDs[room] ?? []) + users.filter { !(memberIDs[room] ?? []).contains($0) }
        for user in users where state.users[user] == nil { _ = resolve(user) }
        rebuildMembers()
        return nil
    }

    /// Puts a channel away in Slack. It leaves the list and waits among the archived rooms to be brought back.
    func archive(room: String) -> String? {
        calls.append("conversations.archive")
        switch api.call("conversations.archive", ["channel": room]) {
        case .failure(.api("already_archived")): break
        case .failure(let failure): return Self.roomMessage(failure)
        case .success: break
        }
        if let index = snapshot.rooms.firstIndex(where: { $0.id == room }) {
            let gone = snapshot.rooms.remove(at: index)
            if !gone.direct { snapshot.archived = (snapshot.archived.filter { $0.id != room } + [gone]).sorted { $0.name < $1.name } }
        }
        roomsAt = .distantPast
        return nil
    }

    /// Gives a channel a new name in Slack. The name is one Slack takes; see `channelName`.
    func rename(room: String, to name: String) -> String? {
        calls.append("conversations.rename")
        switch api.call("conversations.rename", ["channel": room, "name": name]) {
        case .failure(let failure): return Self.roomMessage(failure)
        case .success(let json):
            let given = (json["channel"] as? [String: Any])?["name"] as? String ?? name
            if let index = snapshot.rooms.firstIndex(where: { $0.id == room }) {
                snapshot.rooms[index].name = given
                snapshot.rooms = snapshot.rooms.filter { !$0.direct }.sorted { $0.name < $1.name } + snapshot.rooms.filter(\.direct)
            }
            return nil
        }
    }

    /// Brings an archived channel back into Slack and the list.
    func unarchive(room: String) -> String? {
        calls.append("conversations.unarchive")
        switch api.call("conversations.unarchive", ["channel": room]) {
        case .failure(.api("not_archived")): break
        case .failure(let failure): return Self.roomMessage(failure)
        case .success: break
        }
        if let index = snapshot.archived.firstIndex(where: { $0.id == room }) {
            let back = snapshot.archived.remove(at: index)
            if !snapshot.rooms.contains(where: { $0.id == room }) {
                snapshot.rooms = (snapshot.rooms.filter { !$0.direct } + [back]).sorted { $0.name < $1.name } + snapshot.rooms.filter(\.direct)
            }
        }
        roomsAt = .distantPast
        return nil
    }

    private func loadHistory(_ room: String, limit: Int, now: Date, shown: Bool) -> Bool {
        watchedPass?[room] = nil
        guard let json = call("conversations.history", ["channel": room, "limit": String(min(200, max(1, limit)))], room: room, urgentReason: shown ? "shown" : "") else { return roomAlone }
        fetchedAt[room] = now; loadedLimit[room] = limit; readAt[room] = now.timeIntervalSince1970
        resting[room] = nil; snapshot.problems[room] = nil
        let raw = json["messages"] as? [[String: Any]] ?? []
        historyStructure[room] = raw.map(Self.structure)
        let messages = raw.compactMap(SlackMessage.init(json:))
        let roots = Set(messages.filter(\.isRoot).map(\.ts))
        for message in messages where !message.isRoot {
            guard let ts = message.threadTS else { continue }
            // A reply shown in the channel comes with the listing, so a repaint of it (its status changing) needs no reading of the thread.
            if let index = state.replies[room]?[ts]?.firstIndex(where: { $0.ts == message.ts }), state.replies[room]?[ts]?[index] != message {
                state.replies[room]?[ts]?[index] = message; dirty.insert(room)
            }
            let key = room + ":" + ts
            if !roots.contains(ts), candidateSeen[key] == nil { candidateSeen[key] = observedAt }
            state.channelTimes[room, default: [:]][ts] = max(state.channelTimes[room]?[ts] ?? 0, message.time)
        }
        // What Slack stamps on the user's own posts, without their words: whether a post reads as typed by a person
        // or as sent by an app decides whether Hermes answers it.
        selfPosts[room] = (json["messages"] as? [[String: Any]] ?? []).filter { $0["user"] as? String == state.me }.prefix(8).map { post in
            let marks = ["client_msg_id", "bot_id", "app_id", "bot_profile", "subtype"].filter { post[$0] != nil }
            return "\(post["ts"] as? String ?? "?") " + (marks.isEmpty ? "no marks" : marks.joined(separator: " "))
        }
        for message in messages where message.isRoot && first[room + ":" + message.ts] == nil { first[room + ":" + message.ts] = message.latestReply ?? "" }
        if state.history[room] != messages { state.history[room] = messages; dirty.insert(room); letGoReplies(room) }
        if snapshot.threads[room] == nil { dirty.insert(room) }
        snapshot.more[room] = json["has_more"] as? Bool ?? false
        return true
    }

    /// Replies of threads that have left the room's listing are let go, as the cache leaves them out, with their stamp,
    /// so a thread that comes back into the listing is read again.
    private func letGoReplies(_ room: String) {
        let roots = Set((state.history[room] ?? []).filter(\.isRoot).map(\.ts)).union((state.extra[room] ?? [:]).keys)
        for ts in (state.replies[room] ?? [:]).keys where !roots.contains(ts) { state.replies[room]?[ts] = nil; fetched[room + ":" + ts] = nil }
    }

    /// Each class has its own allowance, within the shared total. Live work can borrow when nothing on screen waits.
    private func roomForCall(_ now: Date, urgent: Bool = false, waiting: Bool = false) -> Bool {
        recentCalls.removeAll { now.timeIntervalSince($0.at) >= 60 }
        let reads = recentCalls.filter { $0.method == "conversations.replies" }
        let method = "conversations.replies"
        let starved = now.timeIntervalSince(reads.filter { !$0.urgent }.map(\.at).max() ?? .distantPast) >= Self.starveWindow
        guard gateOpen(method, observedAt, need: urgent || starved ? 1 : 2), reads.count < allowed(Self.callsPerMinute, method) else { return false }
        if urgent && !waiting { return true }
        return reads.filter { $0.urgent == urgent }.count < allowed(Self.callsPerMinute - Self.reservedCalls, method)
    }

    /// The same for the listing of a room: `shown` for a room on screen or one a character is answering in.
    private func roomForHistory(_ now: Date, shown: Bool) -> Bool {
        let reads = recentCalls.filter { $0.method == "conversations.history" && now.timeIntervalSince($0.at) < 60 }
        let method = "conversations.history"
        let starved = now.timeIntervalSince(reads.filter { !$0.urgent }.map(\.at).max() ?? .distantPast) >= Self.starveWindow
        guard gateOpen(method, observedAt, need: shown || starved ? 1 : 2), reads.count < allowed(Self.historyPerMinute, method) else { return false }
        return shown || reads.filter { !$0.urgent }.count < allowed(Self.backgroundHistory, method)
    }

    /// Threads a character is answering in, or that had a line in the last two minutes.
    func liveThreads(_ room: String, now: Date) -> [String] {
        watchedThreads(room, now: now).filter { $0.reason != "linger" }.map(\.ts)
    }

    /// The threads read again without waiting for the room's listing to change, newest first, each with how often.
    /// A live one is read at every turn. One whose "생각 중" line has stood too long is read only now and then:
    /// an answer that never came must not use up the reading of every other thread.
    func watchedThreads(_ room: String, now: Date) -> [(ts: String, every: TimeInterval, reason: String)] {
        if let cached = watchedPass?[room] { return cached }
        let at = now.timeIntervalSince1970
        let roots = (state.history[room] ?? []).filter(\.isRoot) + Array((state.extra[room] ?? [:]).values)
        let result = roots.compactMap { root -> (root: SlackMessage, every: TimeInterval, reason: String)? in
            let answers = state.replies[room]?[root.ts] ?? []
            let thinking = ([root] + answers).filter { $0.user != state.me && thinkingMemo.value(ts: room + ":" + $0.ts, text: $0.text) }.map(\.time).max()
            let newest = max(root.time, answers.map(\.time).max() ?? 0, Double(root.latestReply ?? "") ?? 0)
            // What the user has just written is watched too, so the answer shows as soon as it is there.
            let waiting = root.replyCount > 0 || (!state.me.isEmpty && root.user == state.me)
            if let thinking, at - thinking < Self.thinkingWindow { return (root, Self.liveInterval, "thinking") }
            if waiting, at - newest < Self.liveWindow, at >= newest {
                let moved = max(newest, changedAt[room + ":" + root.ts]?.timeIntervalSince1970 ?? 0)
                return (root, at - moved < Self.settleWindow ? Self.liveInterval : Self.calmInterval, "live")
            }
            if let state = ([root] + answers).last(where: { $0.hermesReplyState != nil })?.hermesReplyState,
               state != .closed {
                return (root, Self.lingerInterval, "hermes")
            }
            guard let thinking else { return nil }
            return (root, at - thinking < 86_400 ? Self.lingerInterval : Self.longLingerInterval, "linger")
        }.sorted { $0.root.time > $1.root.time }.map { ($0.root.ts, $0.every, $0.reason) }
        if watchedPass != nil { watchedPass?[room] = result }
        return result
    }

    /// Threads to read now: opened ones, the newest few, and any whose replies changed since they were first seen.
    func staleThreads(_ room: String, wanted: Set<String>, eager count: Int = SlackBridge.eagerThreads) -> [String] {
        let roots = (state.history[room] ?? []).filter(\.isRoot).sorted { $0.time > $1.time }
        let eager = Set(roots.prefix(count).map(\.ts))
        return roots.filter { root in
            guard root.replyCount > 0 else { return false }
            let key = room + ":" + root.ts, stamp = root.latestReply ?? ""
            if let last = fetched[key] { return last != stamp }
            return wanted.contains(key) || eager.contains(root.ts) || first[key] != stamp
        }.map(\.ts)
    }

    private func loadReplies(_ room: String, _ ts: String, urgentReason: String = "") -> Bool {
        guard let json = call("conversations.replies", ["channel": room, "ts": ts, "limit": "200"], room: room, urgentReason: urgentReason) else {
            // Held back: the thread keeps what it had and is read when its turn comes again.
            if deferred { return true }
            if state.extra[room]?[ts] != nil { extraRead[room, default: [:]][ts] = lastCode == "thread_not_found" ? "thread_not_found" : "failed" }
            // A thread that is gone counts as read, so it is not asked for on every pass.
            if lastCode == "thread_not_found" { fetched[room + ":" + ts] = state.history[room]?.first { $0.ts == ts }?.latestReply ?? "" }
            return roomAlone
        }
        receiveThreadRead(json, room: room, ts: ts)
        let received = (json["messages"] as? [[String: Any]] ?? []).compactMap(SlackMessage.init(json:))
        if let root = received.first(where: { $0.ts == ts }) {
            func refreshed(_ old: SlackMessage) -> SlackMessage {
                guard root.hermesReplyState != nil || old.hermesReplyState != nil else { return old }
                var result = root
                // Thread scheduling metadata belongs to history; a replies response may omit it.
                result.replyCount = old.replyCount
                result.latestReply = old.latestReply
                return result
            }
            if let index = state.history[room]?.firstIndex(where: { $0.ts == ts }), let old = state.history[room]?[index] {
                state.history[room]?[index] = refreshed(old)
            }
            if let old = state.extra[room]?[ts] { state.extra[room]?[ts] = refreshed(old) }
        }
        let messages = received.filter { $0.ts != ts }
        if state.replies[room]?[ts] != messages { changedAt[room + ":" + ts] = clock }
        state.replies[room, default: [:]][ts] = messages
        if state.extra[room]?[ts] != nil { extraRead[room, default: [:]][ts] = "read" }
        fetched[room + ":" + ts] = state.history[room]?.first { $0.ts == ts }?.latestReply ?? ""
        dirty.insert(room)
        return true
    }

    private func loadExtra(_ room: String, _ ts: String) -> Bool {
        guard let json = call("conversations.replies", ["channel": room, "ts": ts, "limit": "200"], room: room) else {
            if deferred { extraRead[room, default: [:]][ts] = "waiting"; return true }
            extraRead[room, default: [:]][ts] = lastCode == "thread_not_found" ? "thread_not_found" : "failed"
            return roomAlone
        }
        extraRead[room, default: [:]][ts] = "read"
        receiveThreadRead(json, room: room, ts: ts)
        let messages = (json["messages"] as? [[String: Any]] ?? []).compactMap(SlackMessage.init(json:))
        guard var root = messages.first(where: { $0.ts == ts }) else { extraRead[room, default: [:]][ts] = "failed"; return true }
        let answers = messages.filter { $0.ts != ts }
        root.replyCount = max(root.replyCount, answers.count); root.latestReply = answers.last?.ts ?? root.latestReply
        state.extra[room, default: [:]][ts] = root
        state.replies[room, default: [:]][ts] = answers
        dirty.insert(room)
        return true
    }

    // One short, memory-only observation per explicit page click. No periodic work.
    struct PageRequest {
        let room: String; let thread: String; let bot: String; let command: String
        let ts: String; let started: Date; var reads = 0
    }
    private(set) var pageRequest: PageRequest?
    private var lastPostedMessage: SlackMessage?
    /// The last few page clicks, structure only (no text), for the diagnostics file.
    private(set) var pageLog: [String] = []
    private func logPage(_ line: String) {
        pageLog.append(String(format: "%.0f ", clock.timeIntervalSince1970) + line)
        PageTrace.log("bridge " + line)
        if pageLog.count > 12 { pageLog.removeFirst(pageLog.count - 12) }
    }
    /// What kind of line a bot reply starts with, never its words.
    private static func pageShape(_ text: String) -> String {
        let first = text.components(separatedBy: "\n").first ?? ""
        if first.range(of: #"\A쪽 [0-9]+/[0-9]+ · 총 [0-9]+건 — "#, options: .regularExpression) != nil { return text.contains("\n") ? "controls-multiline" : "controls" }
        if first.range(of: #"\A쪽 [0-9]+/[0-9]+"#, options: .regularExpression) != nil { return "controls-other" }
        if first.range(of: #"\A전체 목록 [0-9]+/[0-9]+ · 총 [0-9]+건\z"#, options: .regularExpression) != nil { return "all-header" }
        if first.hasPrefix("전체 목록") { return "all-other" }
        if first.range(of: #"\A[0-9]+/[0-9]+쪽 · 총 [0-9]+건"#, options: .regularExpression) != nil { return "page-body" }
        return "other(\(text.count))"
    }
    func beginPage(room: String, thread: String, bot: String, command: String, now: Date = Date()) -> Bool {
        clock = now; syncStarted = uptime()
        let kind = command == "전체 보기" ? "all" : "page"
        guard pageRequest == nil, now >= pausedUntil, !state.me.isEmpty, !bot.isEmpty,
              (command == "전체 보기" || command.range(of: #"\A쪽: [0-9]+\z"#, options: .regularExpression) != nil) else {
            logPage("\(kind) refused busy=\(pageRequest != nil) paused=\(now < pausedUntil) me=\(!state.me.isEmpty) bot=\(!bot.isEmpty)")
            return false
        }
        lastPostedMessage = nil
        if let failure = post(room: room, thread: thread, text: command) { logPage("\(kind) post_failed \(failure.prefix(60))"); return false }
        guard let message = lastPostedMessage, message.user == state.me, message.text == command,
              message.threadTS == thread, let stamp = Double(message.ts),
              abs(now.timeIntervalSince1970 - stamp) < 60 else {
            let m = lastPostedMessage
            logPage("\(kind) receipt_mismatch has=\(m != nil) me=\(m?.user == state.me) text=\(m?.text == command) thread=\(m?.threadTS == thread) age=\(m.flatMap { Double($0.ts) }.map { Int(now.timeIntervalSince1970 - $0) } ?? -1)")
            return false
        }
        pageRequest = PageRequest(room: room, thread: thread, bot: bot, command: command, ts: message.ts, started: now)
        logPage("\(kind) sent")
        return true
    }
    /// Returns true when updated, timed out, or paused. At most one replies call per step.
    func observePage(now: Date = Date()) -> Bool {
        guard var request = pageRequest else { return true }
        clock = now; syncStarted = uptime()
        guard now >= pausedUntil, now.timeIntervalSince(request.started) < 15,
              request.reads < 4, roomForCall(now, urgent: true) else {
            logPage("read stopped paused=\(now < pausedUntil) reads=\(request.reads) age=\(Int(now.timeIntervalSince(request.started)))")
            pageRequest = nil; return true
        }
        request.reads += 1; pageRequest = request
        guard let json = call("conversations.replies", ["channel": request.room, "ts": request.thread, "limit": "200"], room: request.room, urgentReason: "page") else {
            logPage("read \(request.reads) failed"); pageRequest = nil; return true
        }
        let raw = json["messages"] as? [[String: Any]] ?? []
        let messages = raw.compactMap(SlackMessage.init(json:))
        for root in messages where root.ts == request.thread {
            if let index = state.history[request.room]?.firstIndex(where: { $0.ts == root.ts }) { state.history[request.room]?[index] = root }
            if state.extra[request.room]?[root.ts] != nil { state.extra[request.room]?[root.ts] = root }
        }
        state.replies[request.room, default: [:]][request.thread] = messages.filter { $0.ts != request.thread }
        repliesAt[request.room + ":" + request.thread] = now
        snapshot.threads[request.room] = state.threads(room: request.room, characters: characters)
        let number = String(request.command.dropFirst(3))
        let updated = messages.contains {
            guard $0.user == request.bot else { return false }
            if request.command == "전체 보기" {
                return (Double($0.ts) ?? 0) > (Double(request.ts) ?? 0)
                    && $0.text.range(of: #"\A전체 목록 [0-9]+/[0-9]+ · 총 [0-9]+건(?:\n|\z)"#, options: .regularExpression) != nil
            }
            return $0.text.hasPrefix("쪽 " + number + "/")
        }
        let after = messages.filter { (Double($0.ts) ?? 0) > (Double(request.ts) ?? 0) }
        let edited = raw.filter { ($0["user"] as? String) == request.bot && (($0["edited"] as? [String: Any])?["ts"] as? String).flatMap(Double.init) ?? 0 > (Double(request.ts) ?? 0) }.count
        logPage("read \(request.reads) replies=\(messages.count) after=\(after.count) bot_after=[\(after.filter { $0.user == request.bot }.map { Self.pageShape($0.text) }.joined(separator: ","))] other_after=\(after.filter { $0.user != request.bot && $0.user != state.me }.count) bot_edited=\(edited) updated=\(updated)")
        guard updated || request.reads == 4 else { return false }
        pageRequest = nil
        // Only the fresh source returned for our own successful send may be deleted.
        let statusBeforeDelete = snapshot.status, problemsBeforeDelete = snapshot.problems
        defer { snapshot.status = statusBeforeDelete; snapshot.problems = problemsBeforeDelete }
        if let source = raw.first(where: { $0["ts"] as? String == request.ts }),
           source["user"] as? String == state.me, source["text"] as? String == request.command,
           source["thread_ts"] as? String == request.thread,
           (source["channel"] as? String ?? request.room) == request.room,
           now.timeIntervalSince(request.started) < 15,
           call("chat.delete", ["channel": request.room, "ts": request.ts], room: request.room) != nil {
            state.replies[request.room]?[request.thread]?.removeAll { $0.ts == request.ts }
            if let index = state.history[request.room]?.firstIndex(where: { $0.ts == request.thread }) {
                let count = state.history[request.room]?[index].replyCount ?? 0
                state.history[request.room]?[index].replyCount = max(0, count - 1)
            }
            if let root = state.extra[request.room]?[request.thread] {
                state.extra[request.room]?[request.thread]?.replyCount = max(0, root.replyCount - 1)
            }
            snapshot.threads[request.room] = state.threads(room: request.room, characters: characters)
        }
        return true
    }

    /// Receipts are read on the same serial queue as sending, before the next send can replace them.
    private(set) var postedRootTS: String?
    private(set) var uploadedFileIDs = Set<String>()
    /// Returns a message for the user when the post failed.
    func post(room: String, thread: String?, text: String) -> String? {
        postedRootTS = nil
        var parameters = ["channel": room, "text": text]
        if let thread { parameters["thread_ts"] = thread }
        switch api.call("chat.postMessage", parameters) {
        case .failure(let failure):
            if case .rateLimited(let seconds) = failure { pausedUntil = clock.addingTimeInterval(max(1, seconds)); refused("chat.postMessage", wait: seconds) }
            return SlackAPI.message(failure)
        case .success(let json):
            if thread == nil { postedRootTS = json["ts"] as? String }
            guard let message = (json["message"] as? [String: Any]).flatMap(SlackMessage.init(json:)) else { return nil }
            lastPostedMessage = message
            if let thread {
                if state.replies[room]?[thread] != nil { state.replies[room]?[thread]?.append(message); fetched[room + ":" + thread] = message.ts }
                if let index = state.history[room]?.firstIndex(where: { $0.ts == thread }) {
                    state.history[room]?[index].replyCount += 1; state.history[room]?[index].latestReply = message.ts
                } else if state.extra[room]?[thread] != nil {
                    state.extra[room]?[thread]?.replyCount += 1; state.extra[room]?[thread]?.latestReply = message.ts
                }
            } else {
                postedRootTS = message.ts
                state.history[room, default: []].append(message); first[room + ":" + message.ts] = ""
            }
            snapshot.threads[room] = state.threads(room: room, characters: characters)
            return nil
        }
    }
    /// Sends files, with the text as their caption, in Slack's three steps: ask where, send the bytes, attach to the conversation.
    func upload(room: String, thread: String?, text: String, files: [(name: String, data: Data)]) -> String? {
        upload(room: room, thread: thread, text: text, files: files.map { file in SlackOutgoingFile(name: file.name, size: file.data.count, load: { file.data }) })
    }
    /// Each file is read only when its turn comes and is let go once its bytes are sent, so one file is in memory at a time.
    /// What is read is checked again: a file that grew past the limit or changed since it was checked is not sent.
    func upload(room: String, thread: String?, text: String, files: [SlackOutgoingFile]) -> String? {
        uploadedFileIDs = []
        var sent: [[String: String]] = []
        for file in files {
            let failure: String? = autoreleasepool {
                let data: Data
                do { data = try file.load() } catch { return SlackOutgoingProblem.unreadable(file.name).message }
                if data.count > SlackFileStore.largest { return SlackOutgoingProblem.tooLarge(file.name).message }
                if data.count != file.size { return SlackOutgoingProblem.changed(file.name).message }
                let place: [String: Any]
                switch api.call("files.getUploadURLExternal", ["filename": file.name, "length": String(data.count)]) {
                case .failure(let failure): return SlackAPI.message(failure)
                case .success(let json): place = json
                }
                guard let address = (place["upload_url"] as? String).flatMap(URL.init(string:)), let id = place["file_id"] as? String else { return "슬랙이 파일 올릴 곳을 알려 주지 않았어요." }
                if case .failure(let failure) = api.raw(address, data) { return SlackAPI.message(failure) }
                sent.append(["id": id, "title": file.name])
                return nil
            }
            if let failure { return failure }
        }
        guard let list = try? JSONSerialization.data(withJSONObject: sent), let encoded = String(data: list, encoding: .utf8) else { return "파일 목록을 만들지 못했어요." }
        var parameters = ["files": encoded, "channel_id": room]
        if !text.isEmpty { parameters["initial_comment"] = text }
        if let thread { parameters["thread_ts"] = thread }
        if case .failure(let failure) = api.call("files.completeUploadExternal", parameters) { return SlackAPI.message(failure) }
        uploadedFileIDs = Set(sent.compactMap { $0["id"] })
        // The new message has no stamp in the answer, so the room and the thread are read again right away.
        fetchedAt[room] = .distantPast
        if let thread, fetched[room + ":" + thread] != nil { fetched[room + ":" + thread] = "sent" }
        return nil
    }
    var current: Snapshot { snapshot }
}
