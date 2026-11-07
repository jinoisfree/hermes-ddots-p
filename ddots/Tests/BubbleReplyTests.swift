import Foundation

@main
struct BubbleReplyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func target(working: Bool = false, queued: Bool = false, speaker: String = "민트") -> BubbleReplyTarget {
        BubbleReplyTarget(thread: "slack:C1:1.0", room: "C1", speaker: speaker, profile: "work-x", working: working, queued: queued)
    }
    static func main() {
        // Words (REQ-CI-02): literal expectations.
        check(BubbleReply.placeholder(target(working: true)) == "민트에게 끼어들기…", "a writing agent is interrupted")
        check(BubbleReply.placeholder(target()) == "민트에게 답하기…", "a quiet thread is answered")
        check(BubbleReply.placeholder(target(working: true, queued: true)) == "답이 끝나면 이어서 읽어요", "a queueing agent reads after it ends")
        check(BubbleReply.placeholder(target(speaker: "")) == "에이전트에게 답하기…", "no speaker falls back to a generic word")
        check(BubbleReply.outgoing("  \n ") == nil && BubbleReply.outgoing(" 안녕 \n") == "안녕", "only words are sent, trimmed")

        // Queue detection reads display.busy_input_mode only.
        check(BubbleReply.isQueued(config: "display:\n  compact: false\n  busy_input_mode: queue\n  bell: x\n"), "queue is found")
        check(!BubbleReply.isQueued(config: "display:\n  busy_input_mode: steer\n"), "steer is not queue")
        check(!BubbleReply.isQueued(config: "other:\n  busy_input_mode: queue\ndisplay:\n  compact: false\n"), "the key outside display is ignored")
        check(BubbleReply.isQueued(config: "display:\n  busy_input_mode: \"queue\"  # note\n"), "quotes and comments are tolerated")
        check(!BubbleReply.isQueued(config: ""), "an empty file steers")

        // Surroundings (REQ-CI-06): every blocker alone closes it, and a target is needed.
        let open = BubbleReply.Surroundings()
        check(BubbleReply.canOpen(open), "the default surroundings allow it")
        let blockers: [(String, (inout BubbleReply.Surroundings) -> Void)] = [
            ("setting off", { $0.enabled = false }), ("Slack off", { $0.connected = false }), ("paused", { $0.paused = true }),
            ("screen dark", { $0.resting = true }), ("chat open", { $0.chatExpanded = true }), ("file drop", { $0.fileDropActive = true }),
            ("clipboard", { $0.clipboardActive = true }), ("bubble put away", { $0.bubbleShown = false }), ("no thread", { $0.hasTarget = false })]
        for (name, apply) in blockers { var s = open; apply(&s); check(!BubbleReply.canOpen(s), "\(name) blocks the input") }

        // Hover (REQ-CI-02): opens after 0.3 s on the bubble, not before.
        var hover = BubbleReplyHover()
        hover.update(now: 10.0, eligible: true, pointerOver: true, holds: false)
        check(!hover.open, "not at the first moment")
        hover.update(now: 10.29, eligible: true, pointerOver: true, holds: false)
        check(!hover.open, "not at 0.29 s")
        hover.update(now: 10.31, eligible: true, pointerOver: true, holds: false)
        check(hover.open, "open at 0.31 s")
        // A pointer that left before 0.3 s starts over.
        hover = BubbleReplyHover()
        hover.update(now: 0, eligible: true, pointerOver: true, holds: false)
        hover.update(now: 0.2, eligible: true, pointerOver: false, holds: false)
        hover.update(now: 0.4, eligible: true, pointerOver: true, holds: false)
        hover.update(now: 0.6, eligible: true, pointerOver: true, holds: false)
        check(!hover.open, "the stay restarts after the pointer left")
        hover.update(now: 0.71, eligible: true, pointerOver: true, holds: false)
        check(hover.open, "open after a whole stay")

        // AC-CI-05: with words in the field it stays; empty folds 0.6 s after leaving.
        hover.update(now: 1.0, eligible: true, pointerOver: false, holds: true)
        hover.update(now: 5.0, eligible: true, pointerOver: false, holds: true)
        check(hover.open, "a draft keeps it open")
        hover.update(now: 5.1, eligible: true, pointerOver: false, holds: false)
        hover.update(now: 5.6, eligible: true, pointerOver: false, holds: false)
        check(hover.open, "not yet at 0.5 s")
        hover.update(now: 5.71, eligible: true, pointerOver: false, holds: false)
        check(!hover.open, "folded 0.6 s after leaving empty")
        // Coming back before it folds cancels the fold.
        hover = BubbleReplyHover(); hover.forceOpen()
        hover.update(now: 0, eligible: true, pointerOver: false, holds: false)
        hover.update(now: 0.5, eligible: true, pointerOver: true, holds: false)
        hover.update(now: 1.5, eligible: true, pointerOver: true, holds: false)
        check(hover.open, "returning keeps it open")

        // Esc folds at once and the pointer has to leave before it opens again.
        hover = BubbleReplyHover(); hover.forceOpen(); hover.fold()
        check(!hover.open, "Esc folds")
        hover.update(now: 0, eligible: true, pointerOver: true, holds: false)
        hover.update(now: 1, eligible: true, pointerOver: true, holds: false)
        check(!hover.open, "a pointer that never left does not reopen it")
        hover.update(now: 1.1, eligible: true, pointerOver: false, holds: false)
        hover.update(now: 2, eligible: true, pointerOver: true, holds: false)
        hover.update(now: 2.4, eligible: true, pointerOver: true, holds: false)
        check(hover.open, "after leaving once it opens again")

        // After a send it folds 0.6 s later, pointer or not.
        hover = BubbleReplyHover(); hover.forceOpen(); hover.foldSoon(now: 3)
        hover.update(now: 3.4, eligible: true, pointerOver: true, holds: false)
        check(hover.open, "still open at 0.4 s")
        hover.update(now: 3.61, eligible: true, pointerOver: true, holds: false)
        check(!hover.open, "folded 0.6 s after the send")

        // Not eligible closes everything at once (REQ-CI-06).
        hover = BubbleReplyHover(); hover.forceOpen()
        hover.update(now: 0, eligible: false, pointerOver: true, holds: true)
        check(!hover.open, "an ineligible bubble folds even with a draft")

        // Draft memory: kept for the same thread, dropped for another.
        var draft = BubbleReplyDraft()
        draft.retarget("a"); draft.text = "쓰던 글"
        draft.retarget("a")
        check(draft.text == "쓰던 글", "the same thread keeps the words")
        draft.retarget("b")
        check(draft.text.isEmpty && draft.thread == "b", "another thread drops them")

        // Interruption mark: lives while the agent writes, ends with a new answer or when writing stops.
        let t0 = Date(timeIntervalSince1970: 1000)
        var mark = BubbleReplyInterruption()
        mark.mark(thread: "a", at: t0)
        check(mark.active(in: "a") && !mark.active(in: "b") && !mark.active(in: nil), "the mark belongs to its thread")
        mark.settle(writing: ["a"], answered: Date(timeIntervalSince1970: 999))
        check(mark.active(in: "a"), "an older answer does not end it")
        mark.settle(writing: ["a"], answered: Date(timeIntervalSince1970: 1001))
        check(!mark.active(in: "a"), "a newer answer ends it")
        mark.mark(thread: "a", at: t0); mark.settle(writing: ["b"], answered: nil)
        check(!mark.active(in: "a"), "it ends when the agent stops writing there")
        print("BubbleReplyTests passed")
    }
}
