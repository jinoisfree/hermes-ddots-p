import Darwin
import Foundation

/// Relays this Mac's Hermes conversation and accepts a fixed maintenance notice. It polls only while another Mac is connected.
/// Plain sockets are used so the listener is bound to one address without being tied to an interface.
final class HermesRelayServer {
    private final class Client {
        let fd: Int32
        var drops: [Int: FileDropUpload] = [:]
        var dropRunning = false
        var contextRunning = false
        var engineRunning = false
        var sourceMac = ""
        var source: DispatchSourceRead?
        var buffer = Data()
        var authorized = false
        var unread: Date?
        var unreadChanged = false
        var status: HermesBridge.Status?
        var messages: [ChatMessage]?
        var typing: [TypingIndicator]?
        var session: String?
        var characters: [ChatCharacter]?
        var projects: [ThreadProject]?
        var avatars: [String: ProfileAvatar] = [:]
        var usage: RelayUsage?
        var streams: [StreamPreview]?
        var slack: SlackActivity?
        /// The Slack account whose shared choices this Mac follows, and what of them it already has.
        var dropSyncUser: String?
        var dropSyncSent: [String: SyncEntry] = [:]
        var syncUser: String?
        var syncSent: [String: SyncEntry] = [:]
        var lastSent = Date.distantPast
        init(_ fd: Int32) { self.fd = fd }
    }
    static let maximumClients = 8
    private var bridge: HermesBridge
    private let followsLocation: Bool
    private let token: String
    private let queue = DispatchQueue(label: AppIdentity.bundleID + ".relay", qos: .utility)
    private var listener: DispatchSourceRead?
    /// Shared screen choices, one file per Slack account, kept on this Mac. See `SettingsSync.swift`.
    private let syncFolder: URL
    private var syncStores: [String: SettingsStore] = [:]
    private let connectionHome: URL?
    private lazy var connectionCache = AgentConnectionCache { [connectionHome] in
        let home = connectionHome ?? HermesLocator.shared.locate() ?? HermesLocator.shared.fallbackHome
        return try AgentConnectionDocument.decode(AgentConnectionCommand.run(
            executable: home.appendingPathComponent("bin/hermes-connections"), arguments: ["status", "--json"]))
    }
    private var clients: [Int32: Client] = [:]
    private var streamTimer: DispatchSourceTimer?
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval
    private(set) var polls = 0
    var onTapFailure: ((ThreeTapFailure) -> Void)?
    var dropSuggest: ((Data) throws -> Data)?
    var dropContext: ((Data) throws -> Data)?
    var dropEngine: ((Data) throws -> Data)?
    var dropOriginalsAllowed: ((Int32) -> Bool)?
    // Paseo usage of this Mac, read off the relay queue at most once a minute while another Mac is connected.
    private let usageQueue = DispatchQueue(label: AppIdentity.bundleID + ".relay-usage", qos: .utility)
    private let readUsage: () -> (codex: ServiceUsage?, claude: ServiceUsage?)?
    private let usageInterval: TimeInterval
    private var usageCodex: ServiceUsage?, usageClaude: ServiceUsage?
    private var usageBusy = false
    private var nextUsage = Date.distantPast

    /// Message bodies, receipts and search go out only while the receiving ddots shows the iMessage side.
    let sendsMessages: Bool

