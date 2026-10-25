import Foundation
import CoreFoundation

struct UsageWindow {
    let weekly: Bool
    let usedPercent: Double
    var resetAt: Date? = nil
}

struct ServiceUsage {
    let observedAt: Date
    let maxAge: TimeInterval
    let windows: [UsageWindow]

    func label(now: Date = Date()) -> String {
        guard now.timeIntervalSince(observedAt) <= maxAge, observedAt <= now.addingTimeInterval(60),
              let window = windows.filter({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && ($0.resetAt == nil || $0.resetAt! > now) })
                .max(by: { ceil($0.usedPercent) < ceil($1.usedPercent) }) else { return "—" }
        return (window.weekly ? "주 " : "") + "\(100 - Int(ceil(window.usedPercent)))%"
    }
}

enum UsageParser {
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func percent(_ value: Any?) -> Double? {
        guard let n = number(value), (0...100).contains(n) else { return nil }; return n
    }
    static func object(_ data: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
    static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    static func paseo(_ data: Data, now: Date = Date()) -> (codex: ServiceUsage?, claude: ServiceUsage?)? {
        guard let raw = object(data), raw["type"] as? String == "session",
              let message = raw["message"] as? [String: Any], message["type"] as? String == "provider.usage.list.response",
              let payload = message["payload"] as? [String: Any], let observed = isoDate(payload["fetchedAt"]),
              let providers = payload["providers"] as? [[String: Any]] else { return nil }
        func service(_ id: String) -> ServiceUsage? {
            guard let provider = providers.first(where: { $0["providerId"] as? String == id && $0["status"] as? String == "available" }),
                  let values = provider["windows"] as? [[String: Any]] else { return nil }
            let windows = values.compactMap { value -> UsageWindow? in
                guard let id = value["id"] as? String, id == "five_hour" || id == "weekly",
                      let used = percent(value["usedPct"]) else { return nil }
                let reset = isoDate(value["resetsAt"])
                if let supplied = value["resetsAt"], !(supplied is NSNull), reset == nil { return nil }
                return UsageWindow(weekly: id == "weekly", usedPercent: used, resetAt: reset)
            }
            return ServiceUsage(observedAt: observed, maxAge: 3600, windows: windows)
        }
        return (service("codex-paseo") ?? service("codex"), service("claude"))
    }
}

enum UsageText {
    static func subtitle(codex: String, claude: String) -> String {
        // Remove separator spaces so both weekly 100% labels fit the fixed bubble.
        let separator = codex.count + claude.count >= 12 ? "·" : " · "
        return "Codex \(codex)\(separator)Claude Code \(claude)"
    }
    static func paseoStatus(at: Date?, ok: Bool, codex: String, claude: String, timeZone: TimeZone = .current) -> String {
        guard let at else { return "Paseo 조회 대기 중" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"; formatter.timeZone = timeZone
        let last = " · 마지막 조회 " + formatter.string(from: at)
        let hasCodex = codex != "—", hasClaude = claude != "—"
        if !ok {
            return "Paseo 조회 실패" + last + (hasCodex || hasClaude ? " · 이전 값 표시" : "")
        }
        if hasCodex && hasClaude { return "Paseo 사용 중" + last }
        if hasCodex || hasClaude { return "Paseo 일부만 조회됨" + last }
        return "Paseo 사용량 없음 · Paseo 앱 확인"
    }
}

enum UsageRetention {
    static func next(previous: ServiceUsage?, incoming: ServiceUsage?) -> ServiceUsage? { incoming ?? previous }
    /// This Mac's own Paseo wins; the sharing Mac's value fills in only where this Mac has nothing current.
    static func label(local: ServiceUsage?, relayed: ServiceUsage?, now: Date = Date()) -> String {
        let own = local?.label(now: now) ?? "—"
        return own != "—" ? own : relayed?.label(now: now) ?? "—"
    }
}

/// Usage read by the Mac that runs Paseo, sent over the conversation relay. Times are seconds since 1970.
struct RelayUsage: Codable, Equatable {
    struct Window: Codable, Equatable { var weekly: Bool; var used: Double; var reset: Double? }
    struct Service: Codable, Equatable { var observed: Double; var windows: [Window] }
    var codex: Service?, claude: Service?

    init(codex: ServiceUsage?, claude: ServiceUsage?) {
        func service(_ usage: ServiceUsage?) -> Service? {
            usage.map { Service(observed: $0.observedAt.timeIntervalSince1970,
                                windows: $0.windows.map { Window(weekly: $0.weekly, used: $0.usedPercent, reset: $0.resetAt?.timeIntervalSince1970) }) }
        }
        self.codex = service(codex); self.claude = service(claude)
    }
    /// Values from the wire are checked again; anything malformed is treated as unknown.
    var services: (codex: ServiceUsage?, claude: ServiceUsage?) {
        func usage(_ service: Service?) -> ServiceUsage? {
            guard let service, service.observed.isFinite, service.windows.count <= 8 else { return nil }
            let windows = service.windows.compactMap { window -> UsageWindow? in
                guard window.used.isFinite, (0...100).contains(window.used), window.reset?.isFinite ?? true else { return nil }
                return UsageWindow(weekly: window.weekly, usedPercent: window.used, resetAt: window.reset.map(Date.init(timeIntervalSince1970:)))
            }
            return ServiceUsage(observedAt: Date(timeIntervalSince1970: service.observed), maxAge: 3600, windows: windows)
        }
        return (usage(codex), usage(claude))
    }
}
