import Foundation
import Network

/// The Hermes conversation of another Mac, pushed over the relay. Conversations stay in memory; only character names and pictures may be kept locally.
final class RemoteHermes: HermesSource {
    static let connecting = "공유하는 Mac에 연결하는 중이에요."
    static let lost = "공유하는 Mac에 연결하지 못했어요. 다시 연결하는 중이에요."
    static let denied = "연결 코드가 맞지 않아요. Hermes 연결에서 다시 입력해 주세요."
    private let includeMessages: Bool
    private final class Pending { let done = DispatchSemaphore(value: 0); var messages: [ChatMessage] = [] }
    private let host: String, port: UInt16, token: String
    private let portraits: RelayPortraits?
    private let queue = DispatchQueue(label: AppIdentity.bundleID + ".remote", qos: .utility)
    private let lock = NSLock()
    private var latest = HermesBridge.PollResult(status: .unavailable(RemoteHermes.connecting), messages: [])
    private var lastStateAt: Date?
    /// True while the sharing Mac has accepted this one and is still heard from.
    var linked: Bool { lock.lock(); defer { lock.unlock() }; return isLinked }
    private var isLinked = false
    var lastReceivedAt: Date? { lock.lock(); defer { lock.unlock() }; return lastStateAt }
    private var relayedUsage: RelayUsage?
    /// Paseo usage of the sharing Mac. Kept across a lost link; each value expires by its own observation time.
    var usage: RelayUsage? { lock.lock(); defer { lock.unlock() }; return relayedUsage }
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
    func stop() {
        lock.lock(); isLinked = false; lock.unlock()
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
        latest.status = .unavailable(wasDenied ? Self.denied : Self.lost); latest.typing = []; relayedSlack.writers = []; isLinked = false
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
        case "denied": startupTapFailure = nil; wasDenied = true
        case "welcome":
            welcomed = true; wasDenied = false; attempts = 0
            lock.lock(); isLinked = true; lock.unlock()
            if let failure = startupTapFailure { startupTapFailure = nil; reportTapFailure(failure) }
            onLinked?()
        case "sync":
            if let user = frame.user, let entries = frame.entries { onSync?(user, entries) }
        case "result":
            lock.lock()
            let waiter = frame.id.flatMap { pending.removeValue(forKey: $0) }
            waiter?.messages = (frame.messages ?? []).map(\.message)
            lock.unlock(); waiter?.done.signal()
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
    private func send(_ frame: RelayFrame) {
        queue.async { [self] in
            guard welcomed, let connection else { return }
            connection.send(content: frame.line(), completion: .contentProcessed { _ in })
        }
    }
    private func request(_ frame: RelayFrame) -> [ChatMessage] {
        guard includeMessages else { return [] }
        let waiter = Pending(); var frame = frame
        lock.lock(); nextID += 1; frame.id = nextID; pending[nextID] = waiter; let id = nextID; lock.unlock()
        queue.async { [self] in
            guard welcomed, let connection else {
                lock.lock(); pending.removeValue(forKey: id); lock.unlock(); waiter.done.signal(); return
            }
            connection.send(content: frame.line(), completion: .contentProcessed { _ in })
        }
        _ = waiter.done.wait(timeout: .now() + 5)
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: id)
        return waiter.messages
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