    init(home: URL? = nil, token: String, interval: TimeInterval = 0.5, syncFolder: URL = SettingsStore.folder,
         usageInterval: TimeInterval = 60, sendsMessages: Bool = IMessageFeature.enabled,
         readUsage: @escaping () -> (codex: ServiceUsage?, claude: ServiceUsage?)? = UsageSources.paseo) {
        self.syncFolder = syncFolder; self.sendsMessages = sendsMessages
        self.connectionHome = home
        followsLocation = home == nil
        bridge = HermesBridge(home: home, makesImages: false); self.token = token; self.interval = interval
        self.usageInterval = usageInterval; self.readUsage = readUsage
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "ddots.Relay", code: 5, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private static func option(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32 = 1) {
        var value = value
        setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    /// Binds to one numeric IPv4 address and returns the bound port (port 0 picks a free one).
    func start(host: String, port: UInt16) throws -> UInt16 {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw Self.failure("공유 주소를 읽지 못했어요.") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.failure("공유 포트를 열지 못했어요.") }
        Self.option(fd, SOL_SOCKET, SO_REUSEADDR)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard bound == 0, named == 0, listen(fd, 8) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd); throw Self.failure("공유 포트를 열지 못했어요.")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let peer = accept(fd, nil, nil)
                guard peer >= 0 else { break }
                self?.accepted(peer)
            }
        }
        source.setCancelHandler { close(fd) }
        queue.sync { listener = source }
        source.resume()
        return UInt16(bigEndian: actual.sin_port)
    }
    func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            for client in Array(clients.values) { drop(client) }
            timer?.cancel(); timer = nil; streamTimer?.cancel(); streamTimer = nil
        }
    }

    private func accepted(_ fd: Int32) {
        guard clients.count < Self.maximumClients else { close(fd); return }
        // The accepted socket inherits non-blocking mode; writes here are short and rely on the send timeout instead.
        _ = fcntl(fd, F_SETFL, 0)
        Self.option(fd, SOL_SOCKET, SO_NOSIGPIPE); Self.option(fd, SOL_SOCKET, SO_KEEPALIVE); Self.option(fd, IPPROTO_TCP, TCP_NODELAY)
        Self.option(fd, IPPROTO_TCP, TCP_KEEPALIVE, 10); Self.option(fd, IPPROTO_TCP, TCP_KEEPINTVL, 5); Self.option(fd, IPPROTO_TCP, TCP_KEEPCNT, 3)
        var patience = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        let client = Client(fd)
        log(client, "connected")
        clients[fd] = client
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { self.drop(client); return }
            client.buffer.append(contentsOf: chunk[0..<count])
            for frame in RelayFrame.take(from: &client.buffer) {
                guard let frame, self.clients[fd] === client else { self.drop(client); return }
                self.handle(frame, from: client)
            }
            if client.buffer.count > (client.authorized ? RelayFrame.maximumAuthorizedLine : RelayFrame.maximumLine) { self.drop(client) }
        }
        source.setCancelHandler { close(fd) }
        client.source = source
        source.resume()
        // A peer that never presents the code is not kept around.
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak client] in
            guard let self, let client, !client.authorized else { return }
            self.drop(client)
        }
    }
    private func drop(_ client: Client) {
        guard clients[client.fd] === client else { return }
        log(client, "disconnected")
        clients[client.fd] = nil
        client.source?.cancel(); client.source = nil
        if !clients.values.contains(where: \.authorized) { timer?.cancel(); timer = nil; streamTimer?.cancel(); streamTimer = nil }
    }
    private func log(_ client: Client, _ result: String) {
        print("\(ISO8601DateFormatter().string(from: Date())) relay=\(result); address=\(FileDropEncryptedRoute.peer(client.fd) ?? "unknown")")
        fflush(stdout)
    }
    private func send(_ frame: RelayFrame, to client: Client) {
        guard clients[client.fd] === client else { return }
        client.lastSent = Date()
        let data = frame.line()
        let delivered = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let written = write(client.fd, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        if !delivered { drop(client) }
    }

    private func handle(_ frame: RelayFrame, from client: Client) {
        guard client.authorized else {
            guard frame.op == "hello", let offered = frame.token, RelaySettings.matches(offered, token) else {
                log(client, "denied")
                send(RelayFrame(op: "denied"), to: client); drop(client)
                return
            }
            client.authorized = true
            client.sourceMac = String((frame.text ?? FileDropEncryptedRoute.peer(client.fd) ?? "remote").prefix(100))
            client.unread = frame.unread.map(Date.init(timeIntervalSince1970:)); client.unreadChanged = client.unread != nil
            var welcome = RelayFrame(op: "welcome")
            welcome.checkVersion = 1
            welcome.dropVersion = dropSuggest != nil || FileDropRunner.available(bridge.home) ? 1 : 0
            welcome.dropEngine = FileDropRunner.engineAvailable(bridge.home) || (dropEngine != nil && dropContext != nil) ? 1 : 0
            log(client, "welcome; dropVersion=\(welcome.dropVersion ?? 0)")
            send(welcome, to: client)
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
                timer.setEventHandler { [weak self] in self?.tick() }
                timer.resume(); self.timer = timer
                let streamTimer = DispatchSource.makeTimerSource(queue: queue)
                streamTimer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(30))
                streamTimer.setEventHandler { [weak self] in self?.sendStreams() }
                streamTimer.resume(); self.streamTimer = streamTimer
            }
            tick()
            return
        }
        var reply = RelayFrame(op: "result"); reply.id = frame.id
        switch frame.op {
        case "connections":
            connectionCache.read { [weak self, weak client] result in
                guard let self, let client else { return }
                self.queue.async {
                    var answer = RelayFrame(op: "result"); answer.id = frame.id
                    switch result {
                    case .success(let document): answer.connections = document
                    case .failure: answer.reason = "CONNECTIONS_READ_FAILED"
                    }
                    if answer.line().count <= RelayFrame.maximumAuthorizedLine { self.send(answer, to: client) }
                }
            }
            return
        case "connections-check":
            receiveConnectionCheck(frame, from: client)
            return
        case "drop-open", "drop-chunk", "drop-run":
            receiveDrop(frame, from: client)
            return
        case "drop-context", "drop-engine":
            receiveDropControl(frame, from: client)
            return
        case "three-tap-failure":
            if let failure = frame.tapFailure, failure.valid { onTapFailure?(failure) }
            return
        case "watch":
            client.unread = frame.unread.map(Date.init(timeIntervalSince1970:)); client.unreadChanged = true
            return
        case "sync", "drop-sync":
            receiveSync(frame, from: client, drop: frame.op == "drop-sync")
            return
        case "search", "older", "around":
            // No message bodies leave this Mac while the receiving side shows none (IMessageFeature).
            guard sendsMessages else { reply.messages = []; break }
            switch frame.op {
            case "search": reply.messages = bridge.search(String((frame.text ?? "").prefix(200))).map(RelayFrame.Message.init)
            case "older": reply.messages = bridge.older(before: frame.before?.message).map(RelayFrame.Message.init)
            default: reply.messages = bridge.around(profile: frame.profile ?? "", messageID: frame.row ?? 0).map(RelayFrame.Message.init)
            }
        default: return
        }
        send(reply, to: client)
    }

    /// Context never owns an upload/request slot. Only the engine writer can change policy.
    private func receiveDropControl(_ frame: RelayFrame, from client: Client) {
        guard let id = frame.id, id > 0, let data = frame.drop, data.count <= 64 * 1024 else { return }
        let context = frame.op == "drop-context"
        guard !(context ? client.contextRunning : client.engineRunning),
              var request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if context {
            guard request["mode"] as? String == "context" else { return }
            client.contextRunning = true
        } else {
            guard request["mode"] as? String == "read" || request["mode"] as? String == "write" else { return }
            request["source"] = client.sourceMac
            client.engineRunning = true
        }
        guard let input = try? JSONSerialization.data(withJSONObject: request) else { return }
        let home = bridge.home, invoke = context ? dropContext : dropEngine
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak client] in
            var reply = RelayFrame(op: "result"); reply.id = id
            do { reply.drop = try invoke?(input) ?? FileDropRunner.run(input, home: home, engine: !context) }
            catch { reply.reason = "drop_unavailable" }
            let answer = reply
            self?.queue.async { [weak self, weak client] in
                guard let self, let client else { return }
                if context { client.contextRunning = false } else { client.engineRunning = false }
                self.send(answer, to: client)
            }
        }
    }

    /// Another Mac may only run the read-only `check` command, and only for a profile/connection this Mac's own latest
    /// status lists. Nothing it sends reaches a command line except those two names.
    private func receiveConnectionCheck(_ frame: RelayFrame, from client: Client) {
        guard let id = frame.id, id > 0 else { return }
        func answer(_ checks: [AgentActionReply]?, reason: String? = nil) {
            queue.async { [weak self, weak client] in
                guard let self, let client else { return }
                var reply = RelayFrame(op: "result"); reply.id = id; reply.checks = checks; reply.reason = reason
                if reply.line().count <= RelayFrame.maximumAuthorizedLine { self.send(reply, to: client) }
            }
        }
        connectionCache.read { [weak self] result in
            guard let self else { return }
            guard case .success(let document) = result,
                  let profile = document.agents.first(where: { $0.profile == frame.profile }) else { answer(nil, reason: "CONNECTION_NOT_LISTED"); return }
            if let name = frame.connection, !profile.connections.contains(where: { $0.id == name }) { answer(nil, reason: "CONNECTION_NOT_LISTED"); return }
            let arguments = frame.connection.map { ConnectionCommands.check(profile.profile, $0) } ?? ConnectionCommands.checkAll(profile.profile)
            let home = self.connectionHome ?? HermesLocator.shared.locate() ?? HermesLocator.shared.fallbackHome
            DispatchQueue.global(qos: .utility).async {
                let run = Result { try AgentActionReply.decode(AgentConnectionCommand.run(
                    executable: home.appendingPathComponent("bin/hermes-connections"), arguments: arguments,
                    timeout: ConnectionCommands.timeout(arguments))) }
                self.connectionCache.invalidate()
                switch run {
                case .failure: answer(nil, reason: "CONNECTIONS_CHECK_FAILED")
                case .success(let reply): answer(reply.results ?? [reply])
                }
            }
        }
    }

    private func receiveDrop(_ frame: RelayFrame, from client: Client) {
        guard let id = frame.id, id > 0 else { return }
        func fail() {
            client.drops[id] = nil
            var reply = RelayFrame(op: "result"); reply.id = id; reply.reason = "drop_unavailable"
            send(reply, to: client)
        }
        do {
            switch frame.op {
            case "drop-open":
                guard client.drops.isEmpty, !client.dropRunning, let data = frame.drop else { fail(); return }
                let hasOriginals = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["uploads"] as? [Any]
                let encrypted: Bool
                if hasOriginals?.isEmpty != false { encrypted = false }
                else if let verify = dropOriginalsAllowed { encrypted = verify(client.fd) }
                else {
                    let peer = FileDropEncryptedRoute.peer(client.fd).map(FileDropEncryptedRoute.known) ?? false
                    let local = FileDropEncryptedRoute.peer(client.fd, local: true).map(FileDropEncryptedRoute.known) ?? false
                    encrypted = peer && local
                }
                client.drops[id] = try FileDropUpload(data: data, originals: encrypted)
                queue.asyncAfter(deadline: .now() + FileDropTiming.remaining(data) + FileDropTiming.processGrace) { [weak self, weak client] in
                    guard let self, let client, client.drops[id] != nil else { return }
                    client.drops[id] = nil
                    var reply = RelayFrame(op: "result"); reply.id = id; reply.reason = "drop_timeout"
                    self.send(reply, to: client)
                }
            case "drop-chunk":
                guard let upload = client.drops[id], let file = frame.file, let part = frame.part, let data = frame.drop else { fail(); return }
                try upload.append(data, file: file, part: part)
            default:
                guard let upload = client.drops.removeValue(forKey: id), !client.dropRunning else { fail(); return }
                let data = try upload.finish(), home = bridge.home, suggest = dropSuggest
                client.dropRunning = true
                DispatchQueue.global(qos: .userInitiated).async { [weak self, weak client, upload] in
                    var reply = RelayFrame(op: "result"); reply.id = id
                    do { reply.drop = try suggest?(data) ?? FileDropRunner.run(data, home: home) }
                    catch FileDropServiceError.sensitive { reply.reason = "drop_sensitive" }
                    catch { reply.reason = "drop_unavailable" }
                    // Retain the request folder through the subprocess, then let its owner remove it.
                    _ = upload.paths.count
                    let response = reply
                    self?.queue.async { [weak self, weak client] in
                        guard let self, let client else { return }; client.dropRunning = false
                        self.send(response, to: client)
                    }
                }
            }
        } catch { fail() }
    }

    private func syncStore(_ user: String, drop: Bool = false) -> SettingsStore? {
        let key = (drop ? "drop:" + bridge.home.path + ":" : "screen:") + user
        if let store = syncStores[key] { return store }
        let folder = drop ? FileDropHistory.folder(home: bridge.home) : syncFolder
        guard let store = SettingsStore(user: user, folder: folder) else { return nil }
        syncStores[key] = store; return store
    }
    /// Screen choices and drop history reuse the merge protocol but own separate files.
    private func receiveSync(_ frame: RelayFrame, from client: Client, drop: Bool) {
        guard let user = frame.user, let store = syncStore(user, drop: drop) else { return }
        if drop {
            if client.dropSyncUser != user { client.dropSyncUser = user; client.dropSyncSent = [:] }
        } else if client.syncUser != user { client.syncUser = user; client.syncSent = [:] }
        let entries = drop ? FileDropHistory.valid(frame.entries ?? [:]) : frame.entries ?? [:]
        guard !entries.isEmpty else { return }
        let at = entries.values.map(\.at).max() ?? Date().timeIntervalSince1970, by = entries.values.first?.by ?? ""
        store.merge(entries, replacing: !drop && frame.replace == true, at: at, by: by)
        for (key, entry) in entries where store.entries[key] == entry {
            if drop { client.dropSyncSent[key] = entry } else { client.syncSent[key] = entry }
        }
    }
    private func sendSync(to watchers: [Client]) {
        for drop in [false, true] {
            var refreshed = Set<String>()
            for client in watchers {
                guard let user = drop ? client.dropSyncUser : client.syncUser, let store = syncStore(user, drop: drop) else { continue }
                if refreshed.insert(user).inserted { _ = store.refresh() }
                let seen = drop ? client.dropSyncSent : client.syncSent
                let missing = SettingsSync.difference(store.entries, from: seen)
                guard !missing.isEmpty else { continue }
                for part in SettingsSync.chunks(missing) {
                    var frame = RelayFrame(op: drop ? "drop-sync" : "sync"); frame.user = user; frame.entries = part
                    send(frame, to: client)
                }
                if drop { client.dropSyncSent.merge(missing) { _, latest in latest } }
                else { client.syncSent.merge(missing) { _, latest in latest } }
            }
        }
    }

    /// File stamps make an unchanged poll a handful of stat calls; frames go out only when something differs.
    private func tick() {
        let watchers = clients.values.filter(\.authorized)
        guard !watchers.isEmpty else { return }
        if followsLocation, let home = HermesLocator.shared.locate(), home != bridge.home { bridge = HermesBridge(home: home, makesImages: false) }
        polls += 1
        refreshUsage()
        let usage = usageCodex == nil && usageClaude == nil ? nil : RelayUsage(codex: usageCodex, claude: usageClaude)
        sendSync(to: watchers)
        // The receiving ddots shows no iMessage conversation (IMessageFeature): never send message bodies it would drop.
        let result = bridge.poll(unreadSince: nil, includeMessages: sendsMessages)
        // Who is writing in which Slack thread; the other Mac shows the dots under its own Slack view.
        let slack = bridge.slackActivity()
        var receipts: [Double: [RelayFrame.Receipt]] = [:]
        for client in watchers {
            var frame = RelayFrame(op: "state"); var changed = false
            if client.status != result.status {
                client.status = result.status; changed = true
                switch result.status {
                case .connected(let stores): frame.stores = stores
                case .unavailable(let reason): frame.reason = reason
                }
            }
            let messagesChanged = client.messages != result.messages
            if client.projects != result.projects { client.projects = result.projects; frame.projects = result.projects; changed = true }
            if messagesChanged { client.messages = result.messages; frame.messages = result.messages.map(RelayFrame.Message.init); changed = true }
            if client.typing != result.typing {
                client.typing = result.typing; changed = true
                frame.typing = result.typing.map { RelayFrame.Typing(id: $0.id, speaker: $0.speaker, profile: $0.profile) }
            }
            if client.session != result.sessionToken { client.session = result.sessionToken; frame.session = result.sessionToken; changed = true }
            if client.characters != result.characters {
                client.characters = result.characters; changed = true
                frame.characters = result.characters.map { RelayFrame.Character(id: $0.id, name: $0.name) }
            }
            if client.avatars != result.avatars { client.avatars = result.avatars; frame.avatars = result.avatars.mapValues(RelayFrame.Avatar.init); changed = true }
            if let usage, client.usage != usage { client.usage = usage; frame.usage = usage; changed = true }
            if client.slack != slack { client.slack = slack; frame.slack = slack; changed = true }
            if sendsMessages, let unread = client.unread, messagesChanged || client.unreadChanged {
                let key = unread.timeIntervalSince1970
                if receipts[key] == nil {
                    receipts[key] = bridge.receipts(after: unread).map { RelayFrame.Receipt(id: $0.id, fromUser: $0.fromUser, date: $0.date.timeIntervalSince1970) }
                }
                frame.receipts = receipts[key]; client.unreadChanged = false; changed = true
            }
            // A quiet line still says it is alive, so the other Mac can tell silence from a dead link.
            if changed || Date().timeIntervalSince(client.lastSent) >= 10 { send(frame, to: client) }
        }
    }

    private func sendStreams() {
        let previews = StreamPreview.read(home: bridge.home)
        for client in clients.values where client.authorized && client.streams != previews {
            client.streams = previews
            var frame = RelayFrame(op: "streams"); frame.streams = previews
            send(frame, to: client)
        }
    }

    private func refreshUsage() {
        guard !usageBusy, Date() >= nextUsage else { return }
        usageBusy = true
        usageQueue.async { [weak self] in
            guard let self else { return }
            let read = self.readUsage()
            self.queue.async {
                self.usageBusy = false; self.nextUsage = Date().addingTimeInterval(self.usageInterval)
                self.usageCodex = UsageRetention.next(previous: self.usageCodex, incoming: read?.codex)
                self.usageClaude = UsageRetention.next(previous: self.usageClaude, incoming: read?.claude)
            }
        }
    }

    /// Entry point for `--relay`: no window, no status item, nothing drawn.
    static func runForever(arguments: [String]) -> Never {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        }
        let port = value("--relay-port").flatMap { UInt16($0) } ?? RelaySettings.port
        guard let token = (try? RelaySettings.serverToken(create: true)) ?? nil else {
            fputs("연결 코드를 준비하지 못했어요.\n", stderr); exit(1)
        }
        let server = HermesRelayServer(token: token)
        let maintenance = ThreeTapSender()
        server.onTapFailure = { maintenance.send($0) }
        // Tailscale may come up after login; keep trying instead of exiting into a launchd restart loop.
        let stamp = ISO8601DateFormatter()
        var waiting = false
        while true {
            let host = value("--relay-host") ?? RelaySettings.tailnetAddress()
            if let host, let bound = try? server.start(host: host, port: port) {
                print("\(stamp.string(from: Date())) relay=listening; host=\(host); port=\(bound)"); fflush(stdout)
                break
            }
            // Said once, so a long wait for Tailscale does not fill the log.
            if !waiting { print("\(stamp.string(from: Date())) relay=waiting; \(host == nil ? "no Tailscale address yet" : "port \(port) could not be opened")"); fflush(stdout); waiting = true }
            Thread.sleep(forTimeInterval: 10)
        }
        dispatchMain()
    }
}
