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
            if let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-publish-scale"), index + 1 < CommandLine.arguments.count {
                await verifyScaledPublishStreaming(destination: destination, scaleURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                return
            }
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
                // TextKit substitutes a Korean fallback font without the fixed-pitch trait.
                // The fixture, rather than the resolved font trait, identifies the code span.
                let codeRange = (rendered.string as NSString).range(of: "실제 코드")
                check(codeRange.location != NSNotFound, "inline code remains in rendered text")
                rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
                    if rendered.attributedSubstring(from: range).string != "\u{200B}",
                       let font = value as? NSFont {
                        let expected = NSIntersectionRange(range, codeRange).length > 0 ? ChatMetrics.bodyFont - 1 : ChatMetrics.bodyFont
                        if abs(font.pointSize - expected) > 0.01 {
                            print("stream font mismatch: \(font.fontName) size=\(font.pointSize) expected=\(expected) text=\(rendered.attributedSubstring(from: range).string.debugDescription)")
                            uniform = false
                        }
                    }
                }
                check(uniform, "streaming body uses selected size and code uses one point less")
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
            // The end point is the final Slack message as it will stay. Writing, the final arrival and the
            // last controls must reach it as one continuous motion: no frame moves the page back down or leaps.
            chat.receiveStreams([])
            // Measure as a window the reader is watching: background timer coalescing would hide or invent gaps.
            let watching = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "streaming motion smoke")
            defer { ProcessInfo.processInfo.endActivity(watching) }
            let writer = ChatMessage(id: "synthetic-final-writer", fromUser: false, speaker: "개인비서", body: "◐ 생각 중...",
                                     date: Date(timeIntervalSince1970: now - 1), profile: "personal-secretary")
            thread.replies = [writer]; thread.replyCount = 1
            chat.threads = Array(threads.dropLast()) + [thread]
            // The request's own delayed retries finish within 0.45s, as a sent message's do long before its answer.
            chat.requestScroll("slack-bottom"); await settle(); await settle()
            let lines = (1...36).map { "\($0). 최종 메시지까지 부드럽게 이어지는 합성 문장입니다. [자료 \($0)](https://example.com/\($0))" }
            let streamed = "## 최근 메일\n\n" + lines.joined(separator: "\n")
            // Slack's record of the same answer, read the way the chat reads every Slack message.
            let final = SlackText.display("*최근 메일*\n\n" + (1...36).map { "\($0). 최종 메시지까지 부드럽게 이어지는 합성 문장입니다. <https://example.com/\($0)|자료 \($0)>" }.joined(separator: "\n"), users: [:])
            var tail = preview; tail.id = "final-motion"; tail.status = nil; tail.input_id = nil; tail.done = false
            tail.execution = "claude-opus-5-5 · 답변 수신 중"
            var positions: [CGFloat] = []
            var times: [TimeInterval] = []
            var marks: [String] = []
            func mark(_ name: String) { marks.append("\(positions.count):\(name)") }
            func sample() {
                guard let scroll = chat.scrollView, let frame = chat.rowFrame(thread.id) else { return }
                positions.append(frame.minY - scroll.contentView.bounds.minY); times.append(ProcessInfo.processInfo.systemUptime)
            }
            func frames(_ count: Int) async { for _ in 0..<count { try? await Task.sleep(nanoseconds: 16_666_667); sample() } }
            let characters = Array(streamed)
            var sent = 0
            while sent < characters.count {
                sent = min(characters.count, sent + 45)
                tail.body = String(characters.prefix(sent)); tail.updated = Date().timeIntervalSince1970; tail.expires = tail.updated + 120
                chat.receiveStreams([tail]); await frames(6)
            }
            tail.body = streamed; tail.done = true; tail.updated = Date().timeIntervalSince1970; tail.expires = tail.updated + 30
            mark("done-preview"); chat.receiveStreams([tail]); await frames(12)
            /// The written reply's body height as laid out, and the height its final text needs.
            func bodyHeights() -> (placed: CGFloat, needed: CGFloat)? {
                func card(_ view: NSView) -> NativeThreadCard? {
                    if let found = view as? NativeThreadCard, found.value?.placed.contains(where: { if case .post(let p) = $0.piece { return p.id == writer.id }; return false }) == true { return found }
                    return view.subviews.lazy.compactMap(card).first
                }
                guard let found = card(pet), let placed = found.value?.placed.first(where: { if case .post(let p) = $0.piece { return p.id == writer.id }; return false }),
                      case .post(let post) = placed.piece else { return nil }
                return (placed.text.height, NativeThreadCard.textSize(post.text, width: placed.text.width).height)
            }
            mark("slack-final")
            thread.replies[0].body = final; thread.replies[0].hermesButtons = ["확인"]
            chat.threads = Array(threads.dropLast()) + [thread]
            await frames(30)
            mark("preview-removed"); chat.receiveStreams([]); await frames(150); await frames(50)
            try? (marks.joined(separator: " ") + "\n" + positions.map { String(format: "%.1f", $0) }.joined(separator: " ") + "\n" + times.map { String(format: "%.4f", $0) }.joined(separator: " ")).write(to: destination.appendingPathComponent("final-motion.txt"), atomically: true, encoding: .utf8)
            let settledReply = chat.renderedThreads.last?.thread.replies.first
            check(settledReply?.streaming == false && settledReply?.body == final, "final message is the settled end point")
            let steps = zip(positions.dropFirst(), positions).map { $0 - $1 }
            // Only the final message's own shorter height may ease the page down, a few points a frame.
            let backward = steps.filter { $0 > 8 }
            let leap = steps.map { -$0 }.max() ?? 0
            print("final motion: frames=\(positions.count) backward=\(backward.count) maxBack=\(backward.max() ?? 0) maxLeap=\(leap)")
            check(positions.count > 100, "final motion was sampled")
            check(self.chat.expandedReplies.contains(writer.id), "a reply written in front of the reader stays open at its end point")
            check(backward.isEmpty, "page never moves back down on the way to the final message (\(backward))")
            check(leap < 40, "page never leaps on the way to the final message (largest step \(leap))")
            if let place = chat.place() { check(place.fromBottom < 2, "end point rests at the newest line (distance: \(place.fromBottom))") }
            if let heights = bodyHeights() {
                check(abs(heights.placed - heights.needed) <= 1, "final message keeps no blank space from streaming (\(heights.placed) vs \(heights.needed))")
            } else { check(false, "final message body is measured") }
            capture(destination: destination.appendingPathComponent("final-settled"))
            print("Streaming UI smoke passed")
            NSApp.terminate(nil)
        }
    }
}
