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
    /// Added by the Hermes command; absent in output from older commands, which then offer no buttons.
    var connect_kind: String? = nil
    var verified_by: String? = nil
    var expires_at: String? = nil
    var actions: [ConnectionAction]? = nil
    /// The buttons are exactly what the command lists; the app never infers one from a state.
    func action(_ kind: ConnectionAction.Kind) -> ConnectionAction? { actions?.first { $0.kind == kind } }
    var primaryAction: ConnectionAction? { actions?.first { $0.primary && $0.kind != nil } }
    var otherActions: [ConnectionAction] { (actions ?? []).filter { $0.kind != nil && $0.id != primaryAction?.id } }
    var explanation: String { ConnectionSentence.explanation(reason, kind: connect_kind) ?? account ?? state.title }
}
struct ConnectionAction: Codable, Hashable {
    enum Kind: String {
        case check, oauthConnect = "oauth_connect", secretSet = "secret_set", permissionRequest = "permission_request"
        case openSettings = "open_settings", gatewayRestart = "gateway_restart"
    }
    let id: String, label: String, primary: Bool
    /// A kind this app version does not know is not drawn.
    var kind: Kind? { Kind(rawValue: id) }
    /// Buttons that fix a problem are filled; reading or opening ones are outlined.
    var resolves: Bool { kind.map { [.oauthConnect, .secretSet, .permissionRequest, .gatewayRestart].contains($0) } ?? false }
}
/// One reply of any `hermes-connections` action command (check, secret, permission, gateway).
struct AgentActionReply: Codable {
    struct Check: Codable { let state: String, reason: String; let verified_by: String?, checked_at: String?, expires_at: String? }
    struct Field: Codable { let id: String, label: String, secure: Bool; var value: String? = nil }
    struct Guide: Codable {
        struct Item: Codable, Identifiable {
            struct Check: Codable { let field: String, pattern: String, message: String }
            let n: Int, text: String
            let open_url: String?, copy: String?, image: String?, check: Check?
            var id: Int { n }
        }
        let items: [Item]
        var steps: [String] { items.map(\.text) }
        var link: String? { items.compactMap(\.open_url).first }
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let rows = try? value.decode([Item].self) { items = rows; return }
            struct Legacy: Decodable { let steps: [String]; let link: String? }
            let old = try value.decode(Legacy.self)
            items = old.steps.enumerated().map { Item(n: $0.offset + 1, text: $0.element, open_url: $0.offset == 0 ? old.link : nil, copy: nil, image: nil, check: nil) }
        }
        func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(items) }
        func error(_ values: [String: String]) -> String? {
            for row in items {
                guard let check = row.check, let value = values[check.field], !value.isEmpty else { continue }
                guard let range = value.range(of: check.pattern, options: .regularExpression),
                      range.lowerBound == value.startIndex, range.upperBound == value.endIndex else { return check.message }
            }
            return nil
        }
    }
    struct Missing: Codable { let profile: String, connection: String }
    let action: String?, profile: String?, connection: String?
    let outcome: String, reason: String
    let check: Check?
    let results: [AgentActionReply]?
    let saved_names: [String]?, restart_required: Bool?, undo_until: String?
    let url: String?, instruction: String?
    let fields: [Field]?, guide: Guide?
    var input_error: String? = nil
    let last_restart_at: Double?, connected: Int?
    let missing: [Missing]?
    static func decode(_ data: Data) throws -> Self {
        guard data.count < 1_000_000, let reply = try? JSONDecoder().decode(Self.self, from: data) else { throw ConnectionFailure.invalid }
        return reply
    }
    /// Only System Settings privacy panes; never an arbitrary address from command output.
    var settingsURL: URL? {
        guard let url, url.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_") else { return nil }
        return URL(string: url)
    }
    var undoDeadline: Date? { undo_until.flatMap { ConnectionTime.date($0) } }
}

struct ActionNotice: Equatable {
    let success: Bool, text: String
}

