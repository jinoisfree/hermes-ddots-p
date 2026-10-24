import AppKit
import SwiftUI

extension AppDelegate {
    func verifySlackRoom(destination: URL) {
        Task { @MainActor [self] in
            let model = slack.model
            var report = "40 synthetic threads, varying lengths; one thread has 50 replies.\n"
            @MainActor func check(_ ok: Bool, _ title: String) {
                report += "\(ok ? "PASS" : "FAIL"): \(title)\n"
                try! report.write(to: destination.appendingPathComponent("room.txt"), atomically: true, encoding: .utf8)
                if !ok {
                    report += "visible=\(model.visibleThreads), viewport=\(String(describing: model.scrollView?.contentView.bounds))\n"
                    try! report.write(to: destination.appendingPathComponent("room.txt"), atomically: true, encoding: .utf8)
                    capture(destination: destination.appendingPathComponent("failure"))
                }
                smokeCheck(ok, title)
            }
            func settle() async { try? await Task.sleep(nanoseconds: 750_000_000) }
            @MainActor func visible(_ id: String) -> Bool {
                guard let rect = model.rowFrame(id), let scroll = model.scrollView else { return false }
                return rect.intersection(scroll.contentView.bounds).height > 2
            }
            let room = model.selected ?? "SYNTHETIC"
            let now = Date()
            func fixture(_ index: Int) -> SlackThread {
                let root = ChatMessage(id: "lazy-root-\(index)", fromUser: true, speaker: "", body: "합성 글 \(index) " + String(repeating: "서로 다른 길이의 글을 읽습니다. ", count: 1 + abs(index) % 5), date: now.addingTimeInterval(Double(index) * 1800), profile: "")
                let count = index == 20 ? 50 : (index % 3 == 0 ? 5 : 0)
                let replies = (0..<count).map { n in
                    ChatMessage(id: "lazy-reply-\(index)-\(n)", fromUser: false, speaker: "개인비서", body: "답글 \(n). " + String(repeating: "내용을 확인하고 다음 단계로 이어갑니다. ", count: 2), date: root.date, profile: "personal-secretary")
                }
                return SlackThread(id: "lazy-\(index)", room: room, ts: "\(1000 + index).1", root: root, replies: replies, replyCount: count, loaded: true, latest: root.date.timeIntervalSince1970, latestFromUser: count == 0)
            }
            model.onSend = nil; model.onOpen = { _ in }
            model.foldAll(animated: false); model.threads = (0..<40).map(fixture)
            model.typing = [:]; model.draft = "작성 중인 글"; model.hasOlder = true
            model.requestScroll("slack-bottom")
            await settle()
            check(visible("lazy-39"), "Entering the room shows its newest thread")
            model.jump(SlackNoticeItem(id: "synthetic", title: "질문", color: "#FFCC00", threads: ["lazy-0"]))
            await settle()
            check(visible("lazy-0"), "The notice chip reaches the oldest offscreen thread")
            model.foldAll(animated: false); model.requestScroll("slack-bottom"); await settle()
            // Search arrival uses go(to:) followed by the matching message ID.
            model.go(to: "lazy-0"); model.requestScroll("lazy-root-0"); await settle()
            check(visible("message:lazy-root-0"), "Search arrival reaches the oldest root message")
            model.foldAll(animated: false); model.requestScroll("slack-bottom"); await settle()
            model.open = ["lazy-20"]; model.focusThread = "lazy-20"
            model.requestScroll("lazy-reply-20-25"); await settle()
            check(visible("message:lazy-reply-20-25"), "An offscreen inner reply is brought into view")
            model.foldAll(animated: false); model.requestScroll("slack-bottom"); await settle()
            let height = preferredChatSize.height
            model.toggle(model.threads[3]); await settle()
            capture(destination: destination.appendingPathComponent("distant-open"))
            check(pet.chatSize.height > height + 20, "Opening a distant thread grows the window: actual=\(pet.chatSize.height), preferred=\(height), measured=\(model.threadHeights["lazy-3"] ?? -1), viewport=\(model.viewportHeight), fit=\(slackFitHeight ?? -1), open=\(model.open), focus=\(model.focusThread ?? "nil")")
            guard let foot = model.rowFrame("lazy-3"), let scroll = model.scrollView else { smokeFailed("Missing opened thread frame") }
            check(foot.maxY <= scroll.contentView.bounds.maxY + 2 && foot.maxY > scroll.contentView.bounds.minY, "The opened thread foot is visible")
            model.foldAll(animated: false); await settle()
            check(pet.chatSize.height == height, "Folding returns the window to its preferred height")
            model.requestScroll("lazy-15"); await settle(); model.userScrolls += 1
            for change in 0..<3 {
                guard let place = model.place(), let anchor = model.visibleThreads.first, let before = model.rowFrame(anchor) else { smokeFailed("Missing reading anchor") }
                let y = before.minY - scroll.contentView.bounds.minY
                if change == 0 {
                    var updated = model.threads
                    updated[0].replies.append(ChatMessage(id: "new-reply", fromUser: false, speaker: "개인비서", body: "새 답글", date: now, profile: "personal-secretary"))
                    updated[0].replyCount += 1; model.threads = updated
                } else if change == 1 { model.threads.append(fixture(40)) }
                else {
                    model.onOlder = { model.threads.insert(contentsOf: (-8..<0).map(fixture), at: 0) }
                    model.onOlder?()
                }
                // Match publish: changes above the reader keep the bottom distance; a new post below does not.
                if change != 1 { model.keep(place) }; await settle()
                let moved = model.rowFrame(anchor).map { abs(($0.minY - scroll.contentView.bounds.minY) - y) } ?? .infinity
                check(moved <= 2, "Reading anchor survives update \(change), displacement=\(moved)pt")
            }
            model.requestScroll("slack-bottom"); await settle()
            model.threads.append(fixture(41)); model.requestScroll("slack-bottom"); await settle()
            check(visible("lazy-41"), "Following the newest thread continues after an arrival")
            model.requestScroll("lazy--8"); await settle(); model.userScrolls += 1
            for step in 0..<80 {
                guard let document = scroll.documentView else { smokeFailed("Missing scroll document") }
                let before = scroll.contentView.bounds.minY
                let end = max(0, document.bounds.maxY - scroll.contentView.bounds.height)
                if before >= end - 2 { break }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(end, before + 160)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(nanoseconds: 30_000_000)
                check(scroll.contentView.bounds.minY >= before - 2, "Downward step \(step) never jumps backward")
            }
            model.foldAll(animated: false); model.requestScroll(model.threads[0].id); await settle(); model.userScrolls += 1
            guard let topPlace = model.place(), let topAnchor = model.visibleThreads.first,
                  let topFrame = model.rowFrame(topAnchor) else { smokeFailed("Missing near-top reading anchor") }
            let topOffset = topFrame.minY - scroll.contentView.bounds.minY
            check(scroll.contentView.bounds.minY < 100, "The near-top prepend begins beside the older-posts button")
            model.onOlder = { model.threads.insert(contentsOf: (-18 ..< -8).map(fixture), at: 0) }
            model.onOlder?(); model.keep(topPlace); await settle()
            let topMoved = model.rowFrame(topAnchor).map { abs($0.minY - scroll.contentView.bounds.minY - topOffset) } ?? .infinity
            check(topMoved <= 2, "Near-top varied-height prepend preserves the reading anchor: \(topMoved)pt")
            for target in ["lazy-3", "lazy-36"] {
                model.foldAll(animated: false); model.requestScroll("lazy-20"); await settle()
                model.jump(SlackNoticeItem(id: "jump-" + target, title: "질문", color: "#FFCC00", threads: [target]))
                await settle()
                check(visible(target), "A notice reaches a distant thread from the middle: \(target)")
                check(pet.chatSize.height > preferredChatSize.height + 20, "The notice's opened thread grows the window: \(target)")
                let foot = model.rowFrame(target)
                check(foot.map { $0.maxY <= scroll.contentView.bounds.maxY + 2 && $0.maxY > scroll.contentView.bounds.minY } ?? false,
                      "The notice's opened thread foot is visible: \(target)")
            }
            // Return to the controller's synthetic rooms to exercise the real room-selection callback.
            model.foldAll(animated: false); slack.publish(); await settle()
            if let original = model.threads.first(where: { $0.replyCount > 0 }),
               let other = model.rooms.first(where: { $0.id != room }) {
                model.toggle(original); model.draft = "방을 바꿔도 남는 글"; await settle()
                let opened = model.open
                model.select(other.id); await settle(); model.select(room); await settle()
                check(model.open == opened && model.threads.contains { $0.id == original.id } && model.draft == "방을 바꿔도 남는 글",
                      "Returning to a room preserves its opened thread and draft")
            } else { check(false, "The room round trip has two synthetic rooms") }
            await verifyRoomEntry(destination: destination) { ok, title in check(ok, title) }
            report += "PASS: clicking a room, narrow or wide, shows its newest conversation.\n"
            capture(destination: destination)
            report += "PASS: synthetic room navigation and reading position.\n"
            try! report.write(to: destination.appendingPathComponent("room.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
