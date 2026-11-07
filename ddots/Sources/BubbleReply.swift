import Foundation

/// The thread a pet bubble is about. Answering from the bubble goes to it.
struct BubbleReplyTarget: Equatable {
    /// `SlackThread.id`
    var thread: String
    var room: String
    var speaker: String
    var profile: String
    /// The agent is writing in this thread right now.
    var working: Bool
    /// The agent reads a new line only after it has finished (Hermes `busy_input_mode: queue`).
    var queued: Bool
}

/// Words and rules of answering from the bubble. Pure: nothing here touches a window or Slack.
enum BubbleReply {
    static let settingsKey = "bubbleReplyEnabled"
    /// How long the pointer stays on a bubble before its input opens, and how long after leaving an empty one folds.
    static let dwell: TimeInterval = 0.3
    static let foldDelay: TimeInterval = 0.6
    static let maximumLines = 3
    static let interruptedSubtitle = "끼어들었어요 · 다시 생각하는 중"
    static let interruptedCaption = "끼어들었어요"
    static let accessibilityName = "말풍선 답하기"
    static let sendName = "보내기"

    static func placeholder(_ target: BubbleReplyTarget) -> String {
        let name = target.speaker.isEmpty ? "에이전트" : target.speaker
        if target.working { return target.queued ? "답이 끝나면 이어서 읽어요" : name + "에게 끼어들기…" }
        return name + "에게 답하기…"
    }

    /// What goes to Slack, or nil when there is nothing to send.
    static func outgoing(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `display.busy_input_mode` of one Hermes config file. Without the key Hermes steers.
    static func isQueued(config: String) -> Bool {
        var inDisplay = false
        for raw in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("display:") { inDisplay = true; continue }
            if let first = line.first, !first.isWhitespace, first != "#" { inDisplay = false; continue }
            guard inDisplay else { continue }
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("busy_input_mode:") {
                let value = body.dropFirst("busy_input_mode:".count).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                return value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'"))) == "queue"
            }
        }
        return false
    }

    /// Everything that stops the input from opening (REQ-CI-06). The bubble must also have a thread to speak to.
    struct Surroundings: Equatable {
        var enabled = true
        var connected = true
        var paused = false
        var resting = false
        var chatExpanded = false
        var fileDropActive = false
        var clipboardActive = false
        var bubbleShown = true
        var hasTarget = true
    }
    static func canOpen(_ s: Surroundings) -> Bool {
        s.enabled && s.connected && !s.paused && !s.resting && !s.chatExpanded && !s.fileDropActive && !s.clipboardActive && s.bubbleShown && s.hasTarget
    }
}

/// When the input opens and folds. The pointer opens it after a short stay; leaving folds it only when it is empty and not being typed in.
struct BubbleReplyHover {
    private(set) var open = false
    private var entered: TimeInterval?
    private var left: TimeInterval?
    private var foldAt: TimeInterval?
    /// After an explicit fold the pointer has to leave the bubble once before the input comes out again.
    private var armed = true

    /// `holds` is a draft in the field or the field being typed in.
    mutating func update(now: TimeInterval, eligible: Bool, pointerOver: Bool, holds: Bool) {
        if !pointerOver { armed = true }
        guard eligible else { open = false; entered = nil; left = nil; foldAt = nil; return }
        if open {
            if let at = foldAt, now >= at, !holds { open = false; foldAt = nil; left = nil; armed = false; return }
            if pointerOver || holds { left = nil; return }
            if left == nil { left = now }
            if now - left! >= BubbleReply.foldDelay { open = false; left = nil; foldAt = nil }
        } else {
            guard pointerOver, armed else { entered = nil; return }
            if entered == nil { entered = now }
            if now - entered! >= BubbleReply.dwell { open = true; entered = nil; left = nil; foldAt = nil }
        }
    }
    /// A deliberate open (VoiceOver, a click on the bubble's hint).
    mutating func forceOpen() { open = true; entered = nil; left = nil; foldAt = nil; armed = true }
    /// Esc: fold at once. The draft stays with the card.
    mutating func fold() { open = false; entered = nil; left = nil; foldAt = nil; armed = false }
    /// After a send: fold once the delay has passed.
    mutating func foldSoon(now: TimeInterval) { foldAt = now + BubbleReply.foldDelay }
}

/// The text typed for one thread. Folding keeps it; speaking to another thread drops it.
struct BubbleReplyDraft: Equatable {
    private(set) var thread: String?
    var text = ""
    mutating func retarget(_ id: String?) {
        guard id != thread else { return }
        thread = id; text = ""
    }
}

/// "끼어들었어요": a message was sent into a thread while its agent was writing. It ends when the agent stops writing there
/// or answers after the moment of interruption.
struct BubbleReplyInterruption: Equatable {
    private(set) var thread: String?
    private var since: Date?
    mutating func mark(thread: String, at date: Date) { self.thread = thread; since = date }
    func active(in thread: String?) -> Bool { self.thread != nil && self.thread == thread }
    /// `writing` are the threads whose agent is writing; `answered` is the newest agent line of the marked thread.
    mutating func settle(writing: Set<String>, answered: Date?) {
        guard let thread, let since else { return }
        if !writing.contains(thread) { clear(); return }
        if let answered, answered > since { clear() }
    }
    mutating func clear() { thread = nil; since = nil }
}