/// Reply code to one owner-facing sentence. The command decides the code, this decides the words.
enum ConnectionSentence {
    /// Sentence for a reason code, or nil when the code has no wording of its own.
    static func explanation(_ reason: String, kind: String? = nil) -> String? {
        // A revoked channel token is fixed in the Slack app settings, not by a restart or a pasted value.
        if kind == "channel" && reason == "TOKEN_INVALID" { return "Slack 앱 설정에서 앱을 다시 설치해 주세요" }
        switch reason {
        case "CONFIG_ONLY": return "설정 기준 · 실제 서비스 연결은 확인하지 않았어요"
        case "MAC_PERMISSION_UNVERIFIED": return "설정 켜짐 · Hermes의 Mac 권한은 확인하지 못했어요"
        case "SCOPE_MISSING": return "필요한 Google 권한을 다시 동의해 주세요"
        case "TIMEOUT": return "확인 시간이 초과됐어요"
        case "CHECK_FAILED": return "연결 확인에 실패했어요"
        case "NO_CONNECTION_EVENT": return "이번 게이트웨이 시작 이후 연결 기록이 없어요"
        case "DISABLED": return "Hermes 설정에서 꺼져 있어요"
        case "NO_TOKEN": return "저장된 연결 값이 없어요"
        case "TOKEN_INVALID": return "저장된 토큰이 맞지 않아요"
        case "AUTH_FAILED": return "로그인에 실패했어요 · 저장된 계정 정보를 확인해 주세요"
        case "COOKIE_EXPIRED": return "X 로그인 값이 만료됐어요"
        case "FORMAT_INVALID": return "저장된 값의 형식이 맞지 않아요"
        case "NETWORK": return "서비스에 닿지 못했어요"
        case "RATE_LIMITED": return "요청이 많아 잠시 확인할 수 없어요"
        case "SERVER_ERROR": return "서비스 쪽 문제로 확인하지 못했어요"
        case "PUBLIC_ONLY": return "공개 글 읽기만 확인했어요 · 로그인 값은 없어요"
        case "PERMISSION_DENIED": return "Mac에서 허용되지 않았어요"
        case "NOT_DETERMINED": return "Mac 권한을 아직 묻지 않았어요"
        case "TARGET_UNAVAILABLE": return "대상 앱을 열지 못해 권한을 판정하지 못했어요"
        case "ACCOUNT_UNMAPPED": return "이 계정이 어느 범위인지 알 수 없어요"
        case "GOOGLE_VERIFIED", "NOTION_VERIFIED", "SYNOLOGY_VERIFIED", "X_COOKIE_VERIFIED", "INSTAGRAM_VERIFIED",
             "SLACK_VERIFIED", "PERMISSION_GRANTED", "GATEWAY_LOG": return "직접 확인했어요"
        default: return nil
        }
    }
    static func notice(_ reply: AgentActionReply, label: String, kind: String? = nil, now: Date = Date(), calendar: Calendar = .current) -> ActionNotice {
        func fail(_ text: String) -> ActionNotice { ActionNotice(success: false, text: text) }
        let action = reply.action ?? ""
        if reply.outcome == "refused" || reply.outcome == "failed" {
            switch reply.reason {
            case "BUSY": return fail("지금 대화를 처리 중이라 시작하지 않았어요. 잠시 뒤 다시 눌러 주세요.")
            case "BUSY_CHECK_FAILED": return fail("처리 중인 대화를 확인하지 못해 시작하지 않았어요.")
            case "RATE_LIMITED" where action == "gateway_restart":
                let when = ConnectionTime.label(reply.last_restart_at.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }, now: now, calendar: calendar)
                return fail("다시 시작은 60분에 한 번만 할 수 있어요. 마지막 시작: \(when.replacingOccurrences(of: " 확인", with: ""))")
            case "NOT_RECONNECTED":
                let names = (reply.missing ?? []).prefix(3).map { $0.profile + " " + $0.connection }.joined(separator: ", ")
                return fail("다시 시작했지만 일부 채널이 연결되지 않았어요" + (names.isEmpty ? "" : " (\(names))"))
            case "RESTART_FAILED", "RESTART_TIMEOUT": return fail("다시 시작하지 못했어요. 자동으로 다시 시도하지 않아요.")
            case "FORMAT_INVALID": return fail("값 형식이 맞지 않아요. 확인하고 다시 넣어 주세요.")
            case "TOKEN_INVALID": return fail("토큰이 맞지 않아 저장하지 않았어요.")
            case "AUTH_FAILED": return fail("로그인에 실패해 저장하지 않았어요. 계정 정보를 확인해 주세요.")
            case "COOKIE_EXPIRED": return fail("X 로그인 값이 맞지 않아 저장하지 않았어요.")
            case "TIMEOUT", "NETWORK": return fail(action.hasPrefix("secret") ? "서비스 응답이 없어 저장하지 않았어요." : "응답을 받지 못했어요. 잠시 뒤 다시 해 주세요.")
            case "RATE_LIMITED", "SERVER_ERROR", "CHECK_FAILED": return fail("서비스가 제한 중이라 확인하지 못했어요. 잠시 뒤 다시 해 주세요.")
            case "WRITE_FAILED": return fail("저장하지 못했어요. 기존 값은 그대로예요.")
            case "NAME_NOT_ALLOWED": return fail("이 연결은 화면에서 값을 바꿀 수 없어요.")
            case "NO_UNDO", "EXPIRED": return fail("되돌릴 수 있는 시간이 지났어요.")
            case "LAUNCH_FAILED": return fail("Mac 권한 확인을 시작하지 못했어요.")
            case "OFF": return fail("꺼져 있는 연결이에요.")
            case "UNKNOWN_CONNECTION", "UNKNOWN_PROFILE": return fail("이 연결을 찾지 못했어요. 새로 확인해 주세요.")
            default: return fail("하지 못했어요 (\(reply.reason))")
            }
        }
        switch action {
        case "secret_set":
            return ActionNotice(success: true, text: reply.restart_required == true
                ? "\(label) 값을 확인하고 저장했어요. 다시 시작해야 적용돼요."
                : "\(label) 값을 확인하고 저장했어요.")
        case "secret_undo": return ActionNotice(success: true, text: "\(label) 값을 이전으로 되돌렸어요." + (reply.restart_required == true ? " 다시 시작해야 적용돼요." : ""))
        case "gateway_restart": return ActionNotice(success: true, text: "다시 시작했고 채널 \(reply.connected ?? 0)개가 다시 연결됐어요.")
        case "open_settings": return ActionNotice(success: true, text: reply.instruction ?? "시스템 설정에서 허용해 주세요.")
        default: break
        }
        guard let check = reply.check else { return ActionNotice(success: true, text: "마쳤어요.") }
        if action == "permission_request" {
            switch check.state {
            case "connected": return ActionNotice(success: true, text: "Mac 권한이 허용됐어요.")
            case "not_connected": return fail("허용되지 않았어요. 시스템 설정에서 켜 주세요.")
            default: return fail("권한 창에서 허용하지 않아 아직 허용되지 않았어요.")
            }
        }
        if reply.reason == "RECENTLY_CHECKED" { return ActionNotice(success: check.state == "connected", text: "방금 확인한 결과예요. 잠시 뒤 다시 확인할 수 있어요.") }
        if reply.reason == "COOLDOWN" { return fail("로그인 실패 뒤 대기 중이라 다시 시도하지 않았어요. 30분 뒤 다시 확인해 주세요.") }
        switch check.state {
        case "connected":
            return ActionNotice(success: true, text: check.reason == "PUBLIC_ONLY" ? "공개 글 읽기만 확인했어요. 로그인 값은 없어요." : "연결을 확인했어요.")
        case "needs_reconnect", "not_connected":
            return fail("연결을 확인하지 못했어요. " + (explanation(check.reason, kind: kind) ?? ""))
        default:
            return fail("확인하지 못했어요. " + (explanation(check.reason, kind: kind) ?? ""))
        }
    }
    static func summary(_ replies: [AgentActionReply]) -> ActionNotice {
        let checks = replies.compactMap(\.check)
        let good = checks.filter { $0.state == "connected" }.count
        let others = replies.count - good
        return ActionNotice(success: others == 0, text: others == 0 ? "모두 확인했어요. \(good)개가 연결돼 있어요." : "\(replies.count)개를 확인했어요. \(good)개 연결됨, \(others)개는 확인이 필요해요.")
    }
}

