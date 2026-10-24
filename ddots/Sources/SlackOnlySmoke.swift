import AppKit

extension AppDelegate {
    func recordDisabledIMessageChecks(destination: URL) {
        guard !IMessageFeature.enabled else { return }
        let note = """
        Disabled iMessage UI checks (underlying ConversationTests are retained):
        - ChatSmoke/ChatInteractionSmoke: photon history/search/paging, iMessage composer/typing/avatar nudges; --ui-smoke-chat runs the full Slack checks instead.
        - SlackSetup: switching to the iMessage width and restoring its keyboard.
        - ComposerScrollSmoke/FormatSmoke: iMessage pass only; Slack passes are retained.
        - ComposerSmoke: iMessage attachment rejection only; all Slack paste/drop checks are retained.
        - ResponseSmoke/SlackEntrySmoke: iMessage tab switch; Slack room re-entry is retained.
        - StabilitySmoke: delayed iMessage search/older/around; delayed poll and lifecycle checks are retained.
        - CalendarSmoke: iMessage calendar buttons.
        - ChatPerformanceSmoke: iMessage arrival/typing samples; Slack samples are retained.
        """
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? (note + "\n").write(to: destination.appendingPathComponent("imessage-skipped.txt"), atomically: true, encoding: .utf8)
    }

    func verifySlackOnlyChat(destination: URL) {
        smokeCheck(!IMessageFeature.enabled && slack.model.source == .slack, "Chat opens on Slack with iMessage disabled")
        slack.model.source = .imessage
        smokeCheck(slack.model.source == .slack, "The disabled source cannot be selected")
        var result = HermesBridge.PollResult(status: .connected(stores: 1), messages: [ChatMessage(id: "disabled-message", fromUser: false, speaker: "위키담당", body: "숨길 합성 글", date: Date())])
        result.characters = chat.characters; result.avatars = chat.avatars
        result.typing = [TypingIndicator(id: "disabled-typing", speaker: "위키담당")]
        chat.needsAutomation = true
        applyChat(result)
        smokeCheck(chat.messages.isEmpty && storedMessages.isEmpty && chat.typing.isEmpty, "Hermes supplies characters without iMessage content")
        smokeCheck(!chat.canSend && !chat.needsAutomation && chat.notice == nil && chat.scrollView == nil, "The iMessage pane and automation prompt are absent")
        smokeCheck(!nudgeMessages.contains { $0.id == "disabled-message" }, "An iMessage cannot enter pet nudges")
        chat.openSearch(); searchChat("숨길 합성 글")
        smokeCheck(!chat.searchOpen && chat.results.isEmpty, "iMessage search is disabled")
        sendChat("보내지 않는 합성 글")
        smokeCheck(!chat.sending && pendingMessages.isEmpty, "The iMessage send path is disabled")
        try? "PASS: Slack-only source, hidden iMessage pane, character-only results, no iMessage nudges/search/send/automation\n"
            .write(to: destination.appendingPathComponent("slack-only.txt"), atomically: true, encoding: .utf8)
        verifySlack(destination: destination)
    }
}
