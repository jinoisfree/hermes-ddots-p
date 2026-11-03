import AppKit
import SwiftUI

@MainActor func clipboardSmokeOpenDrawer(_ pet: PetView, panel: PetPanel) async {
    var previous = CGRect.zero, stableSince = ProcessInfo.processInfo.systemUptime
    for _ in 0..<300 {
        pet.layoutSubtreeIfNeeded()
        if pet.clipboardPresented { return }
        let frame = pet.convert(pet.clipboardRowRect, to: nil).offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let now = ProcessInfo.processInfo.systemUptime
        if !pet.clipboardRowVisible || frame != previous { previous = frame; stableSince = now }
        if pet.clipboardRowVisible && !frame.isEmpty && now - stableSince >= 0.08 {
            let r = pet.clipboardRowRect
            let point = pet.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            guard pet.hitTest(point) is ClipboardDrawerRow else { smokeFailed("drawer row measured hit target is not its control") }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
            }
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if pet.clipboardPresented { return }
            }
            break
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    smokeFailed("clipboard row real click opens drawer; available=\(pet.clipboardAvailable) row=\(pet.clipboardRowVisible) attention=\(pet.clipboardAttention) bubble=\(pet.bubbleShown) chat=\(pet.chatExpanded) frame=\(pet.clipboardRowRect) pointer=\(pet.pointerLocation()) head=\(pet.atlas.interactionRect(in: pet.spriteRect)) panel=\(panel.frame)")
}

