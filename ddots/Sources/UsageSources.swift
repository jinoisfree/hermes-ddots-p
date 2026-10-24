import Foundation

// All readers run on the usage queue. Nothing here persists credentials or responses.
enum UsageSources {
    // Decode only routing fields; unsolicited stream payloads are never inspected or retained.
    private struct PaseoEnvelope: Decodable {
        let type: String
        let message: Message?
        enum CodingKeys: String, CodingKey { case type, message }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            type = try fields.decode(String.self, forKey: .type)
            message = type == "session" ? try fields.decodeIfPresent(Message.self, forKey: .message) : nil
        }
        struct Message: Decodable {
            let type: String
            let payload: Payload?
            enum CodingKeys: String, CodingKey { case type, payload }
            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                type = try fields.decode(String.self, forKey: .type)
                payload = type == "provider.usage.list.response" ? try fields.decodeIfPresent(Payload.self, forKey: .payload) : nil
            }
            struct Payload: Decodable { let requestId: String? }
        }
    }
    private final class PaseoSessionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private final class PaseoResult {
        private let lock = NSLock()
        private var value: (codex: ServiceUsage?, claude: ServiceUsage?)?
        func put(_ value: (codex: ServiceUsage?, claude: ServiceUsage?)?) { lock.lock(); defer { lock.unlock() }; self.value = value }
        func get() -> (codex: ServiceUsage?, claude: ServiceUsage?)? { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func paseoURL(listen: String) -> URL? {
        guard let parts = URLComponents(string: "ws://" + listen),
              let host = parts.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              let port = parts.port, (1...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil else { return nil }
        var url = parts; url.path = "/ws"
        return url.url
    }
    static func paseo() -> (codex: ServiceUsage?, claude: ServiceUsage?)? {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".paseo")
        guard let pid = try? Data(contentsOf: home.appendingPathComponent("paseo.pid")),
              let listen = UsageParser.object(pid)?["listen"] as? String, let url = paseoURL(listen: listen),
              let text = try? String(contentsOf: home.appendingPathComponent("local-credential"), encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 10
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: PaseoSessionDelegate(), delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 64 * 1024 * 1024
        let done = DispatchSemaphore(value: 0), result = PaseoResult()
        let requestID = UUID().uuidString
        socket.resume()
        let task = Task {
            defer { done.signal() }
            do {
                func json(_ value: [String: Any]) throws -> URLSessionWebSocketTask.Message {
                    .string(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
                }
                try await socket.send(json(["type": "hello", "clientId": "ddots-usage", "clientType": "cli", "protocolVersion": 1,
                                            "auth": ["kind": "localCredential", "token": token]]))
                try await socket.send(json(["type": "session", "message": ["type": "provider.usage.list.request", "requestId": requestID]]))
                var bytes = 0
                for _ in 0..<500 {
                    let data: Data
                    switch try await socket.receive() {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: return
                    }
                    bytes += data.count
                    guard bytes <= 64 * 1024 * 1024, !Task.isCancelled else { return }
                    guard let envelope = try? JSONDecoder().decode(PaseoEnvelope.self, from: data),
                          envelope.type == "session", envelope.message?.type == "provider.usage.list.response",
                          envelope.message?.payload?.requestId == requestID else { continue }
                    result.put(UsageParser.paseo(data)); return
                }
            } catch { /* Leave the previous values in memory; never log responses or credentials. */ }
        }
        let completed = done.wait(timeout: .now() + 10) == .success
        task.cancel(); socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
        return completed ? result.get() : nil
    }
}

final class UsageMonitor {
    private let queue = DispatchQueue(label: "ddots.usage", qos: .utility)
    private var paseoCodex: ServiceUsage?, paseoClaude: ServiceUsage?
    private var lastAt: Date?
    private var lastOK = false
    private var busy = false
    private var suspended = true
    private var generation = 0
    private var nextPaseo = Date.distantPast
    var fixture = false
    var onChange: (() -> Void)?

    var paseoStatus: String {
        if fixture { return "Paseo 사용 중" }
        return UsageText.paseoStatus(at: lastAt, ok: lastOK,
                                    codex: paseoCodex?.label() ?? "—", claude: paseoClaude?.label() ?? "—")
    }
    var subtitle: String {
        if fixture {
            let now = Date()
            let c = ServiceUsage(observedAt: now, maxAge: 900, windows: [UsageWindow(weekly: false, usedPercent: 28)])
            let h = ServiceUsage(observedAt: now, maxAge: 1800, windows: [UsageWindow(weekly: true, usedPercent: 52)])
            return UsageText.subtitle(codex: c.label(now: now), claude: h.label(now: now))
        }
        return UsageText.subtitle(codex: paseoCodex?.label() ?? "—", claude: paseoClaude?.label() ?? "—")
    }
    func tick(paused: Bool, smoke: Bool) {
        let wasSuspended = suspended
        suspended = paused || smoke || fixture
        if suspended != wasSuspended { generation += 1 }
        guard !suspended, !busy, Date() >= nextPaseo else { return }
        let requestGeneration = generation
        busy = true
        queue.async { [weak self] in
            let allowed = DispatchQueue.main.sync {
                guard let self else { return false }
                return !self.suspended && self.generation == requestGeneration
            }
            let p = allowed ? UsageSources.paseo() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard !self.suspended, self.generation == requestGeneration else {
                    self.nextPaseo = .distantPast
                    self.onChange?(); return
                }
                let now = Date()
                self.paseoCodex = UsageRetention.next(previous: self.paseoCodex, incoming: p?.codex)
                self.paseoClaude = UsageRetention.next(previous: self.paseoClaude, incoming: p?.claude)
                self.nextPaseo = now.addingTimeInterval(60)
                self.lastAt = now; self.lastOK = p != nil
                self.onChange?()
            }
        }
    }
}
