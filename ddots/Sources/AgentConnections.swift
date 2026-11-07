import Foundation
import Darwin

struct AgentConnectionDocument: Codable {
    let schema: String
    let checked_at: String
    let agents: [AgentConnectionProfile]
    static func decode(_ data: Data) throws -> Self {
        guard data.count < 1_000_000 else { throw ConnectionFailure.invalid }
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard document.schema == "hermes-connections/1",
              Set(document.agents.map(\.profile)).count == document.agents.count,
              document.agents.allSatisfy({ !$0.profile.isEmpty && Set($0.connections.map(\.id)).count == $0.connections.count })
        else { throw ConnectionFailure.invalid }
        return document
    }
}
struct AgentConnectionProfile: Codable, Identifiable {
    let profile: String, display_name: String
    let connections: [AgentConnectionItem]
    var id: String { profile }
    var summary: String {
        if connections.contains(where: { $0.state == .needsReconnect || $0.state == .notConnected }) { return "다시 연결 필요" }
        return !connections.isEmpty && connections.allSatisfy { $0.state == .connected || $0.state == .off } ? "연결됨" : "확인 안 됨"
    }
}
struct AgentConnectionItem: Codable, Identifiable {
    enum Group: String, Codable { case account, mac, channel }
    enum State: String, Codable {
        case connected, needsReconnect = "needs_reconnect", notConnected = "not_connected", unknown, off
        var title: String {
            switch self {
            case .connected: return "연결됨"
            case .needsReconnect: return "다시 연결 필요"
            case .notConnected: return "연결 안 됨"
            case .unknown: return "확인 안 됨"
            case .off: return "꺼짐"
            }
        }
    }
    enum Account: String, Codable { case personal, company }
    let id: String, service: String, label: String, reason: String, checked_at: String
    let group: Group, state: State
    let account: String?
    let scope: Account?, reconnect: Account?
    let capabilities: [String], rules: [String]
    var canReconnect: Bool { reconnect != nil && (state == .needsReconnect || state == .notConnected) }
    var explanation: String {
        switch reason {
        case "CONFIG_ONLY": return "설정 기준 · 실제 서비스 연결은 확인하지 않았어요"
        case "MAC_PERMISSION_UNVERIFIED": return "설정 켜짐 · Hermes의 Mac 권한은 확인하지 못했어요"
        case "SCOPE_MISSING": return "필요한 Google 권한을 다시 동의해 주세요"
        case "TIMEOUT": return "확인 시간이 초과됐어요"
        case "CHECK_FAILED": return "연결 확인에 실패했어요"
        case "NO_CONNECTION_EVENT": return "이번 게이트웨이 시작 이후 연결 기록이 없어요"
        case "DISABLED": return "Hermes 설정에서 꺼져 있어요"
        default: return account ?? state.title
        }
    }
}
struct AgentReconnectReply: Decodable {
    let state: String
    let reason: String?
    let url: String?
    let exit_code: Int?
    var loginURL: URL? {
        guard let url, let value = URL(string: url), value.scheme == "https",
              value.host == "accounts.google.com", value.user == nil, value.password == nil,
              value.port == nil, value.path.hasPrefix("/o/oauth2/") else { return nil }
        return value
    }
}
enum ConnectionFailure: Error, LocalizedError {
    case missing, command, invalid, timeout, oldRelay
    var errorDescription: String? {
        switch self {
        case .missing: return "이 Mac에 연결 상태 명령이 없어요."
        case .command: return "연결 상태 명령을 실행하지 못했어요."
        case .invalid: return "연결 상태 자료의 형식이 맞지 않아요."
        case .timeout: return "연결 상태 확인이 30초를 넘었어요."
        case .oldRelay: return "맥미니 ddots를 업데이트하면 볼 수 있어요."
        }
    }
}

/// The app reads only this command's bounded JSON, never Hermes credential files.
enum AgentConnectionCommand {
    static func run(executable: URL, arguments: [String], timeout: Double = 30) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ConnectionFailure.missing }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HERMES_DISABLE_LAZY_INSTALLS": "1", "PYTHONDONTWRITEBYTECODE": "1"
        ]) { _, new in new }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw ConnectionFailure.command }
        let read = DispatchGroup(), lock = NSLock()
        var output = Data(), oversized = false
        read.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { read.leave() }
            while let part = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !part.isEmpty {
                lock.lock()
                if output.count + part.count > 1_000_000 { oversized = true }
                if !oversized { output.append(part) }
                lock.unlock()
                if oversized { process.terminate(); break }
            }
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 0.2) != .success { kill(process.processIdentifier, SIGKILL) }
            throw ConnectionFailure.timeout
        }
        guard read.wait(timeout: .now() + 0.2) == .success else { throw ConnectionFailure.command }
        lock.lock(); defer { lock.unlock() }
        guard !oversized else { throw ConnectionFailure.invalid }
        guard process.terminationStatus == 0 else { throw ConnectionFailure.command }
        return output
    }
}

/// One refresh in flight, shared by local UI and relay requests; last good data is retained.
final class AgentConnectionCache {
    typealias Reply = Result<AgentConnectionDocument, Error>
    private let lock = NSLock()
    private var cached: AgentConnectionDocument?, loaded = Date.distantPast
    private var waiting: [(Reply) -> Void] = []
    private let fetch: () throws -> AgentConnectionDocument
    init(fetch: @escaping () throws -> AgentConnectionDocument) { self.fetch = fetch }
    func read(force: Bool = false, completion: @escaping (Reply) -> Void) {
        lock.lock()
        if !force, let cached, Date().timeIntervalSince(loaded) < 60 {
            lock.unlock(); completion(.success(cached)); return
        }
        waiting.append(completion)
        guard waiting.count == 1 else { lock.unlock(); return }
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { try fetch() }
            lock.lock()
            if case .success(let value) = result { cached = value; loaded = Date() }
            let callbacks = waiting; waiting = []
            lock.unlock()
            callbacks.forEach { $0(result) }
        }
    }
}

/// All status timestamps use the viewing Mac's local calendar and time zone.
enum ConnectionTime {
    static func label(_ raw: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let raw else { return "확인 전" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: raw)
        if date == nil { iso.formatOptions = [.withInternetDateTime]; date = iso.date(from: raw) }
        if date == nil {
            let log = DateFormatter(); log.locale = Locale(identifier: "en_US_POSIX")
            log.timeZone = calendar.timeZone; log.dateFormat = "yyyy-MM-dd HH:mm:ss"
            date = log.date(from: raw)
        }
        guard let date else { return "확인 시각 알 수 없음" }
        if (0..<60).contains(now.timeIntervalSince(date)) { return "방금 확인" }
        let local = DateFormatter(); local.locale = Locale(identifier: "ko_KR"); local.timeZone = calendar.timeZone
        local.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm '확인'" : "M월 d일 HH:mm '확인'"
        return local.string(from: date)
    }
}