extension AppDelegate {
    @MainActor func verifyClipboardDrawer(library: ClipboardLibrary, board: NSPasteboard, destination: URL, capture: (String) -> Void) async {
        let oldPointer = pet.pointerLocation, oldSize = clipboardPreferredSize, oldClick = pet.onClick
        let oldState = pet.state, oldHeadline = pet.headline
        var pointer = CGPoint(x: -10000, y: -10000), clicks = 0
        pet.pointerLocation = { pointer }; pet.onClick = { _ in clicks += 1 }
        defer { pet.pointerLocation = oldPointer; pet.onClick = oldClick; pet.state = oldState; pet.headline = oldHeadline; clipboardPreferredSize = oldSize }
        var log: [String] = []
        func record(_ line: String) { log.append(line); try! (log.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("clipboard-drawer.txt"), atomically: true, encoding: .utf8) }
        func check(_ value: @autoclosure () -> Bool, _ name: String) { if !value() { record("FAIL " + name); capture("drawer-failure"); smokeFailed(name) } }
        func pause(_ seconds: Double = 0.35) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); pet.layoutSubtreeIfNeeded() }
        func wait(_ name: String, _ predicate: () -> Bool) async { for _ in 0..<300 { if predicate() { return }; await pause(0.02) }; check(false, name) }
        func localEvent(_ type: NSEvent.EventType, _ local: CGPoint, clicks: Int = 1) {
            let point = pet.convert(local, to: nil)
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!, atStart: false)
        }
        func move(_ local: CGPoint, delay: Double = 0.35) async {
            pointer = panel.convertPoint(toScreen: pet.convert(local, to: nil)); localEvent(.mouseMoved, local, clicks: 0); await pause(delay)
        }
        func head() -> CGPoint { let r = pet.atlas.interactionRect(in: pet.spriteRect); return CGPoint(x: r.midX, y: r.midY) }
        @MainActor func rows(_ root: NSView) -> [ClipboardDrawerRow] { ((root as? ClipboardDrawerRow).map { [$0] } ?? []) + root.subviews.flatMap(rows) }
        func row(collapse: Bool = false) -> CGPoint { let r = pet.clipboardRowRect; return CGPoint(x: collapse ? r.maxX - 17 : r.midX, y: r.midY) }
        func click(_ local: CGPoint, count: Int = 1) async { localEvent(.leftMouseDown, local, clicks: count); localEvent(.leftMouseUp, local, clicks: count); await pause(0.02) }
        pet.dismissClipboard(); pet.state = .idle; setBubbleActions([]); pet.headline = "보관함 확인"
        await pause(3.3)
        library.clear(includingPins: true); await wait("empty drawer fixture", { library.entries.isEmpty })
        await move(CGPoint(x: -200, y: -200)); await move(head())
        check(pet.bubbleShown && !pet.clipboardRowVisible, "T-61 empty history preserves ordinary bubble")
        let r = pet.placement!.bubbleRect
        await move(CGPoint(x: r.midX, y: r.midY), delay: 0.6)
        check(pet.bubbleShown && !pet.clipboardPresented, "V-12 head→ordinary bubble remains visible")
        setBubbleActions([PetAction(kind: .openChat, title: "확인")]); await move(head()); await pause()
        let a = pet.placement!.bubbleRect
        await move(CGPoint(x: a.midX, y: a.midY))
        check(pet.bubbleShown && !pet.clipboardRowVisible, "V-12 head→actions bubble remains visible with no row")
        setBubbleActions([])
        library.add(ClipboardInput(kind: .text, text: "서랍 합성 자료", source: "fixture"))
        await wait("drawer fixture stored", { library.entries.count == 1 })
        await move(CGPoint(x: -200, y: -200)); await move(head(), delay: 2)
        check(pet.clipboardRowVisible && !pet.clipboardPresented, "T-61 two-second head hover does not open drawer")
        capture("clipboard-drawer-folded-light")
        await move(row(), delay: 0.18)
        check(pet.bubbleShown && !pet.clipboardPresented, "T-61 row dwell below .3 seconds stays folded")
        await pause(0.16)
        await wait("T-61 row dwell opens drawer", { pet.clipboardPresented })
        var heights: [CGFloat] = []
        for _ in 0..<25 { heights.append(pet.placement!.globalBubble.height); await pause(0.012) }
        check(rows(pet).count == 1, "T-61 one retained row")
        record("T-61 height samples=" + heights.map { String(format: "%.2f", $0) }.joined(separator: ","))
        capture("clipboard-drawer-open-light")
        await click(row()); await pause(0.1)
        check(pet.clipboardPresented, "T-43 ordinary footer content click preserves shelf")
        await move(row(collapse: true), delay: 0.02); await click(row(collapse: true)); await pause(0.5)
        check(!pet.clipboardPresented, "T-61 footer collapses drawer")
        await move(CGPoint(x: -200, y: -200)); await move(head())
        await clipboardSmokeOpenDrawer(pet, panel: panel)
        await wait("T-61 row click reopens", { pet.clipboardPresented })
        for state in [WorkState.waiting, .failed] {
            pet.state = state; await pause()
            check(pet.clipboardPresented && pet.clipboardAttention, "T-62 attention preserves open drawer")
        }
        capture("clipboard-drawer-attention")
        let prior = clicks
        await click(row()); await pause()
        check(clicks == prior + 1 && !pet.clipboardPresented, "T-62 notification footer invokes existing chat click route once")
        await move(head()); check(!pet.clipboardRowVisible, "T-62 failed notification has no clipboard row")
        pet.state = .idle; await move(head()); await wait("T-62 row restored", { pet.clipboardRowVisible })
        pet.revealBubble(); await pause(); check(!pet.clipboardRowVisible, "T-62 new answer notification has no row")
        await pause(3.1); await wait("T-62 normal row returns after new answer", { pet.clipboardRowVisible })
        await clipboardSmokeOpenDrawer(pet, panel: panel); await pause(0.6)
        // Real edge drag, not a direct resize callback.
        let oldFrame = pet.placement!.globalBubble
        let right = CGPoint(x: pet.placement!.bubbleRect.maxX - 2, y: pet.placement!.bubbleRect.midY)
        localEvent(.leftMouseDown, right)
        await pause(0.02)
        localEvent(.leftMouseDragged, CGPoint(x: right.x + 60, y: right.y))
        await pause(0.1)
        localEvent(.leftMouseUp, CGPoint(x: right.x + 60, y: right.y)); await pause(0.7)
        check(pet.clipboardPresented && pet.placement!.globalBubble.width > oldFrame.width + 100, "T-45 native right edge resize grows width")
        check(ClipboardDrawer.columns(width: pet.placement!.globalBubble.width) >= 4, "T-45 resize exposes four columns")
        record("T-45 original=\(oldFrame) resized=\(pet.placement!.globalBubble)")
        resetClipboardSize(); await pause(0.7)
        check(pet.placement!.globalBubble.size == ClipboardDrawer.defaultSize, "T-45 reset restores default size")
        // T-45 top edge and minimum clamp, through actual event routing.
        let topRect = pet.placement!.bubbleRect
        let top = CGPoint(x: topRect.midX, y: topRect.maxY - 2)
        localEvent(.leftMouseDown, top); await pause(0.02)
        localEvent(.leftMouseDragged, CGPoint(x: top.x, y: top.y + 80)); await pause(0.05)
        localEvent(.leftMouseUp, CGPoint(x: top.x, y: top.y + 80)); await pause(0.3)
        check(pet.placement!.globalBubble.height > ClipboardDrawer.defaultSize.height + 70, "T-45 top drag adds another visible row")
        let leftRect = pet.placement!.bubbleRect, left = CGPoint(x: leftRect.minX + 2, y: leftRect.midY)
        localEvent(.leftMouseDown, left); await pause(0.02)
        localEvent(.leftMouseDragged, CGPoint(x: left.x + 500, y: left.y)); await pause(0.05)
        localEvent(.leftMouseUp, CGPoint(x: left.x + 500, y: left.y)); await pause(0.3)
        check(pet.placement!.globalBubble.width == ClipboardDrawer.minimumSize.width, "T-45 left edge cannot shrink below two columns")
        let resetEdge = CGPoint(x: pet.placement!.bubbleRect.maxX - 2, y: pet.placement!.bubbleRect.midY)
        await click(resetEdge, count: 2); await pause(0.6)
        check(pet.placement!.globalBubble.size == ClipboardDrawer.defaultSize, "T-45 edge double click restores default")
        // T-46 content fit has real intermediate frames and never invents a pointer exit.
        var fitting = library.settings; fitting.fitsContents = true; library.changeSettings(fitting, persist: false)
        await pause(0.5)
        let smallHeight = pet.placement!.globalBubble.height
        for index in 0..<7 { library.add(ClipboardInput(kind: .text, text: "fit \(index)", source: "fixture")) }
        await wait("T-46 eight entries", { library.entries.count == 8 }); await pause(0.4)
        let largeHeight = pet.placement!.globalBubble.height
        check(largeHeight > smallHeight + 80, "T-46 content fit expands within user maximum")
        let remove = library.entries.filter { $0.text?.hasPrefix("fit ") == true }
        library.delete(remove)
        var fitHeights: [CGFloat] = []
        for _ in 0..<28 { fitHeights.append(pet.placement!.globalBubble.height); await pause(0.012) }
        let reduced = CommandLine.arguments.contains("--ui-smoke-reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        check(reduced || fitHeights.contains { $0 > smallHeight + 1 && $0 < largeHeight - 1 }, "T-46 content fit has intermediate native frames")
        check(abs(pet.placement!.globalBubble.height - smallHeight) <= 1 && pet.clipboardPresented, "T-46 shrink finishes without closing shelf")
        fitting.fitsContents = false; library.changeSettings(fitting, persist: false); await pause(0.4)
        check(pet.placement!.globalBubble.size == ClipboardDrawer.defaultSize, "T-46 fixed mode restores saved bounds")
        record("T-46 frame samples=" + fitHeights.map { String(format: "%.2f", $0) }.joined(separator: ","))
        // T-62 uses the real approval model and the unchanged application click route.
        let savedSnapshot = slack.snapshot, savedRoom = slack.model.selected, savedSource = slack.model.source
        let savedApprovalThreads = slack.model.approvalThreads
        var request = ChatMessage(id: "slack:SYNTH:100.1", fromUser: false, speaker: "진단담당", body: "합성 시험 결과를 반영할까요?", date: Date())
        request.hermesReplyState = .asking; request.hermesButtons = ["승인", "거절"]
        let thread = SlackThread(id: request.id, room: "SYNTH", ts: "100.1", root: request, replies: [], replyCount: 0, loaded: true,
            latest: Date().timeIntervalSince1970, latestFromUser: false)
        var snapshot = SlackBridge.Snapshot(); snapshot.status = .connected; snapshot.rooms = [SlackRoom(id: "SYNTH", name: "합성 요청")]
        snapshot.threads["SYNTH"] = [thread]
        slack.model.source = .slack; slack.model.selected = "SYNTH"; slack.model.approvalThreads = nil
        slack.acceptSnapshot(snapshot); updatePet(); await pause(0.4)
        check(slack.model.needsPetApproval && pet.clipboardPresented, "T-62 real approval model keeps current drawer")
        check(pet.animationFrame.row == PetAnimation.waiting.rawValue, "T-62 real urgent animation keeps waving phone")
        let copiedBefore = board.changeCount
        if let firstCard = pet.subviews.compactMap({ $0 as? NSHostingView<ClipboardShelf> }).first {
            @MainActor func findCard(_ root: NSView) -> ClipboardCardView? { (root as? ClipboardCardView) ?? root.subviews.lazy.compactMap(findCard).first }
            if let card = findCard(firstCard) {
                let rect = card.convert(card.bounds, to: pet)
                await click(CGPoint(x: rect.midX, y: rect.midY)); await pause(0.2)
                check(board.changeCount > copiedBefore && pet.clipboardPresented, "T-62 card still copies during incoming approval")
            } else { check(false, "T-62 visible approval fixture card") }
        }
        capture("clipboard-drawer-live-approval")
        pet.onClick = oldClick
        await move(row(), delay: 0.02); await click(row())
        await wait("T-62 original click opens exact pending conversation", { chatExpanded && slack.model.focusThread == thread.id && slack.model.open.contains(thread.id) })
        check(!pet.clipboardPresented, "T-62 opening pending conversation closes drawer")
        capture("clipboard-approval-target")
        collapseChat(); await pause(1)
        check(slack.model.needsPetApproval && !pet.clipboardRowVisible, "T-62 folded real approval has no clipboard row")
        record("T-62 folded notification size=\(pet.placement!.globalBubble.size), target=\(bubbleSize)")
        check(pet.placement!.globalBubble.size == PetLayout.bubbleSize(actionCount: bubbleActions.count), "T-62 folded notification restores original bubble size after conversation")
        let notification = pet.placement!.bubbleRect
        await move(CGPoint(x: notification.midX, y: notification.midY), delay: 0.05)
        await click(CGPoint(x: notification.midX, y: notification.midY))
        await wait("T-62 folded notification retains exact conversation route", { chatExpanded && slack.model.focusThread == thread.id })
        collapseChat(); await pause(1)
        slack.model.selected = savedRoom; slack.model.source = savedSource; slack.model.approvalThreads = savedApprovalThreads
        slack.acceptSnapshot(savedSnapshot); pet.state = .idle; setBubbleActions([]); await pause(3.2)
        pet.onClick = { _ in clicks += 1 }
        await move(CGPoint(x: -200, y: -200)); await move(head())
        await clipboardSmokeOpenDrawer(pet, panel: panel); await pause(0.4)
        record("PASS T-62 actual approval model, phone pose, card copy and exact original conversation navigation")
        panel.appearance = NSAppearance(named: .darkAqua); await pause(); capture("clipboard-drawer-open-dark")
        await move(row(collapse: true), delay: 0.02); await click(row(collapse: true)); await pause()
        await move(CGPoint(x: -200, y: -200)); await move(head()); capture("clipboard-drawer-folded-dark")
        library.add(ClipboardInput(kind: .text, text: "drawer-sensitive-fixture", source: "fixture", secret: true))
        await wait("T-61 recent secret fixture", { library.entries.first?.secret == true }); await pause(0.2)
        let rowView = rows(pet).first!
        check(rowView.text.contains("비밀 항목") && !rowView.text.contains("drawer-sensitive-fixture"), "T-61 recent secret row contains only safe name")
        library.paused = true; await pause(0.15)
        check(rowView.text.contains("기록 멈춤"), "T-61 paused row explains state")
        library.paused = false; library.monitor.allowed = { false }; library.monitor.poll(); await pause(0.15)
        check(rowView.text.contains("허용이 필요"), "T-61 permission row explains state")
        library.monitor.allowed = { true }; library.monitor.poll()
        await move(CGPoint(x: -200, y: -200)); await pause(0.4)
        board.clearContents(); board.setString("drawer-sensitive-fixture", forType: .string); board.setString("1", forType: ClipboardPasteboard.concealed)
        library.monitor.poll()
        await wait("T-61 copy notice with row", { pet.clipboardCopyFrame != nil && pet.clipboardRowVisible })
        check(pet.clipboardCopyFrame?.text == "비밀 항목이 복사되었습니다", "T-61 copy notice and row never reveal secret")
        capture("clipboard-copy-with-row")
        await move(row(), delay: 0.02); await click(row()); await pause(0.3)
        check(pet.clipboardPresented && pet.clipboardCopyFrame == nil, "T-61 row can open drawer during copy notice")
        pet.dismissClipboard()
        record("PASS V-12 T-61 T-62 native crossing, dwell, row click, attention/footer; T-45 top/left/right/minimum/reset and T-46 adaptive frames")
        pet.dismissClipboard(); panel.appearance = nil
    }
}
