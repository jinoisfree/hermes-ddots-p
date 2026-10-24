import AppKit

extension AppDelegate {
    func verifyComposerScroll(destination: URL) {
        Task { @MainActor [self] in
            func settle(_ milliseconds: UInt64 = 350) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
            smokeCheck(isSmoke && !slack.persists && slack.connected, "Composer checks use synthetic Slack and iMessage")
            let long = (1...120).map { "\($0)번째 줄 · 긴 입력 글의 처음부터 끝까지 확인합니다." }.joined(separator: "\n")
            var sent = 0
            chat.onSend = { _ in sent += 1 }
            slack.model.onSend = { _, _, _, _ in sent += 1 }
            slack.model.select("CTRUTH")
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
            var report = ""
            for source in IMessageFeature.enabled ? [ChatSource.imessage, .slack] : [.slack] {
                slack.model.source = source
                await settle()
                if source == .imessage { chat.draft = long; chat.focusDraftRevision += 1 }
                else { slack.model.draft = long; slack.model.focusRevision += 1 }
                await settle(600)
                guard let editor = panel.firstResponder as? DraftTextView, let scroll = editor.enclosingScrollView else {
                    smokeFailed("Long draft has a focused native scrollable editor: \(String(describing: panel.firstResponder))")
                }
                let conversation = source == .imessage ? chat.scrollView : slack.model.scrollView
                smokeCheck(editor.string == long && scroll.contentSize.height < 120 && scroll.contentSize.height >= 13, "Long draft stays within five lines")
                smokeCheck(editor.frame.height > scroll.contentSize.height * 10, "All 120 lines remain in the scrollable document")
                smokeCheck((conversation?.contentSize.height ?? 0) > 100, "Long draft leaves room for the conversation")
                let conversationOffset = conversation?.contentView.bounds.origin
                editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.scrollRangeToVisible(editor.selectedRange())
                await settle()
                smokeCheck(scroll.contentView.bounds.minY < 2, "The first line is reachable")
                func wheel(_ delta: Int32) {
                    let point = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
                    event.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
                    panel.sendEvent(NSEvent(cgEvent: event)!)
                }
                wheel(-450); await settle()
                let down = scroll.contentView.bounds.minY
                smokeCheck(down > 20, "Wheel scrolls down inside the long draft: \(down)")
                wheel(250); await settle()
                smokeCheck(scroll.contentView.bounds.minY < down, "Wheel scrolls back up inside the draft")
                smokeCheck(conversation?.contentView.bounds.origin == conversationOffset, "Draft scrolling leaves the conversation position unchanged")
                ChatView.moveCaretToEnd(in: panel); await settle()
                smokeCheck(scroll.contentView.bounds.maxY >= editor.frame.maxY - 2, "The last line and caret are reachable")
                capture(destination: destination.appendingPathComponent(source == .imessage ? "imessage-last" : "slack-last"))
                collapseChat(); await settle(500); showChat(); await settle(600)
                smokeCheck(editor.string == long && (source == .imessage ? chat.draft : slack.model.draft) == long, "Folding preserves all 120 lines")
                report += "\(source): 120 lines, viewport=\(scroll.contentSize.height), document=\(editor.frame.height), wheel-down=\(down)\n"
                if source == .imessage { chat.draft = "짧은 글" } else { slack.model.draft = "짧은 글" }
                await settle()
                smokeCheck(scroll.contentSize.height < 35, "A short draft shrinks back to one line")
                editor.insertText(" · 편집", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
                editor.breakUndoCoalescing()
                await settle()
                smokeCheck(editor.undoManager?.canUndo == true, "Typing registers undo in this editor")
                editor.undoManager?.undo(); await settle()
                smokeCheck(editor.string == "짧은 글" && (source == .imessage ? chat.draft : slack.model.draft) == "짧은 글", "Undo restores the draft binding")
                editor.undoManager?.redo(); await settle()
                smokeCheck(editor.string == "짧은 글 · 편집", "Redo restores typed text")
                if source == .imessage { chat.draft = "" } else { slack.model.draft = "" }
                await settle()
                smokeCheck(editor.string.isEmpty && editor.undoManager?.canUndo == false && editor.undoManager?.canRedo == false,
                           "Replacing a draft clears obsolete undo ranges after send or room change")
            }
            smokeCheck(sent == 0, "Scrolling and folding never send a message")
            try! report.write(to: destination.appendingPathComponent("composer-scroll.txt"), atomically: true, encoding: .utf8)
            print("PASS: enabled composers, wheel in both directions, first/last lines, bounded height and preserved conversation/draft")
            NSApp.terminate(nil)
        }
    }
}
