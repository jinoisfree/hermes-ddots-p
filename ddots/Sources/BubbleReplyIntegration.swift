import AppKit

extension AppDelegate {
    /// The bubble's input sends through the conversation's own path and puts its words back when that fails.
    func prepareBubbleReply() {
        pet.installBubbleReply(bubbleReply)
        bubbleReply.onGeometry = { [weak self] in
            guard let self else { return }
            self.pet.updateBubbleReplyPresentation(); self.updateClipboardGeometry()
        }
        bubbleReply.onSend = { [weak self] target, words in self?.slack.sendReply(words, to: target.thread) ?? false }
        slack.onSendFailed = { [weak self] thread, _, reason in self?.bubbleReply.restore(reason, thread: thread) }
    }
    var bubbleReplyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: BubbleReply.settingsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: BubbleReply.settingsKey) }
    }
    /// Called at the end of every pet update with the thread the bubble now speaks to (nil when it speaks to none).
    func applyBubbleReply(_ target: BubbleReplyTarget?) {
        var mark = slack.model.interruption
        if mark.thread != nil {
            let writing = Set(slack.model.typing.filter { !$0.value.isEmpty }.map(\.key))
            mark.settle(writing: writing, answered: mark.thread.flatMap { slack.latestAgentLine(in: $0) })
            if mark != slack.model.interruption { slack.model.interruption = mark }
        }
        pet.bubbleReplyAllowed = bubbleReplyEnabled && slack.connected
        pet.subtitleInterrupted = target.map { $0.working && slack.model.interruption.active(in: $0.thread) } ?? false
        let resolved = isPreview || model.paused ? nil : target
        if bubbleReply.target != resolved { bubbleReply.aim(resolved) }
    }
    @objc func toggleBubbleReply(_ sender: NSButton) {
        bubbleReplyEnabled = sender.state == .on
    }
}
