import AppKit
import SwiftUI

extension AppDelegate {
    /// An opened thread folds on a click in its empty space or on 접기, and on nothing else:
    /// every control inside it is pressed with a real mouse click, as are a gap between two buttons and a button that is switched off.
    @MainActor func threadActionsSmoke(destination: URL) async {
        let m = slack.model
        m.source = .slack; m.selected = "CCOW"; m.query = ""; m.draft = ""
        m.workspace = "fake-workspace"; m.vaultOverride = ShrimpVault(root: FileManager.default.temporaryDirectory.path)
        m.clipboard = NSPasteboard(name: .init("ddots-thread-actions-smoke"))
        var effects = 0
        m.vaultOpen = { _ in effects += 1; return nil }; m.vaultReveal = { _ in effects += 1; return nil }
        m.onSend = { _,_,_,_ in effects += 1 }
        m.onPageSend = { _,_, done in effects += 1; done() }
        guard let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first else { smokeFailed("The conversation is on screen") }
        func click(_ spot: CGPoint) async {
            let point = host.convert(NSPoint(x: spot.x, y: host.isFlipped ? spot.y : host.bounds.height - spot.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        var results: [[String: Any]] = []
        let cases = ["전체 보기", "쪽", "경로 줘", "파일오픈", "다운로드", "표", "수정", "종결", "복사", "답글", "꺼진 답글", "버튼 사이", "접기", "빈 곳"]
        for (index, action) in cases.enumerated() {
            web.close(); m.pageHold = nil; m.replyTo = nil; m.picked = nil; m.copied = nil
            var choice = ChatMessage(id: "choice-\(index)", fromUser: false, speaker: "새우튀김", body: "선택: 가짜.xlsx → 시험 시트 → 합성행\n- 이름: 합성행", date: Date(), profile: "fried-shrimp")
            choice.slackUserID = ShrimpVault.defaultBot
            var fallback = choice; fallback.id = "fallback-\(index)"; fallback.body = "경로 줘 · 열어줘 · 다운로드 · 표 · 수정 · 종결 — 글로 보내도 됩니다"
            var control = choice; control.id = "control-\(index)"; control.body = "쪽 1/3 · 총 25건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다"
            var note = choice; note.id = "note-\(index)"; note.body = "가짜 시험 답글"
            let thread = SlackThread(id: "thread-\(index)", room: "CCOW", ts: "800", root: choice, replies: [fallback,note,control], replyCount: 3, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
            m.threads = [thread]; m.open = [thread.id]; m.focusThread = nil
            // A button that is switched off: 답글 while the answer is already going to this thread.
            if action == "꺼진 답글" { m.reply(thread) }
            m.requestScroll(SlackModel.end(thread.id))
            try? await Task.sleep(nanoseconds: 700_000_000)
            let key: String
            switch action {
            case "전체 보기": key = "thread-all"
            case "쪽": key = "ux58-page-2"
            case "복사", "버튼 사이", "빈 곳": key = "copy-" + thread.id
            case "답글", "꺼진 답글": key = "reply-" + thread.id
            case "접기": key = "fold-" + thread.id
            default: key = "vault-" + action + "-" + choice.id
            }
            guard let rect = chat.smokeFrames[key], rect.width > 1 else { smokeFailed("\(action) has a place to press") }
            let before = effects
            switch action {
            // The foot's buttons stand apart; the space between two of them belongs to the row.
            case "버튼 사이": await click(CGPoint(x: rect.maxX + 6, y: rect.midY))
            // Left of the first button the card is bare.
            case "빈 곳": await click(CGPoint(x: rect.minX - 40, y: rect.midY))
            default: await click(CGPoint(x: rect.midX, y: rect.midY))
            }
            let open = m.open.contains(thread.id)
            results.append(["action": action, "open": open, "effects": effects - before, "pane": web.open])
            capture(destination: destination.appendingPathComponent("action-\(index)"))
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: destination.appendingPathComponent("thread-actions.json")) }
            switch action {
            case "접기", "빈 곳": smokeCheck(!open, "\(action) folds the thread")
            default: smokeCheck(open, "Pressing \(action) leaves the thread open")
            }
            switch action {
            case "전체 보기": smokeCheck(web.open && effects == before + 1, "전체 보기 asks for the list and opens it at the right")
            case "쪽", "경로 줘", "파일오픈", "다운로드", "표", "수정", "종결": smokeCheck(effects == before + 1, "\(action) does its work once: \(effects - before)")
            case "복사": smokeCheck(m.copied == "copy-" + thread.id, "복사 copies the thread")
            // An opened thread is already the one being answered, so its 답글 is switched off either way.
            case "답글", "꺼진 답글": smokeCheck(m.target?.id == thread.id && effects == before, "답글 keeps the answer on the thread")
            default: smokeCheck(effects == before, "\(action) sends nothing")
            }
        }
        // A short thread shows its replies without being opened. Asking for the whole list from it brings answers that make it
        // long enough to pile up; it must stay unfolded all the same.
        web.close(); m.pageHold = nil; m.replyTo = nil; m.picked = nil
        var asked = ChatMessage(id: "short-root", fromUser: true, speaker: "나", body: "가짜새", date: Date(), profile: "")
        asked.slackUserID = "UME"
        var pages = ChatMessage(id: "short-pages", fromUser: false, speaker: "새우튀김", body: "쪽 1/3 · 총 25건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다", date: Date(), profile: "fried-shrimp")
        pages.slackUserID = ShrimpVault.defaultBot
        var short = SlackThread(id: "thread-short", room: "CCOW", ts: "900", root: asked, replies: [pages], replyCount: 1, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
        m.threads = [short]; m.open = []; m.focusThread = nil
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard let all = chat.smokeFrames["thread-all"], all.width > 1 else { smokeFailed("A short thread shows 전체 보기 without being opened") }
        await click(CGPoint(x: all.midX, y: all.midY))
        var command = asked; command.id = "short-command"; command.body = "전체 보기"
        var list = pages; list.id = "short-list"; list.body = "전체 목록 1/1 · 총 25건\n\n1. 가짜.md\n\n2. 가짜 둘.md"
        short.replies = [pages, command, list]; short.replyCount = 3
        m.threads = [short]
        try? await Task.sleep(nanoseconds: 600_000_000)
        capture(destination: destination.appendingPathComponent("short-thread"))
        smokeCheck(m.open.contains(short.id) && SlackStack.visible(short, expanded: m.open.contains(short.id)).hidden == 0,
                   "A short thread asked for its whole list stays unfolded when the answers arrive")
        // The list at the right belongs to the thread it was asked from. Choosing another thread puts it away and the window draws back.
        var other = ChatMessage(id: "other-root", fromUser: false, speaker: "새우튀김", body: "다른 가짜 글", date: Date(), profile: "fried-shrimp")
        other.slackUserID = ShrimpVault.defaultBot
        let second = SlackThread(id: "thread-other", room: "CCOW", ts: "901", root: other, replies: [], replyCount: 0, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
        m.threads = [short, second]; m.shrimpListThread = short.id; web.showShrimpList()
        try? await Task.sleep(nanoseconds: 900_000_000)
        let wide = panel.frame.width
        smokeCheck(web.shrimpList && web.open, "The whole list is open at the right")
        m.pick(short, foldable: false)
        smokeCheck(web.shrimpList && m.shrimpListThread == short.id, "Choosing the list's own thread leaves the list open")
        m.pick(second, foldable: false)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        capture(destination: destination.appendingPathComponent("other-thread"))
        smokeCheck(!web.shrimpList && !web.open && m.shrimpListThread == nil, "Choosing another thread closes the whole list")
        smokeCheck(panel.frame.width < wide - 100, "The window draws back when the list closes: \(wide) -> \(panel.frame.width)")
        NSApp.terminate(nil)
    }
}