/// Argument lists and time limits of the action commands. The value of a secret is never an argument.
enum ConnectionCommands {
    static func check(_ profile: String, _ connection: String) -> [String] { ["check", "--profile", profile, "--connection", connection, "--json"] }
    static func checkAll(_ profile: String) -> [String] { ["check", "--profile", profile, "--all", "--json"] }
    static func secret(_ verb: String, _ profile: String, _ connection: String) -> [String] { ["secret", verb, "--profile", profile, "--connection", connection, "--json"] }
    static func permission(_ verb: String, _ profile: String, _ connection: String) -> [String] { ["permission", verb, "--profile", profile, "--connection", connection, "--json"] }
    static let restart = ["gateway", "restart", "--json"]
    static let apps = ["apps", "--json"]
    /// Another Mac asks this Mac to run a check; it waits a little longer than the check's own limit.
    static let relayCheckSeconds = 35.0, relayCheckAllSeconds = 95.0
    static func timeout(_ arguments: [String]) -> Double {
        switch arguments.first {
        case "check": return arguments.contains("--all") ? 90 : 30
        case "secret": return 30
        case "permission": return arguments.dropFirst().first == "request" ? 130 : 30
        case "gateway": return 150
        default: return 30
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
        case .timeout: return "제한 시간 안에 끝나지 않았어요."
        case .oldRelay: return "맥미니 ddots를 업데이트하면 볼 수 있어요."
        }
    }
}

