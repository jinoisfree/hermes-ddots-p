import Foundation

/// Tracks protocol states only. Notifications are once per state, per Mac, for 48 hours.
final class FileDropWatch {
    struct Notice {
        var assignment: String
        var thread: SlackThread
        var profile: String
        var label: String
        var state: HermesReplyState
        var at = Date().timeIntervalSince1970
    }
    var assignments: [FileDropAssignment] = []
    var notices: [Notice] = []
    var device = "local"
    var onChange: (() -> Void)?
    func update(_ threads: [SlackThread], now: Double = Date().timeIntervalSince1970) {
        var changed = false
        let count = assignments.count
        assignments.removeAll { now - $0.at > 48 * 3600 }
        changed = count != assignments.count
        notices.removeAll { now - $0.at > 48 * 3600 }
        for index in assignments.indices {
            let entry = assignments[index]
            guard let thread = threads.first(where: { thread in
                thread.room == entry.room && (entry.ts == thread.ts || entry.ts == nil && !entry.files.isEmpty && !Set(thread.root.files.map(\.id)).isDisjoint(with: entry.files))
            }) else { continue }
            if assignments[index].ts == nil { assignments[index].ts = thread.ts; changed = true }
            let latest = thread.messages.last { !$0.fromUser }
            guard let state = latest?.effectiveHermesReplyState ?? SlackNotice.hermesState(thread), state != .working else { continue }
            let key = device + ":" + state.rawValue
            guard !assignments[index].seen.contains(key) else { continue }
            assignments[index].seen.insert(key); assignments[index].outcome = state.rawValue
            notices.append(Notice(assignment: entry.id, thread: thread, profile: entry.profile, label: entry.label, state: state, at: entry.at)); changed = true
        }
        if changed { onChange?() }
    }
}
