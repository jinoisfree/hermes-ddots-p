import AppKit

extension AppDelegate {
    func verifyStreaming(destination: URL) {
        Task { @MainActor [self] in
            func settle() async { try? await Task.sleep(nanoseconds: 350_000_000) }
            func check(_ ok: Bool, _ label: String) {
                guard ok else { fputs("FAIL streaming: \(label)\n", stderr); exit(1) }
                print("PASS streaming: \(label)")
            }
            await ensureDdotsSmoke(destination: destination)
            await settle()
            let chat = slack.model
            let now = Date().timeIntervalSince1970
            let threads = (0..<24).map { i -> SlackThread in
                let ts = String(now - 500 + Double(i))
                let message = ChatMessage(id: "synthetic-\(i)", fromUser: true, speaker: "사용자", body: "합성 대화 \(i)", date: Date(timeIntervalSince1970: now - 500 + Double(i)), profile: "me")
                return SlackThread(id: "CHUB:" + ts, room: "CHUB", ts: ts, root: message, replies: [], replyCount: 0, loaded: true, latest: message.date.timeIntervalSince1970, latestFromUser: true)
            }
            var thread = threads.last!
            let spinner = ChatMessage(id: "synthetic-spinner", fromUser: false, speaker: "개인비서", body: "◐ 생각 중...", date: Date(timeIntervalSince1970: now - 1), profile: "personal-secretary")
            thread.replies = [spinner]; thread.replyCount = 1
            chat.threads = Array(threads.dropLast()) + [thread]
            chat.requestScroll("slack-bottom")
            await settle()
            var preview = StreamPreview(id: "smoke", room: thread.room, thread: thread.ts, since: now - 2, updated: now, expires: now + 120,
                                        body: "첫 줄부터 표시합니다.", done: false, profile: "personal-secretary")
            chat.receiveStreams([preview]); await settle()
            check(chat.renderedThreads.last?.thread.replies.last?.body == preview.body, "first text appears before completion")
            check(chat.threads.last?.replies.last?.body == spinner.body, "Slack record stays authoritative")
            let stableID = chat.renderedThreads.last?.thread.replies.last?.id
            for i in 1...5 {
                preview.body += "\n합성 스트리밍 문장 \(i) — 한글을 끊김 없이 이어서 표시합니다."
                chat.receiveStreams([preview]); await settle()
                check(chat.renderedThreads.last?.thread.replies.last?.id == stableID, "one stable message through chunk \(i)")
            }
            check(chat.scrollView != nil, "real chat scroll view is mounted")
            if let place = chat.place() { check(place.fromBottom < 30, "bottom follows growing text") }
            capture(destination: destination.appendingPathComponent("streaming"))
            if let scroll = chat.scrollView {
                chat.userScrolls += 1
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
                let y = scroll.contentView.bounds.minY
                preview.body += "\n사용자가 위로 스크롤하면 그 자리를 유지합니다."
                chat.receiveStreams([preview]); await settle()
                check(abs(scroll.contentView.bounds.minY - y) < 2, "manual scroll is preserved")
            }
            preview.status = "waiting"; preview.input_id = "synthetic-followup"
            chat.receiveStreams([preview]); await settle()
            check(chat.renderedThreads.last?.thread.replies.last?.body.hasPrefix("추가 지시 반영 대기") == true, "accepted input waits for tools")
            preview.status = "applying"; preview.body = "추가 지시를 반영한 새 답변"
            chat.receiveStreams([preview]); await settle()
            check(chat.renderedThreads.last?.thread.replies.last?.id == stableID, "correction preserves message identity")
            check(chat.renderedThreads.last?.thread.replies.last?.body == preview.displayedBody, "new generation replaces old text with server status")
            thread.replies[0].body = "확정된 최종 답변"; thread.replies[0].hermesButtons = ["확인"]
            chat.threads = Array(threads.dropLast()) + [thread]
            await settle()
            check(chat.renderedThreads.last?.thread.replies.count == 1, "final message is not duplicated")
            check(chat.renderedThreads.last?.thread.replies[0].hermesButtons == ["확인"], "final controls are preserved")
            check(chat.renderedThreads.last?.thread.replies[0].streaming == false, "final replaces transient rendering")
            chat.receiveStreams([])
            print("Streaming UI smoke passed")
            NSApp.terminate(nil)
        }
    }
}
