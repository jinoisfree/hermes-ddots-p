import AppKit

extension AppDelegate {
    /// Local synthetic actions only. Never invokes a Slack API send or the user's message bridge.
    func verifyResponses(destination: URL) {
        Task { @MainActor [self] in
            let model = slack.model
            func settle() async { try? await Task.sleep(nanoseconds: 800_000_000) }
            smokeCheck(!slack.persists && isSmoke, "Response measurement uses synthetic Slack")
            StallTrace.writer.sync {}
            try? FileManager.default.removeItem(at: destination.appendingPathComponent("stall-log.txt"))
            let page = destination.appendingPathComponent("response-page.html")
            try? "<html><body style='background:#19ad38'>Synthetic response page</body></html>".write(to: page, atomically: true, encoding: .utf8)
            for _ in 0..<3 {
                model.select("CTRUTH"); await settle()
                model.select("CCOW"); await settle()
                if IMessageFeature.enabled { model.source = .imessage; await settle() }
                model.source = .slack; await settle()
                guard let thread = model.threads.first(where: { $0.loaded && $0.replyCount > 0 }) else { smokeFailed("Response fixture needs a loaded thread") }
                model.foldAll(animated: false); await settle()
                model.toggle(thread); await settle()
                smokeCheck(model.open.contains(thread.id), "Measured thread opens")
                model.toggle(thread); await settle()
                smokeCheck(!model.open.contains(thread.id), "Measured thread closes")
                if model.stackOpen { model.toggleStack(); await settle() }
                model.toggleStack(); await settle()
                model.toggleStack(); await settle()
                model.writeNewPost()
                let saved = model.onSend
                var sent = false
                model.onSend = { [self] text, room, thread, _ in
                    let echo = ChatMessage(id: "slack-pending:\(UUID().uuidString)", fromUser: true, speaker: "", body: text, date: Date(), pending: true, profile: "")
                    slack.addEcho(room: room, thread: thread?.ts, message: echo)
                    slack.publish(); model.didPublishEcho(); sent = true
                }
                model.draft = "Synthetic local echo"; model.send(); model.onSend = saved
                smokeCheck(sent, "Measured send publishes a local echo only")
                await settle()
                toggleChatWidth(); await settle()
                toggleChatWidth(); await settle()
                web.open(page); await settle()
                web.close(); await settle()
            }
            await settle()
            StallTrace.writer.sync {}
            let text = (try? String(contentsOf: destination.appendingPathComponent("stall-log.txt"), encoding: .utf8)) ?? ""
            let rows = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            for action in ["roomSelect", "sourceTab", "threadOpen", "threadClose", "listOpen", "listClose", "sendEcho", "headerWidth", "webOpen", "webClose"] {
                smokeCheck(rows.filter { $0["kind"] as? String == "response" && $0["name"] as? String == action }.count >= 3, "Three response samples for \(action)")
            }
            NSApp.terminate(nil)
        }
    }
}
