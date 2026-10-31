import AppKit
import SwiftUI

extension AppDelegate {
    /// Synthetic design matrix plus semantic checks; no preferences or messages are written.
    func verifyHybridChat(destination: URL) {
        Task { @MainActor [self] in
            let model = slack.model
            let savedAppearance = panel.appearance, savedOpacity = pet.chatOpacityPercent
            defer { panel.appearance = savedAppearance; pet.chatOpacityPercent = savedOpacity }
            var checks: [String] = []
            func check(_ ok: Bool, _ title: String) {
                checks.append("\(ok ? "PASS" : "FAIL"): \(title)")
                try? checks.joined(separator: "\n").write(to: destination.appendingPathComponent("hybrid-checks.txt"), atomically: true, encoding: .utf8)
                smokeCheck(ok, title)
            }
            func settle() async { try? await Task.sleep(nanoseconds: 500_000_000) }
            /// The top row: bell and badges on one centre line, 10pt apart, inside the inset, clear of the author and the words.
            @MainActor func verifyHeader(_ base: NativeThreadCard.Content, name: String) {
                var variants: [(String, NativeThreadCard.Content)] = []
                for bell in [nil, true, false] as [Bool?] {
                    for badges in 0...2 {
                        var c = base; c.bell = bell; c.replyTarget = badges >= 1; c.statusTitle = badges == 2 ? (base.statusTitle.isEmpty ? "처리 중" : base.statusTitle) : ""
                        variants.append(("bell=\(String(describing: bell)) badges=\(badges)", c))
                        if case .post(var post)? = c.top.first {
                            post.mine = true; var mine = c; mine.top[0] = .post(post)
                            variants.append(("mine bell=\(String(describing: bell)) badges=\(badges)", mine))
                        }
                    }
                }
                var failures: [String] = []
                for (label, c) in variants {
                    for width: CGFloat in [200, 260, 360, 540] {
                        let layout = NativeThreadCard.layout(c, width: width), header = layout.header, inset = c.style.inset
                        let tag = "\(name) \(label) \(Int(width))pt"
                        let frames = header.all
                        if c.bell != nil && header.bell == nil { failures.append(tag + ": bell missing") }
                        if let first = frames.first, frames.contains(where: { abs($0.midY - first.midY) > 0.5 }) { failures.append(tag + ": centres differ") }
                        if let bell = header.bell {
                            let icon = NativeThreadCard.bellIconWidth, iconLeft = bell.minX + (bell.width - icon) / 2
                            if abs(iconLeft + icon - (width - inset)) > 0.5 { failures.append(tag + ": bell not at inset") }
                            if let next = header.badges.first, abs(iconLeft - next.frame.maxX - NativeThreadCard.bellGap) > 0.5 { failures.append(tag + ": bell gap \(iconLeft - next.frame.maxX)") }
                            if bell.minY < 0 || bell.maxX > width { failures.append(tag + ": bell box outside card") }
                        }
                        for badge in header.badges where badge.frame.minX < inset - 0.5 || badge.frame.minY < 0 { failures.append(tag + ": badge outside inset") }
                        for (a, b) in zip(frames, frames.dropFirst()) where a.intersects(b) { failures.append(tag + ": header pieces overlap") }
                        let nameFont = NSFont.systemFont(ofSize: ChatMetrics.nameFont, weight: .bold)
                        for item in layout.placed {
                            var taken: [NSRect] = []
                            if case .post(let post) = item.piece {
                                taken = [item.text, item.bubble, item.aside].filter { !$0.isEmpty }
                                if !post.mine {
                                    let span = NativeThreadCard.width(post.speaker, font: nameFont) + 6 + NativeThreadCard.width(post.time, font: .systemFont(ofSize: 10))
                                    taken.append(NSRect(x: item.time.minX, y: item.time.minY, width: span, height: item.time.height))
                                } else { taken.append(item.time) }
                            } else { taken = [item.frame] }
                            for rect in taken where frames.contains(where: { $0.intersects(rect) }) { failures.append(tag + ": header overlaps \(rect)") }
                        }
                    }
                }
                check(failures.isEmpty, "Header row aligned and clear of the card, \(name): " + failures.prefix(4).joined(separator: "; "))
            }
            let room = model.selected ?? "CCOW", date = Date(timeIntervalSince1970: 1793320200)
            func message(_ id: String, _ text: String, _ who: String, mine: Bool = false, offset: Double = 0) -> ChatMessage {
                ChatMessage(id: id, fromUser: mine, speaker: mine ? "나" : who, body: text,
                            date: date.addingTimeInterval(offset), profile: who == "진단담당" ? "system-doctor" : "personal-secretary")
            }
            var root = message("hybrid-root", "오늘 회의 준비 내용이에요.\n• 회의 시간 · 오후 3시\n• 확인할 자료 · 변경 사항 2건", "개인비서")
            root.hermesReplyState = .working
            let replies = [message("hybrid-user", "바뀐 부분만 먼저 알려줘.", "나", mine: true, offset: 60),
                           message("hybrid-answer", "시작 시간이 바뀌었고, 안건이 하나 추가됐어요.", "개인비서", offset: 120)]
            func thread(_ id: String, _ root: ChatMessage, _ replies: [ChatMessage] = []) -> SlackThread {
                SlackThread(id: id, room: room, ts: id, root: root, replies: replies, replyCount: replies.count,
                            loaded: true, latest: (replies.last ?? root).date.timeIntervalSince1970, latestFromUser: false)
            }
            let active = thread("hybrid-active", root, replies)
            var done = message("hybrid-done", "시스템 점검을 마쳤어요.\n모든 연결이 정상이에요.", "진단담당")
            done.hermesReplyState = .closed
            var asking = message("hybrid-asking", "이 아이디어를 더 살펴볼까요?", "개인비서")
            asking.hermesReplyState = .asking; asking.hermesButtons = ["승인", "거절", "의견", "확인"]
            let fixtures = [active, thread("hybrid-closed", done), thread("hybrid-question", asking)]
            model.onSend = nil; model.onOpen = { _ in }; model.onOlder = nil
            // The bell only flips here; the smoke marks nothing read in Slack.
            let savedBell = model.onBell
            defer { model.onBell = savedBell }
            model.onBell = { thread in model.bells[thread.id] = !(model.bells[thread.id] ?? false) }
            model.bells = [active.id: true, "hybrid-question": false]
            model.notices = []; model.roomNotices = [:]
            model.threads = fixtures; model.typing = [:]; model.hasOlder = false
            model.open = [active.id]; model.reply(active); model.draft = ""
            let view = ChatView(model: chat, slack: model, web: web)
            for dark in [true, false] {
                panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for (i, item) in fixtures.enumerated() {
                    let inputs = model.rowInputs(model.renderedThreads[i], chat: chat, dark: dark, reduceMotion: true, target: i == 0)
                    let card = view.nativeThreadContent(item, inputs: inputs, target: i == 0)
                    let expected = DdotsConfig.shared.conversation.color(i == 0 ? "workingColor" : i == 1 ? "closedColor" : "askingColor")
                    check(card.style.status == MessageFormat.color(expected), "State rail \(i) remains \(expected), dark=\(dark)")
                    for piece in card.top {
                        if case .note(let mark, _) = piece { check(mark.color == card.style.status, "Status text and outer rail use the same colour") }
                    }
                    if i == 0 {
                        check(card.style.stroke == NSColor.controlAccentColor, "Reply target outline stays independent of yellow rail")
                        let replyPosts = (card.replies ?? []).compactMap { piece -> NativeThreadCard.Post? in
                            if case .post(let post) = piece { return post }; return nil
                        }
                        check(replyPosts.last?.conversational == true, "Short assistant reply uses a conversational bubble")
                        for width: CGFloat in [260, 540] {
                            let layout = NativeThreadCard.layout(card, width: width)
                            check(layout.placed.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= width + 1 }, "Thread pieces stay inside \(width)pt")
                        }
                        check(card.bell == true && card.replyTarget && !card.statusTitle.isEmpty, "Active card carries bell, reply badge and status badge")
                    }
                    if i == 1 { check(card.statusTitle == "답변 완료", "Settled badge shows its words without ✅: \(card.statusTitle)") }
                    check(card.statusTitle.unicodeScalars.first.map { !($0.properties.isEmoji && $0.value > 0x7F) } ?? true, "Status badge starts with words, card \(i)")
                    check(!card.actions.contains { $0.identifier.hasPrefix("reply-") || $0.title.hasPrefix("답글") }, "Card foot has no reply count button, card \(i)")
                    check(!card.actions.contains { $0.title == "펼치기" }, "Card foot has no 펼치기, card \(i)")
                    check(!card.top.contains { if case .hosted(let id, _) = $0 { return id.hasPrefix("digest:") }; return false }, "Card has no conversation summary, card \(i)")
                    verifyHeader(card, name: "card \(i) dark=\(dark)")
                }
                for strip in [SlackSidebar.expandedWidth, SlackSidebar.width] {
                    model.sidebarWidth = strip
                    resizeChat(to: CGSize(width: 800 + strip, height: 850))
                    await settle()
                    for opacity in [55.0, 65.0, 100.0] {
                        let slider = NSSlider(value: opacity, minValue: 55, maxValue: 100, target: nil, action: nil)
                        let preference = UserDefaults.standard.object(forKey: BubbleOpacity.settingsKey) as? Double
                        changeChatOpacity(slider)
                        check(pet.chatOpacityPercent == opacity, "Opacity updates immediately to \(opacity)")
                        check((UserDefaults.standard.object(forKey: BubbleOpacity.settingsKey) as? Double) == preference, "Smoke leaves opacity preference unchanged")
                        model.requestScroll(active.id); await settle()
                        let name = "\(dark ? "dark" : "light")-\(strip == SlackSidebar.width ? "compact" : "expanded")-\(Int(opacity))"
                        capture(destination: destination.appendingPathComponent(name))
                        if opacity == 65 {
                            model.requestScroll("slack-bottom"); await settle()
                            capture(destination: destination.appendingPathComponent(name + "-questions"))
                        }
                    }
                }
                // A narrow card with bell, "답글 작성 중" and status together.
                resizeChat(to: CGSize(width: 380 + SlackSidebar.width, height: 850))
                model.sidebarWidth = SlackSidebar.width
                model.requestScroll(active.id); await settle()
                capture(destination: destination.appendingPathComponent("\(dark ? "dark" : "light")-narrow-header"))
            }
            check(!ThreadAppearance.isConversational("| 제목 | 내용 |\n|---|---|"), "Tables keep report width")
            check(!ThreadAppearance.isConversational("```swift\nlet x = 1\n```"), "Code keeps report width")
            check(BubbleOpacity.alpha(progress: 1, percent: 55, reduceTransparency: true) == 1, "Reduce transparency forces opaque backdrop")
            // Switching destinations must not move a thread draft into a new post.
            model.reply(active); model.draft = "스레드에 남길 초안"
            model.writeNewPost(); model.draft = "방에 남길 초안"
            model.reply(active)
            check(model.target?.id == active.id && model.draft == "스레드에 남길 초안", "Reply target and saved thread draft agree")
            model.writeNewPost()
            check(model.target == nil && model.draft == "방에 남길 초안", "New post draft survives target switching")
            await verifyCardClicks(destination: destination, check: check)
            await verifyLongReportButtons(destination: destination, check: check)
            NSApp.terminate(nil)
        }
    }

    /// Real mouse clicks on a native card: a click opens it and picks it as the reply target, 접기 folds it, the bell flips.
    /// Nothing is sent; the bell's action is replaced by the caller.
    @MainActor private func verifyCardClicks(destination: URL, check smokeCheck: (Bool, String) -> Void) async {
        let model = slack.model
        func settle() async { try? await Task.sleep(nanoseconds: 600_000_000) }
        func card(_ id: String) -> NativeThreadCard? {
            func find(_ view: NSView) -> NativeThreadCard? {
                if let card = view as? NativeThreadCard, card.value?.content.id == id, !card.isHidden { return card }
                for child in view.subviews { if let found = find(child) { return found } }
                return nil
            }
            return model.scrollView.flatMap { find($0) }
        }
        func click(_ view: NSView, at point: NSPoint) async {
            let location = view.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
            }
            await settle()
        }
        let room = model.selected ?? "CCOW", date = Date(timeIntervalSince1970: 1793320200)
        let root = ChatMessage(id: "hybrid-long-root", fromUser: false, speaker: "개인비서", body: "긴 스레드의 첫 글이에요.", date: date, profile: "personal-secretary")
        let replies = (0..<4).map { ChatMessage(id: "hybrid-long-\($0)", fromUser: false, speaker: "개인비서", body: "합성 답글 \($0)", date: date.addingTimeInterval(Double($0 + 1) * 60), profile: "personal-secretary") }
        let long = SlackThread(id: "hybrid-long", room: room, ts: "hybrid-long", root: root, replies: replies, replyCount: replies.count,
                               loaded: true, latest: replies.last!.date.timeIntervalSince1970, latestFromUser: false)
        model.writeNewPost(); model.draft = ""
        model.threads = [long]; model.open = []; model.bells = [long.id: true]
        resizeChat(to: CGSize(width: 800 + SlackSidebar.width, height: 850))
        model.requestScroll(long.id); await settle()
        guard NativeListFeature.enabled, let folded = card(long.id), let value = folded.value else { smokeCheck(false, "Native card for click checks is on screen"); return }
        smokeCheck(!value.content.actions.contains { $0.identifier.hasPrefix("fold-") || $0.identifier.hasPrefix("reply-") }, "A folded card offers no 펼치기 and no reply count")
        // The pile of earlier replies starts on the line where the posts' words and 더 보기 start.
        let words = value.placed.compactMap { item -> CGFloat? in if case .post = item.piece { return item.text.minX }; return nil }
        let pile = value.placed.first { if case .stack = $0.piece { return true }; return false }?.frame
        smokeCheck(pile != nil && words.contains { abs($0 - pile!.minX) < 0.5 } && abs(pile!.minX - (value.content.style.inset + ChatMetrics.avatar + 9)) < 0.5,
                   "Earlier replies pile starts at the words' line: \(String(describing: pile?.minX)) words=\(words)")
        capture(destination: destination.appendingPathComponent("hybrid-click-folded"))
        // The card's bottom margin, left of the foot: bare card.
        await click(folded, at: NSPoint(x: ChatMetrics.horizontalInset + 30, y: value.height - 4))
        smokeCheck(model.open.contains(long.id), "A click on the card opens it")
        smokeCheck(model.picked == long.id && model.target?.id == long.id, "A click on the card makes it the reply target")
        model.requestScroll(SlackModel.end(long.id)); await settle()
        guard let opened = card(long.id), let openValue = opened.value else { smokeCheck(false, "Opened card is on screen"); return }
        let fold = opened.diagnosticButtonFrames["fold-" + long.id]
        smokeCheck(fold != nil && openValue.content.actions.first { $0.identifier == "fold-" + long.id }?.title == "접기", "An opened card offers 접기")
        capture(destination: destination.appendingPathComponent("hybrid-click-opened"))
        if let fold { await click(opened, at: NSPoint(x: fold.midX, y: fold.midY)) }
        smokeCheck(!model.open.contains(long.id), "접기 folds the card")
        model.requestScroll(long.id); await settle()
        guard let again = card(long.id), let bell = again.value?.header.bell else { smokeCheck(false, "Bell is on screen"); return }
        await click(again, at: NSPoint(x: bell.midX + ChatMetrics.horizontalInset, y: bell.midY))
        smokeCheck(model.bells[long.id] == false, "Clicking the bell marks it read")
        smokeCheck(!model.open.contains(long.id), "The bell does not open the card")
        if let bell = card(long.id)?.value?.header.bell, let view = card(long.id) {
            await click(view, at: NSPoint(x: bell.midX + ChatMetrics.horizontalInset, y: bell.midY))
        }
        smokeCheck(model.bells[long.id] == true, "Clicking the bell again marks it unread")
    }

    /// A long report folds behind 더 보기, but its buttons sit outside the fold and are drawn once; the strip's tabs share its centre.
    @MainActor private func verifyLongReportButtons(destination: URL, check smokeCheck: (Bool, String) -> Void) async {
        let model = slack.model
        func settle() async { try? await Task.sleep(nanoseconds: 600_000_000) }
        let room = model.selected ?? "CCOW", date = Date(timeIntervalSince1970: 1793320200)
        let body = "# 이번 주 마감 3건 · 1건 확인 필요\n정산 서류만 아직 제출 전이에요.\n\n*할 일*\n1. 직인 받을 사람을 알려줘.\n\n*마감 현황*\n"
            + (1...16).map { "• 합성 항목 \($0) · 상세 근거와 원문 대조 결과를 적어 둔 줄이에요." }.joined(separator: "\n")
        var root = ChatMessage(id: "hybrid-long-report", fromUser: false, speaker: "업무비서", body: body, date: date, profile: "work-assistant")
        root.hermesReplyState = .asking; root.hermesButtons = ["의견", "확인"]
        let report = SlackThread(id: "hybrid-report", room: room, ts: "hybrid-report", root: root, replies: [], replyCount: 0,
                                 loaded: true, latest: date.timeIntervalSince1970, latestFromUser: false)
        model.writeNewPost(); model.draft = ""
        model.threads = [report]; model.open = []; model.bells = [:]
        let savedAppearance = panel.appearance
        defer { panel.appearance = savedAppearance }
        for dark in [true, false] {
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            model.sidebarWidth = SlackSidebar.width
            resizeChat(to: CGSize(width: 640 + SlackSidebar.width, height: 850))
            model.requestScroll(report.id); await settle()
            let card: NativeThreadCard? = {
                func find(_ view: NSView) -> NativeThreadCard? {
                    if let card = view as? NativeThreadCard, card.value?.content.id == report.id { return card }
                    for child in view.subviews { if let found = find(child) { return found } }
                    return nil
                }
                return model.scrollView.flatMap { find($0) }
            }()
            guard let value = card?.value else { smokeCheck(false, "Long report card is on screen, dark=\(dark)"); return }
            // Title, summary and what to do; the buttons; then the details, which fold behind 더 보기 (owner, 2026-10-31).
            func order(_ value: NativeThreadCard.Layout, _ state: String) {
                let posts = value.placed.compactMap { item -> (NativeThreadCard.Post, NSRect)? in
                    if case .post(let post) = item.piece { return (post, item.frame) }; return nil
                }
                let approvals = value.placed.filter { if case .hosted(let id, _) = $0.piece { return id.hasPrefix("approval:") }; return false }
                smokeCheck(approvals.count == 1 && posts.count == 2, "The report is what-to-do, buttons, details (\(state)): \(posts.count) posts, \(approvals.count) buttons")
                guard posts.count == 2, let buttons = approvals.first else { return }
                let head = posts[0], detail = posts[1]
                smokeCheck(head.0.text.string.contains("할 일") && head.0.text.string.contains("직인 받을 사람") && !head.0.text.string.contains("마감 현황"),
                           "Above the buttons: the title, summary and what to do (\(state))")
                smokeCheck(detail.0.text.string.contains("마감 현황") && detail.0.continuation && !detail.0.text.string.contains("직인 받을 사람"),
                           "Under the buttons: the details, without a second name (\(state))")
                smokeCheck(head.1.maxY <= buttons.frame.minY + 0.5 && buttons.frame.maxY <= detail.1.minY + 0.5, "Buttons sit between what to do and the details (\(state)), dark=\(dark)")
                smokeCheck(!(head.0.text.string + detail.0.text.string).contains("[[버튼"), "The button marker is not drawn as words")
                if let scroll = model.scrollView, let cardView = card {
                    let shown = cardView.convert(buttons.frame.offsetBy(dx: ChatMetrics.horizontalInset, dy: 0), to: scroll.contentView)
                    smokeCheck(scroll.contentView.bounds.intersection(shown).height >= min(shown.height, 20), "Buttons are on screen (\(state)), dark=\(dark)")
                }
            }
            order(value, "details folded")
            if case .post(let detail)? = value.placed.last(where: { if case .post = $0.piece { return true }; return false })?.piece {
                smokeCheck(detail.foldTitle == "더 보기", "The long details fold behind 더 보기, dark=\(dark)")
                chat.toggleReply(detail.id); model.requestScroll(report.id); await settle()
                if let opened = card?.value {
                    order(opened, "details open")
                    let shown = opened.placed.compactMap { item -> NativeThreadCard.Post? in if case .post(let post) = item.piece { return post }; return nil }.last
                    smokeCheck(shown?.foldTitle == "접기" && shown?.text.string.contains("합성 항목 16") == true, "더 보기 opens the details in place, dark=\(dark)")
                }
                capture(destination: destination.appendingPathComponent("\(dark ? "dark" : "light")-long-report-open"))
                chat.toggleReply(detail.id); await settle()
            }
            capture(destination: destination.appendingPathComponent("\(dark ? "dark" : "light")-long-report-buttons"))
            // Compact strip: every tab's faces and name, and the brand above, share the strip's centre line.
            var off: [String] = []
            // The strip's own frame: its blank foot spans the whole strip.
            guard let strip = chat.smokeFrames["sidebar-blank"], abs(strip.width - SlackSidebar.width) < 1 else {
                smokeCheck(false, "Compact strip is measured: \(String(describing: chat.smokeFrames["sidebar-blank"]))"); return
            }
            for tab in model.rooms.map(\.id) {
                for part in ["room-face-", "room-name-"] {
                    guard let frame = chat.smokeFrames[part + tab] else { off.append(part + tab + " missing"); continue }
                    if abs(frame.midX - strip.midX) > 1 { off.append("\(part)\(tab) \(frame.midX) vs \(strip.midX)") }
                }
            }
            if let brand = chat.smokeFrames["brand-d"], abs(brand.midX - strip.midX) > 1 { off.append("brand \(brand.midX) vs \(strip.midX)") }
            smokeCheck(off.isEmpty && !model.rooms.isEmpty, "Compact strip tabs are centred, dark=\(dark): " + off.prefix(4).joined(separator: "; "))
        }
        // 의견 asks the character what to do: the word goes to this thread, nothing else is sent (no Slack here).
        var sent: [(String, String?)] = []
        let savedSend = model.onSend
        defer { model.onSend = savedSend }
        model.onSend = { text, _, thread, _ in sent.append((text, thread?.id)) }
        model.answerHermes(report, label: "의견")
        var plain = ChatMessage(id: "hybrid-plain-ask", fromUser: false, speaker: "개인비서", body: "이대로 진행할까요?\n승인하면 이대로 보낼게.", date: date, profile: "personal-secretary")
        plain.hermesReplyState = .asking
        let ask = SlackThread(id: "hybrid-plain", room: room, ts: "hybrid-plain", root: plain, replies: [], replyCount: 0,
                              loaded: true, latest: date.timeIntervalSince1970, latestFromUser: false)
        model.threads = [ask]
        model.opinion(ask)
        smokeCheck(sent.map(\.0) == ["의견", "의견"] && sent.map(\.1) == [report.id, ask.id], "의견 sends 의견 into its own thread from both button kinds: \(sent)")
        // A question without a what-to-do section keeps its buttons after the whole message.
        smokeCheck(ReplyButtonPolicy.split(plain.body) == nil, "No what-to-do section: no split")
    }
}