/// The app reads only this command's bounded JSON, never Hermes credential files.
enum AgentConnectionCommand {
    /// `input` reaches the command's standard input only; it is never an argument or environment value.
    static func run(executable: URL, arguments: [String], timeout: Double = 30, input: Data? = nil) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ConnectionFailure.missing }
        let process = Process(), pipe = Pipe(), stdin = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HERMES_DISABLE_LAZY_INSTALLS": "1", "PYTHONDONTWRITEBYTECODE": "1"
        ]) { _, new in new }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw ConnectionFailure.command }
        if let input {
            DispatchQueue.global(qos: .utility).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
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
    /// A check changed what the next status would say, so the 60-second copy is dropped.
    func invalidate() { lock.lock(); loaded = .distantPast; lock.unlock() }
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
    static func date(_ raw: String, calendar: Calendar = .current) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: raw)
        if date == nil { iso.formatOptions = [.withInternetDateTime]; date = iso.date(from: raw) }
        if date == nil {
            let log = DateFormatter(); log.locale = Locale(identifier: "en_US_POSIX")
            log.timeZone = calendar.timeZone; log.dateFormat = "yyyy-MM-dd HH:mm:ss"
            date = log.date(from: raw)
        }
        return date
    }
    static func label(_ raw: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let raw else { return "확인 전" }
        guard let date = date(raw, calendar: calendar) else { return "확인 시각 알 수 없음" }
        if (0..<60).contains(now.timeIntervalSince(date)) { return "방금 확인" }
        let local = DateFormatter(); local.locale = Locale(identifier: "ko_KR"); local.timeZone = calendar.timeZone
        local.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm '확인'" : "M월 d일 HH:mm '확인'"
        return local.string(from: date)
    }
}
