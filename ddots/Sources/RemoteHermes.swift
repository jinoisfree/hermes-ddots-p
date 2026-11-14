import Foundation
import Network

/// The Hermes conversation of another Mac, pushed over the relay. Conversations stay in memory; only character names and pictures may be kept locally.
final class RemoteHermes: HermesSource {
    static let connecting = "공유하는 Mac에 연결하는 중이에요."
    static let lost = "공유하는 Mac에 연결하지 못했어요. 다시 연결하는 중이에요."
    static let denied = "연결 코드가 맞지 않아요. Hermes 연결에서 다시 입력해 주세요."
    private let includeMessages: Bool
    private final class Pending { let done = DispatchSemaphore(value: 0); var reply: RelayFrame? }
    private let host: String, port: UInt16, token: String
    private let portraits: RelayPortraits?
    private let queue = DispatchQueue(label: AppIdentity.bundleID + ".remote", qos: .utility)
    private let lock = NSLock()
    private var latest = HermesBridge.PollResult(status: .unavailable(RemoteHermes.connecting), messages: [])
    private var lastStateAt: Date?
    /// True while the sharing Mac has accepted this one and is still heard from.
    var linked: Bool { lock.lock(); defer { lock.unlock() }; return isLinked }
    private var isLinked = false
    private var dropVersion = 0
    private var dropEngine = 0
    private var dropFailureAt: Date?
    private var dropDenied = false
    private var checkVersion = 0
    var dropOriginalsAllowed: ((NWConnection) -> Bool)?
    var supportsDrop: Bool { lock.lock(); defer { lock.unlock() }; return isLinked && dropVersion == 1 }
    var supportsDropEngine: Bool { lock.lock(); defer { lock.unlock() }; return isLinked && dropEngine == 1 }
    var dropFailure: String {
        lock.lock(); defer { lock.unlock() }
        if dropDenied { return "연결 코드를 다시 입력해 주세요" }
        if isLinked { return "맥미니 앱을 업데이트해 주세요" }
        if let at = dropFailureAt {
            let format = DateFormatter(); format.dateFormat = "HH:mm"
            return "맥미니 연결 확인 · " + format.string(from: at)
        }
        return "맥미니에 연결하는 중이에요"
    }
    var lastReceivedAt: Date? { lock.lock(); defer { lock.unlock() }; return lastStateAt }
    private var relayedUsage: RelayUsage?
    /// Paseo usage of the sharing Mac. Kept across a lost link; each value expires by its own observation time.
    var usage: RelayUsage? { lock.lock(); defer { lock.unlock() }; return relayedUsage }
    private var relayedStreams: [StreamPreview] = []
    var streamPreviews: [StreamPreview] { lock.lock(); defer { lock.unlock() }; return relayedStreams }
    private var relayedSlack = SlackActivity()
    /// Slack threads the sharing Mac's characters are writing in. Cleared when the link is lost so no dots linger.
    var slackActivity: SlackActivity { lock.lock(); defer { lock.unlock() }; return relayedSlack }
    private var unread: Date?
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    // Queue-confined state.
    private var connection: NWConnection?
    private var buffer = Data()
    private var startupTapFailure: ThreeTapFailure?
    private var welcomed = false
    private var attempts = 0
    private var wasDenied = false
    private var lastHeard = Date()
    private var watchdog: DispatchSourceTimer?
    private var stopped = false
    /// Called on an arbitrary queue whenever the picture changed.
    var onChange: (() -> Void)?
    /// Shared screen choices from the keeping Mac, and the moment the link is up again. Called on an arbitrary queue.
    var onSync: ((String, [String: SyncEntry]) -> Void)?
    var onDropSync: ((String, [String: SyncEntry]) -> Void)?
    var onLinked: (() -> Void)?

    init(host: String, port: UInt16, token: String, portraits: RelayPortraits? = nil, includeMessages: Bool = true) {
        self.host = host; self.port = port; self.token = token; self.portraits = portraits
        self.includeMessages = includeMessages
    }

    func start() {
        queue.async { [self] in
            guard watchdog == nil else { return }
            stopped = false; connect()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            // The relay speaks at least every ten seconds; long silence means a sleeping or unreachable peer.
            timer.setEventHandler { [weak self] in
                guard let self, self.welcomed, Date().timeIntervalSince(self.lastHeard) > 25 else { return }
                self.disconnected()
            }
            timer.resume(); watchdog = timer
        }
    }
    func setEnabled(chat: Bool, fileDrop: Bool) {
        if chat || fileDrop { start() } else { stop() }
    }
    func stop() {
        lock.lock(); isLinked = false; relayedStreams = []; lock.unlock()
        queue.sync { startupTapFailure = nil; stopped = true; watchdog?.cancel(); watchdog = nil; connection?.cancel(); connection = nil; welcomed = false }
        lock.lock(); let waiting = Array(pending.values); pending = [:]; lock.unlock()
        waiting.forEach { $0.done.signal() }
    }

