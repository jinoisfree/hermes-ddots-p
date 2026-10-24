import Foundation

/// Retains tool call IDs, expiry times and observed target-window metadata only.
struct ComputerUseActivity {
    private var pending: [String: Date] = [:]
    private var lingerUntil = Date.distantPast
    private(set) var target: ScreenTarget?
    private var targetCallStartedAt = Date.distantPast

    static func isScreenTool(_ name: String) -> Bool {
        ["mcp__cua_repl.js", "mcp__cua_repl__js", "computer", "computer_use",
         "mcp__computer__computer", "mcp__computer.computer"].contains(name) || name.hasPrefix("mcp__computer_use__") || name.hasPrefix("mcp__computer_use.")
    }

    mutating func start(name: String, id: String, at date: Date) {
        guard Self.isScreenTool(name), !id.isEmpty, date.timeIntervalSinceNow < 60 else { return }
        pending = pending.filter { $0.value > date }
        guard pending.count < 32 else { return }
        pending[String(id.prefix(200))] = date.addingTimeInterval(60)
    }

    mutating func finish(id: String, at date: Date, output: Any? = nil) {
        guard let expiry = pending.removeValue(forKey: String(id.prefix(200))) else { return }
        let started = expiry.addingTimeInterval(-60)
        if started >= targetCallStartedAt {
            switch ScreenTarget.observation(from: output) {
            case .known(let observed): target = observed; targetCallStartedAt = started
            case .ambiguous: target = nil; targetCallStartedAt = started
            case .absent: break // Incremental observations may omit the unchanged window header.
            }
        }
        lingerUntil = max(lingerUntil, date.addingTimeInterval(3))
    }

    mutating func reset() {
        pending.removeAll(); lingerUntil = .distantPast; target = nil; targetCallStartedAt = .distantPast
    }
    func expiresAt(now: Date) -> Date? {
        let expiry = max(pending.values.max() ?? .distantPast, lingerUntil)
        return expiry > now ? expiry : nil
    }
}
