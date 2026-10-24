import Foundation

/// Stopping a character's run from its thread, and afterwards asking it to put back what it had already changed.
/// Hermes stops only runs of the thread the command is posted in; outside changes cannot be undone automatically,
/// so the character is asked to list them first and to change nothing before the user agrees.
enum AgentStop {
    /// Slack keeps slash commands out of threads; Hermes reads a known leading "!" command as "/".
    static let command = "!stop"
    static let undoRequest = "방금 중지한 작업에서 이미 바꾼 것(메모·미리알림·파일·Notion·NAS·보낸 메시지 등)을 목록으로 먼저 보여 줘. 내가 확인하면 원래대로 되돌려 줘. 확인 전에는 아무것도 바꾸지 마."

    /// A character is writing in the thread: its typing mark, or its "생각 중" line still standing.
    static func working(_ thread: SlackThread, typing: [TypingIndicator]) -> Bool {
        !typing.isEmpty || thread.messages.contains { !$0.fromUser && SlackText.isThinking($0.body) }
    }

    enum Control: Equatable { case stop, undo }
    /// After a stop the thread offers the undo request until it is sent or the user writes there again.
    static func control(working: Bool, stopped: Bool) -> Control? {
        stopped ? .undo : working ? .stop : nil
    }
}