    private func connect() {
        guard !stopped else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        tcp.noDelay = true; tcp.connectionTimeout = 8
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any, using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection; buffer = Data(); welcomed = false
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection, !self.stopped else { return }
            switch state {
            case .ready:
                var hello = RelayFrame(op: "hello"); hello.token = self.token
                hello.text = Host.current().localizedName
                self.lock.lock(); hello.unread = self.unread?.timeIntervalSince1970; self.lock.unlock()
                connection.send(content: hello.line(), completion: .contentProcessed { _ in })
                self.receive(connection)
            case .failed, .cancelled, .waiting: self.disconnected()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func disconnected() {
        guard let old = connection else { return }
        startupTapFailure = nil; connection = nil; welcomed = false; old.cancel()
        lock.lock()
        latest.status = .unavailable(wasDenied ? Self.denied : Self.lost); latest.typing = []; relayedSlack.writers = []; relayedStreams = []; isLinked = false
        dropFailureAt = Date()
        let waiting = Array(pending.values); pending = [:]
        lock.unlock()
        waiting.forEach { $0.done.signal() }
        onChange?()
        guard !stopped else { return }
        attempts += 1
        // A wrong code will not fix itself, so it is retried slowly.
        let delay = wasDenied ? 30 : min(10, pow(2, Double(min(attempts, 4)) - 1))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connection == nil else { return }
            self.connect()
        }
    }
    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak connection] data, _, finished, error in
            guard let self, let connection, self.connection === connection, !self.stopped else { return }
            if let data { self.buffer.append(data) }
            for frame in RelayFrame.take(from: &self.buffer) { if let frame { self.handle(frame) } }
            // 200 messages with avatars stay far below this; a line that never ends is not the relay.
            if self.buffer.count > 16 << 20 || finished || error != nil { self.disconnected(); return }
            self.receive(connection)
        }
    }
    private func handle(_ frame: RelayFrame) {
        lastHeard = Date()
        switch frame.op {
        case "denied":
            startupTapFailure = nil; wasDenied = true
            lock.lock(); dropDenied = true; lock.unlock()
        case "welcome":
            welcomed = true; wasDenied = false; attempts = 0
            lock.lock(); isLinked = true; dropDenied = false; dropVersion = frame.dropVersion ?? 0; dropEngine = frame.dropEngine ?? 0; checkVersion = frame.checkVersion ?? 0; lock.unlock()
            if let failure = startupTapFailure { startupTapFailure = nil; reportTapFailure(failure) }
            onLinked?()
        case "drop-sync":
            if let user = frame.user, let entries = frame.entries { onDropSync?(user, FileDropHistory.valid(entries)) }
        case "sync":
            if let user = frame.user, let entries = frame.entries { onSync?(user, entries) }
        case "result":
            lock.lock()
            let waiter = frame.id.flatMap { pending.removeValue(forKey: $0) }
            waiter?.reply = frame
            lock.unlock(); waiter?.done.signal()
        case "streams":
            lock.lock(); relayedStreams = frame.streams ?? []; lock.unlock()
        case "state":
            portraits?.receive(frame, fromRelay: true)
            lock.lock()
            lastStateAt = Date()
            let before = latest
            if let stores = frame.stores { latest.status = .connected(stores: stores) }
            else if let reason = frame.reason { latest.status = .unavailable(reason) }
            else if case .unavailable(let text) = latest.status, [Self.connecting, Self.lost, Self.denied].contains(text) { latest.status = .connected(stores: 0) }
            if includeMessages, let messages = frame.messages { latest.messages = messages.map(\.message) }
            if includeMessages, let typing = frame.typing { latest.typing = typing.map { TypingIndicator(id: $0.id, speaker: $0.speaker, profile: $0.profile) } }
            if includeMessages, let session = frame.session { latest.sessionToken = session }
            if let characters = frame.characters { latest.characters = characters.map { ChatCharacter(id: $0.id, name: $0.name) } }
            if let projects = frame.projects { latest.projects = projects }
            if let usage = frame.usage { relayedUsage = usage }
            if let slack = frame.slack { relayedSlack = slack }
            if let avatars = frame.avatars { latest.avatars = avatars.mapValues(\.avatar) }
            if includeMessages, let receipts = frame.receipts {
                latest.receipts = receipts.map { ChatReceipt(id: $0.id, fromUser: $0.fromUser, date: Date(timeIntervalSince1970: $0.date)) }
            }
            let changed = before.status != latest.status || before.messages != latest.messages || before.typing != latest.typing
                || before.characters != latest.characters || frame.avatars != nil || frame.receipts != nil || frame.projects != nil || frame.usage != nil || frame.slack != nil
            lock.unlock()
            if changed { onChange?() }
        default: break
        }
    }
    func reportTapFailure(_ failure: ThreeTapFailure) {
        guard failure.valid else { return }
        queue.async { [self] in
            guard let connection, !stopped else { return }
            if welcomed {
                var frame = RelayFrame(op: "three-tap-failure"); frame.tapFailure = failure
                connection.send(content: frame.line(), completion: .contentProcessed { _ in })
            } else if attempts == 0, !wasDenied {
                // An app-start fault may precede the first handshake. Never keep it across a disconnect.
                startupTapFailure = failure
                queue.asyncAfter(deadline: .now()+8) { [weak self] in
                    if self?.startupTapFailure?.key == failure.key { self?.startupTapFailure = nil }
                }
            }
        }
    }
    /// Passes on choices made here. Dropped while the link is down; everything is sent again once it is back.
    func sendSync(user: String, entries: [String: SyncEntry], replace: Bool) {
        let parts = entries.isEmpty ? [[:]] : SettingsSync.chunks(entries)
        for part in parts {
            var frame = RelayFrame(op: "sync"); frame.user = user; frame.entries = part
            if replace { frame.replace = true }
            send(frame)
        }
    }
    func sendDropSync(user: String, entries: [String: SyncEntry]) {
        for part in entries.isEmpty ? [[:]] : SettingsSync.chunks(FileDropHistory.valid(entries)) {
            var frame = RelayFrame(op: "drop-sync"); frame.user = user; frame.entries = part; send(frame)
        }
    }
    private func send(_ frame: RelayFrame) {
        queue.async { [self] in
            guard welcomed, let connection else { return }
            connection.send(content: frame.line(), completion: .contentProcessed { _ in })
        }
    }
    private func request(_ frame: RelayFrame) -> [ChatMessage] {
        guard includeMessages else { return [] }
        return (requestFrame(frame, timeout: 5)?.messages ?? []).map(\.message)
    }
    /// Runs a check on the sharing Mac. An older sharing Mac never answers the op, so the welcome frame decides up front.
    func connectionCheck(profile: String, connection: String?) throws -> [AgentActionReply] {
        lock.lock(); let supported = isLinked && checkVersion >= 1; lock.unlock()
        guard supported else { throw ConnectionFailure.oldRelay }
        var frame = RelayFrame(op: "connections-check"); frame.profile = profile; frame.connection = connection
        let limit = connection == nil ? ConnectionCommands.relayCheckAllSeconds : ConnectionCommands.relayCheckSeconds
        guard let reply = requestFrame(frame, timeout: limit) else { throw ConnectionFailure.timeout }
        guard let checks = reply.checks, !checks.isEmpty else { throw ConnectionFailure.command }
        return checks
    }
    func connectionStatus() throws -> AgentConnectionDocument {
        guard let reply = requestFrame(RelayFrame(op: "connections"), timeout: 9) else { throw ConnectionFailure.oldRelay }
        guard let document = reply.connections else { throw ConnectionFailure.command }
        return try AgentConnectionDocument.decode(JSONEncoder().encode(document))
    }
    private func requestFrame(_ frame: RelayFrame, timeout: Double) -> RelayFrame? {
        let waiter = Pending(); var frame = frame
        lock.lock(); nextID += 1; frame.id = nextID; pending[nextID] = waiter; let id = nextID; lock.unlock()
        queue.async { [self] in
            guard welcomed, let connection else {
                lock.lock(); pending.removeValue(forKey: id); lock.unlock(); waiter.done.signal(); return
            }
            connection.send(content: frame.line(), completion: .contentProcessed { _ in })
        }
        _ = waiter.done.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: id)
        return waiter.reply
    }

    /// Called off the main thread. Unknown/old relay versions fail without sending originals.
    func contextDrop(_ data: Data) throws -> Data {
        if supportsDropEngine {
            return try controlDrop(data, op: "drop-context")
        }
        return try suggestDrop(data, files: [], context: true)
    }
    func engineDrop(_ data: Data) throws -> Data {
        guard supportsDropEngine else { throw CocoaError(.featureUnsupported) }
        return try controlDrop(data, op: "drop-engine")
    }
    private func controlDrop(_ data: Data, op: String) throws -> Data {
        guard data.count <= 64 * 1024, supportsDropEngine else { throw FileDropServiceError.unavailable }
        var frame = RelayFrame(op: op); frame.drop = data
        let limit = op == "drop-engine" ? FileDropTiming.engineLimit(data) + FileDropTiming.processGrace : FileDropTiming.contextSeconds
        guard let reply = requestFrame(frame, timeout: limit), let result = reply.drop else { throw FileDropServiceError.unavailable }
        return result
    }
    func suggestDrop(_ signals: Data, files: [URL], context: Bool = false) throws -> Data {
        guard signals.count <= 64 * 1024, supportsDrop else { throw CocoaError(.featureUnsupported) }
        let waiter = Pending()
        lock.lock(); nextID += 1; let id = nextID; pending[id] = waiter; lock.unlock()
        queue.async { [self] in
            guard welcomed, let connection else { waiter.done.signal(); return }
            let numeric: String?
            if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint { numeric = String(describing: host) } else { numeric = nil }
            let encrypted = !files.isEmpty && (dropOriginalsAllowed?(connection) ?? numeric.map(FileDropEncryptedRoute.known) ?? false)
            let uploads = encrypted ? Array(files.prefix(5)) : []
            do {
                guard var request = try JSONSerialization.jsonObject(with: signals) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                var metadata: [[String: Any]] = []
                for file in uploads {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    metadata.append(["name": file.lastPathComponent, "size": size])
                }
                request["uploads"] = metadata; request["files"] = nil
                var open = RelayFrame(op: "drop-open"); open.id = id; open.drop = try JSONSerialization.data(withJSONObject: request)
                guard open.drop!.count <= 64 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                connection.send(content: open.line(), completion: .contentProcessed { _ in })
                for (index, file) in uploads.enumerated() {
                    let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                    var part = 0
                    while let chunk = try input.read(upToCount: 512 * 1024), !chunk.isEmpty {
                        var frame = RelayFrame(op: "drop-chunk"); frame.id = id; frame.file = index; frame.part = part; frame.drop = chunk
                        connection.send(content: frame.line(), completion: .contentProcessed { _ in }); part += 1
                    }
                }
                var run = RelayFrame(op: "drop-run"); run.id = id
                connection.send(content: run.line(), completion: .contentProcessed { _ in })
            } catch { waiter.done.signal() }
        }
        let limit = context ? FileDropTiming.contextSeconds : FileDropTiming.remaining(signals) + FileDropTiming.processGrace
        _ = waiter.done.wait(timeout: .now() + limit)
        lock.lock(); pending.removeValue(forKey: id); let reply = waiter.reply; let result = reply?.drop; let reason = reply?.reason; lock.unlock()
        if context && reply == nil { throw FileDropServiceError.legacyContextTimeout }
        if reason == "drop_sensitive" { throw FileDropServiceError.sensitive }
        if reason == "drop_timeout" { throw FileDropServiceError.timeout }
        guard let result else { throw FileDropServiceError.unavailable }
        let error = ((try? JSONSerialization.jsonObject(with: result)) as? [String: Any])?["error"] as? String
        if error == "engine_changed" { throw FileDropServiceError.engineChanged }
        if ["drop_deadline", "TimeoutExpired"].contains(error ?? "") { throw FileDropServiceError.timeout }
        return result
    }

    // MARK: HermesSource

    func poll(unreadSince: Date?) -> HermesBridge.PollResult {
        lock.lock()
        let changed = unread != unreadSince; unread = unreadSince
        var result = latest
        // Receipts were counted against the previous mark until the relay answers the new one.
        if let unreadSince { result.receipts = result.receipts.filter { $0.date > unreadSince } } else { result.receipts = [] }
        lock.unlock()
        if changed { var frame = RelayFrame(op: "watch"); frame.unread = unreadSince?.timeIntervalSince1970; send(frame) }
        return result
    }
    func search(_ text: String) -> [ChatMessage] {
        var frame = RelayFrame(op: "search"); frame.text = text; return request(frame)
    }
    func older(before message: ChatMessage?) -> [ChatMessage] {
        var frame = RelayFrame(op: "older"); frame.before = message.map(RelayFrame.Message.init)
        frame.before?.body = ""
        return request(frame)
    }
    func around(profile: String, messageID: Int64) -> [ChatMessage] {
        var frame = RelayFrame(op: "around"); frame.profile = profile; frame.row = messageID; return request(frame)
    }
}
