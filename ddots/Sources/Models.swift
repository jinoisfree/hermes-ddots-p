import Foundation

enum Provider: String, Codable, CaseIterable {
    case codex, claude, other
    var name: String { self == .codex ? "Codex" : self == .claude ? "Claude Code" : "외부 AI" }
}

enum WorkState: String, Codable {
    case idle, running, waiting, responded, failed, interrupted, unknown
    var label: String {
        switch self {
        case .idle: return "대기"
        case .running: return "작업 중"
        case .waiting: return "확인 필요"
        case .responded: return "응답 종료"
        case .failed: return "오류"
        case .interrupted: return "중단됨"
        case .unknown: return "상태 확인 필요"
        }
    }
    var rank: Int {
        switch self {
        case .waiting: return 6
        case .failed: return 5
        case .running: return 4
        case .responded: return 3
        case .interrupted: return 2
        case .unknown: return 1
        case .idle: return 0
        }
    }
    var row: Int {
        switch self {
        case .running: return 7
        case .waiting: return 6
        case .responded: return 3
        case .failed: return 5
        default: return 0
        }
    }
}

struct WorkItem: Codable, Identifiable, Equatable {
    var provider: Provider
    var sessionID: String
    var turnID: String
    var project: String
    var state: WorkState
    var updatedAt: Date
    var source: String
    var event: String
    var id: String { "\(provider.rawValue):\(sessionID)" }
    var shortID: String { String(sessionID.prefix(8)) }
    func effective(at now: Date) -> WorkItem {
        var result = self
        if (state == .running || state == .waiting) && now.timeIntervalSince(updatedAt) > 300 {
            result.state = .unknown
        }
        return result
    }
}

struct ConnectionInfo: Codable, Identifiable, Equatable {
    var provider: Provider
    var available: Bool
    var fileCount: Int
    var detail: String
    var id: String { provider.rawValue }
}

enum PetTaskSummary {
    static func runningHeadline(_ tasks: [WorkItem]) -> String? {
        let running = tasks.filter { $0.state == .running }
        guard running.count > 1 else { return nil }
        let providers = Provider.allCases.filter { provider in running.contains { $0.provider == provider } }
        let names = providers.map(\.name).joined(separator: " · ")
        return providers.count > 1 ? "\(names) · 작업 중" : "\(names) · \(running.count)개 작업 중"
    }

    static func runningDetail(_ tasks: [WorkItem]) -> String {
        Provider.allCases.compactMap { provider -> String? in
            let count = tasks.filter { $0.state == .running && $0.provider == provider }.count
            return count > 0 ? "\(provider.name) \(count)" : nil
        }.joined(separator: " · ")
    }
}

struct Snapshot: Codable {
    var observedAt: Date
    var tasks: [WorkItem]
    var connections: [ConnectionInfo]
    var warning: String?
    var screenUseUntil: Date? = nil
    var screenFocus: ScreenFocus? = nil
}

enum Dates {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let plain = ISO8601DateFormatter()
    static func parse(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}
