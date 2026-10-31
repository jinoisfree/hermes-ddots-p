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
            let spinner = ChatMessage(id: "synthetic-spinner", fromUser: false, speaker: "개인비서", body: "◐ 생각 중...", date: Date(timeIntervalSince1970: now - 3), profile: "personal-secretary")
            thread.replies = [spinner]; thread.replyCount = 1
            chat.threads = Array(threads.dropLast()) + [thread]
            chat.requestScroll("slack-bottom")
            await settle()
            var preview = StreamPreview(id: "smoke", room: thread.room, thread: thread.ts, since: now - 2, updated: now, expires: now + 120,
                                        body: "첫 줄부터 표시합니다.", done: false, profile: "personal-secretary")
            preview.status = "working"; preview.body = "이메일 도구를 확인하고 있습니다"
            preview.execution = "gmail_direct · read · 실행 중"
            chat.receiveStreams([preview]); await settle()
            check(chat.renderedThreads.last?.thread.replies.last?.body.contains("이메일 도구") == true,
                  "real tool activity replaces empty typing dots")
            check(chat.executionStatus(thread) == preview.execution, "real execution event reaches shimmer status")
            let beforeStatus = chat.renderedThreads.last?.revision
            preview.execution = "gmail_direct · list · 실행 중"
            chat.receiveStreams([preview]); await settle()
            check(chat.renderedThreads.last?.revision != beforeStatus, "execution-only update invalidates retained row")
            capture(destination: destination.appendingPathComponent("tool-activity"))
            preview.status = nil; preview.body = "첫 줄부터 표시합니다."
            preview.execution = "claude-opus-5-5 · 답변 수신 중"
            chat.receiveStreams([preview]); await settle()
            check(chat.renderedThreads.last?.thread.replies.last?.body == preview.body, "first text appears before completion")
            check(chat.threads.last?.replies.last?.body == spinner.body, "Slack record stays authoritative")
            check(chat.renderedThreads.last?.thread.replies.count == 1, "spinner preceding lease is replaced without duplication")
            let stableID = chat.renderedThreads.last?.thread.replies.last?.id
            check(stableID == spinner.id, "preview reuses original Slack message identity")
            for i in 1...5 {
                preview.body += "\n합성 스트리밍 문장 \(i) — 한글을 끊김 없이 이어서 표시합니다."
                chat.receiveStreams([preview]); await settle()
                check(chat.renderedThreads.last?.thread.replies.last?.id == stableID, "one stable message through chunk \(i)")
            }
            check(chat.scrollView != nil, "real chat scroll view is mounted")
            if let place = chat.place() { check(place.fromBottom < 30, "bottom follows growing text (distance: \(place.fromBottom))") }
            preview.body = "## 오늘 일정\n**회의 안내**\n\n| 시간 | 일정 |\n| --- | --- |\n| 16:00 | 업무 회의 |\n\n- 확인할 내용\n`실제 코드`는 코드 서식을 유지합니다."
            chat.receiveStreams([preview]); await settle()
            func renderedText(_ view: NSView) -> NSAttributedString? {
                if let text = view as? NativeThreadCard.Text, text.string.contains("회의 안내") { return text.textStorage }
                return view.subviews.lazy.compactMap(renderedText).first
            }
            if let rendered = renderedText(pet) {
                check(rendered.string.contains("회의 안내") && !rendered.string.contains("**") && !rendered.string.contains("##"), "streaming headings and emphasis are formatted")
                var uniform = true
                rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
                    if rendered.attributedSubstring(from: range).string != "\u{200B}",
                       let font = value as? NSFont, abs(font.pointSize - ChatMetrics.bodyFont) > 0.01 { uniform = false }
                }
                check(uniform, "streaming headings and body use one font size")
                var hasTable = false
                rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                    if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { hasTable = true }
                }
                check(hasTable, "streaming table uses native table cells")
            } else { check(false, "streaming rich body is rendered in the real chat") }
            func streamingHeight(_ view: NSView) -> CGFloat? {
                if let card = view as? NativeThreadCard, let placed = card.value?.placed.first(where: {
                    if case .post(let post) = $0.piece { return post.id == stableID }; return false
                }) { return placed.text.height }
                return view.subviews.lazy.compactMap(streamingHeight).first
            }
            let beforeCorrection = streamingHeight(pet)
            preview.body += "["; chat.receiveStreams([preview]); await settle()
            preview.body.removeLast(); chat.receiveStreams([preview])
            check(chat.renderedThreads.last?.thread.replies.last?.body == preview.body, "filtered suffix does not erase the visible answer")
            await settle()
            if let beforeCorrection, let afterCorrection = streamingHeight(pet) {
                check(afterCorrection >= beforeCorrection, "streaming body height does not contract on suffix correction")
            } else { check(false, "streaming height is measured in the mounted card") }
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
            // A final Slack update arriving during a burst must not flash the full answer.
            var burst = preview; burst.id = "burst"; burst.status = nil
            burst.body = String(repeating: "부드럽게 나타나는 합성 답변입니다.\n", count: 30)
            thread.replies = [spinner]
            chat.threads = Array(threads.dropLast()) + [thread]
            chat.receiveStreams([burst])
            thread.replies[0].body = burst.body
            chat.threads = Array(threads.dropLast()) + [thread]
            await settle()
            let during = chat.renderedThreads.last?.thread.replies[0]
            check(during?.id == spinner.id && during?.streaming == true, "final arrival keeps one revealing message")
            check((during?.body.count ?? 0) < burst.body.count, "burst is still partial after 350ms")
            check(chat.threads.last?.replies[0].body == burst.body, "final record is immediately available unchanged")
            capture(destination: destination.appendingPathComponent("burst-partial"))
            chat.receiveStreams([])
            try? await Task.sleep(nanoseconds: 3_100_000_000)
            check(chat.renderedThreads.last?.thread.replies[0].body == burst.body, "final reveal completes despite preview removal")
            check(chat.renderedThreads.last?.thread.replies[0].streaming == false, "final rendering restored after bounded reveal")
            print("Streaming UI smoke passed")
            NSApp.terminate(nil)
        }
    }
}
