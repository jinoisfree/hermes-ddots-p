import AppKit
import SwiftUI

extension AppDelegate {
    /// Synthetic design matrix plus semantic checks; no preferences or messages are written.
    func verifyHybridChat(destination: URL) {
        Task { @MainActor [self] in
            await verifyThreadDigests(destination: destination)
            ThreadDigestStore.shared.testProvider = { data in
                let text = String(data: data, encoding: .utf8) ?? ""
                return .success(text.contains("바뀐 부분") ? "회의 시간은 오후 3시로 변경됐고 안건이 하나 추가됐어요. 변경 사항 2건의 확인을 진행 중입니다." : text.contains("시스템 점검") ? "시스템 점검을 마쳤고 모든 연결이 정상임을 확인했어요." : "제안한 아이디어를 더 살펴볼지 소유자의 결정을 기다리고 있어요.")
            }
            defer { ThreadDigestStore.shared.testProvider = nil }
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
                    }
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
            NSApp.terminate(nil)
        }
    }
}
