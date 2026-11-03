import AppKit
import SwiftUI
import Vision

/// Real window dispatch protects the pointer/focus/responder contracts, rather than calling tab actions directly.
extension AppDelegate {
    @MainActor func verifyClipboardInteractions(library: ClipboardLibrary, board: NSPasteboard, destination: URL,
                                                capture: (String) -> Void) async {
        let originalPointer = pet.pointerLocation, physicalPointer = NSEvent.mouseLocation, originalTabs = library.tabs
        let originalFront = NSWorkspace.shared.frontmostApplication
        let windowNumber = panel.windowNumber
        NSApp.activate(ignoringOtherApps: true)
        let screen = panel.screen!.visibleFrame
        var pointer = CGPoint(x: screen.minX + 5, y: screen.minY + 5)
        let outside = pointer
        let reduced = CommandLine.arguments.contains("--ui-smoke-reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var log = ["T-39~44 native NSApp event dispatch; reduced=\(reduced)"]
        func warp(_ point: CGPoint) {
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y))
        }
        defer { pet.pointerLocation = originalPointer; warp(physicalPointer); if originalFront?.processIdentifier != getpid() { originalFront?.activate(options: []) } }
        pet.pointerLocation = { pointer }
        pet.installClipboard(library)
        func pause(_ seconds: Double = 0.45) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); pet.layoutSubtreeIfNeeded() }
        func record(_ line: String) {
            log.append(line)
            try! (log.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("clipboard-interaction.txt"), atomically: true, encoding: .utf8)
        }
        func fail(_ name: String) -> Never {
            record("FAIL " + name); capture("interaction-failure"); warp(physicalPointer)
            if originalFront?.processIdentifier != getpid() { originalFront?.activate(options: []) }
            smokeFailed(name)
        }
        func check(_ condition: @autoclosure () -> Bool, _ name: String) { if !condition() { fail(name) } }
        func require<T>(_ value: T?, _ name: String) -> T { guard let value else { fail(name) }; return value }
        func wait(_ name: String, _ predicate: () -> Bool) async {
            for _ in 0..<250 { if predicate() { return }; await pause(0.02) }
            fail(name)
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func move(_ point: CGPoint, delay: Double = 0.45) async {
            pointer = point; warp(point)
            NSApp.postEvent(event(.mouseMoved, at: point, clicks: 0), atStart: false)
            await pause(delay)
        }
        func click(_ point: CGPoint, clicks: Int = 1) async {
            pointer = point; warp(point)
            NSApp.postEvent(event(.leftMouseDown, at: point, clicks: clicks), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, at: point, clicks: clicks), atStart: false)
            await pause(0.04)
        }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], chars: String = "") {
            panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] { ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, T.self) } }
        func head() -> CGPoint {
            let r = pet.atlas.interactionRect(in: pet.spriteRect)
            return panel.convertPoint(toScreen: pet.convert(CGPoint(x: r.midX, y: r.midY), to: nil))
        }
        func selection() -> ClipboardSelectionView { require(descendants(pet, ClipboardSelectionView.self).first, "Selection surface exists") }
        func grid() -> ClipboardGridView { require(descendants(pet, ClipboardGridView.self).first, "Grid surface exists") }
        func tabPoint(_ id: UUID) -> CGPoint {
            let selection = selection(), rect = require(selection.tabRects[id], "Tab has measured frame")
            return panel.convertPoint(toScreen: selection.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil))
        }
        func nativePoint(_ view: NSView) -> CGPoint {
            var rect = view.convert(view.bounds, to: pet)
            if view is ClipboardCardView { rect = rect.intersection(grid().convert(grid().bounds, to: pet)) }
            check(!rect.isEmpty, "Clicked control intersects its viewport")
            return panel.convertPoint(toScreen: pet.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil))
        }
        func controlPoint(_ identifier: String) -> CGPoint {
            guard let view = descendants(pet, NSView.self).first(where: { $0.identifier?.rawValue == identifier }) else { fail("Missing measured control " + identifier) }
            check(!view.visibleRect.isEmpty, "Measured control is visible: " + identifier)
            let point = nativePoint(view)
            record("control=\(identifier) frame=\(view.convert(view.bounds, to: pet)) bounds=\(view.bounds) visible=\(view.visibleRect) panel=\(panel.frame) petFrame=\(pet.frame) point=\(point) hit=\(pet.hitTest(panel.convertPoint(fromScreen: point)).map { String(describing: type(of: $0)) } ?? "nil") active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
            return point
        }
        func remainsOpen(_ name: String) {
            check(pet.clipboardPresented && !chatExpanded, name + " keeps shelf open without opening chat")
        }
        await move(outside)
        if chatExpanded { collapseChat(); await pause(0.8) }
        library.clear(includingPins: true); await wait("interaction clean fixture", { library.entries.isEmpty })
        for i in 0..<8 {
            library.add(ClipboardInput(kind: .text, text: "interaction sample \(i)", source: "fixture"))
            await wait("interaction fixture write", { library.entries.count == i + 1 })
        }
        library.editTabs {
            $0 = ClipboardTabs()
            _ = try $0.add(name: "한 개", kind: .custom)
            _ = try $0.add(name: "빈 탭", kind: .custom)
            _ = try $0.add(name: "추가 탭", kind: .custom)
            $0.selected = $0.items[0].id
        }
        await wait("interaction seven tabs", { library.tabs.items.map(\.name) == ["전체", "글자", "비밀번호", "사진·영상", "한 개", "빈 탭", "추가 탭"] })
        let full = library.tabs.items[0].id
        let one = require(library.tabs.items.first { $0.name == "한 개" }, "One-card fixture tab").id
        let empty = require(library.tabs.items.first { $0.name == "빈 탭" }, "Empty fixture tab").id
        library.membership(library.entries[0].id, tab: one, add: true)
        await wait("interaction one card tab", { library.entries.filter { $0.memberships.contains(one) }.count == 1 })
        record("fixture prepared")
        await move(head()); await clipboardSmokeOpenDrawer(pet, panel: panel); await wait("T-40 first visit", { pet.clipboardPresented }); await pause(0.8)
        let fixed = pet.placement!.globalBubble, tabLine = tabPoint(full)
        record("fixed frame=\(fixed), tab=\(tabLine)")
        // T-39/42: click the actual measured controls, and inspect real in-flight native frames.
        var frameSequence: [[String: Double]] = []
        for id in [one, empty, full] {
            record("select tab index=\(library.tabs.items.firstIndex { $0.id == id }!)")
            let oldSelection = selection().selectionRect
            await move(tabPoint(id), delay: 0.02)
            await click(tabPoint(id))
            await wait("T-39 native tab selects", { library.tabs.current.id == id })
            var middleSelection = false, middleGrid = false, blank = false, translated = false, capturedMiddle = false
            let started = ProcessInfo.processInfo.systemUptime
            repeat {
                let s = selection(), g = grid()
                if let target = s.tabRects[id] {
                    let lower = min(oldSelection.midX, target.midX), upper = max(oldSelection.midX, target.midX)
                    check(s.selectionRect.midX >= lower - 1 && s.selectionRect.midX <= upper + 1, "T-39 selection stays between the two real tab controls")
                    if s.selectionRect.midX > lower + 1 && s.selectionRect.midX < upper - 1 { middleSelection = true }
                    frameSequence.append(["tabIndex": Double(library.tabs.items.firstIndex { $0.id == id }!),
                        "time": ProcessInfo.processInfo.systemUptime - started,
                        "fromX": Double(oldSelection.midX), "targetX": Double(target.midX),
                        "selectionX": Double(s.selectionRect.midX), "selectionY": Double(s.selectionRect.midY),
                        "incomingAlpha": Double(g.incomingAlpha), "outgoingAlpha": Double(g.outgoingAlpha), "offset": Double(g.offset)])
                }
                if g.isTransitioning && g.incomingAlpha > 0 && g.incomingAlpha < 1 { middleGrid = true }
                if g.incomingAlpha + g.outgoingAlpha < 0.99 { blank = true }
                if abs(g.offset) > 0.01 { translated = true }
                if middleGrid && !capturedMiddle { capture("clipboard-tab-transition-\(library.tabs.items.firstIndex { $0.id == id }!)"); capturedMiddle = true }
                check(pet.placement!.globalBubble == fixed && tabPoint(full) == tabLine, "T-42 frame and tab screen coordinates never change")
                remainsOpen("T-42 native tab click")
                await pause(0.012)
            } while ProcessInfo.processInfo.systemUptime - started < 0.35
            let g = grid()
            check(middleGrid && !blank && !g.isTransitioning, "T-39 real grid crossfade has intermediate opacity and no blank/residue")
            check(reduced ? !translated && !middleSelection : translated && middleSelection, "T-39 selection and grid movement obey reduced motion")
            let elapsed = g.transitionFinished! - g.transitionStarted!
            check((0.1...0.35).contains(elapsed), "T-39 transition duration within specification")
            record("T-39 tab transition duration=\(elapsed) selectionMiddle=\(middleSelection) gridMiddle=\(middleGrid) translated=\(translated)")
            if id == empty {
                let view = grid()
                view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("T-42 empty grid capture") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { fail("T-42 empty grid image") }
                let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["ko-KR", "en-US"]; request.recognitionLevel = .accurate
                do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { fail("T-42 actual Vision failed") }
                let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().replacingOccurrences(of: " ", with: "")
                check(visible.contains("아직없어요"), "T-42 empty tab visibly shows 아직 없어요 (actual Vision)")
                capture("clipboard-interaction-empty")
            }
        }
        capture("clipboard-interaction-tabs")
        // T-43: current tab, unused canvas and focus changes never run the pet's click handler.
        await click(tabPoint(full)); await pause(); remainsOpen("T-43 current tab")
        let host = pet.subviews.first { $0 is NSHostingView<ClipboardShelf> }!
        let blankPoint = panel.convertPoint(toScreen: host.convert(CGPoint(x: host.bounds.width - 6, y: host.bounds.height / 2), to: nil))
        await click(blankPoint); await pause(); remainsOpen("T-43 blank area")
        panel.makeKey(); panel.resignKey(); await pause(); remainsOpen("T-43 key changes")
        func cancelTrackingSoon() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                NSApp.postEvent(event, atStart: true)
            }
        }
        func dismissMenu(at point: CGPoint, right: Bool = false) async {
            var opened = false, ended = false
            let begin = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                opened = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!, atStart: true)
                }
            }
            let end = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in ended = true }
            pointer = point; warp(point)
            if right {
                NSApp.postEvent(event(.rightMouseDown, at: point), atStart: false)
                NSApp.postEvent(event(.rightMouseUp, at: point), atStart: false)
            } else { await click(point) }
            await wait("T-43 native menu actually opens", { opened })
            await wait("T-43 native menu actually ends", { ended })
            NotificationCenter.default.removeObserver(begin); NotificationCenter.default.removeObserver(end)
            await pause(0.1)
        }
        let plainHost = NSHostingView(rootView: EmptyView())
        record("default hosting first mouse=\(plainHost.acceptsFirstMouse(for: nil)); shelf first mouse=\(host.acceptsFirstMouse(for: nil))")
        let more = controlPoint("clipboard-more")
        await dismissMenu(at: more); remainsOpen("T-43 more menu closes")
        let plus = controlPoint("clipboard-add")
        await click(plus); await pause(); remainsOpen("T-43 add tab")
        await click(plus); await pause(); remainsOpen("T-43 add tab closes")
        let field = require(descendants(pet, NSTextField.self).first { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == ClipboardSearch.placeholder }, "Native search field")
        await click(nativePoint(field)); await pause(); remainsOpen("T-43 search click")
        let editor = panel.firstResponder as! NSTextView
        editor.insertText("no matching result", replacementRange: NSRange(location: NSNotFound, length: 0)); await pause(2)
        remainsOpen("T-44 zero search results with stationary pointer")
        check(pet.placement!.globalBubble == fixed && tabPoint(full) == tabLine, "T-42 zero search results keep geometry")
        // T-39 keyboard uses the very same animation, and keeps the native search text.
        key(48); await pause(0.04); key(124)
        await wait("T-39 keyboard selected another tab", { library.tabs.current.id != full })
        await pause(0.08)
        check(grid().isTransitioning && (reduced ? grid().offset == 0 : grid().offset != 0), "T-39 keyboard animates grid")
        await pause(); check(field.stringValue == "no matching result", "T-39 keyboard preserves query")
        let overflow = library.tabs.items[6].id
        while library.tabs.current.id != library.tabs.items[5].id {
            let before = library.tabs.current.id; key(124)
            await wait("T-39 keyboard advances through visible tabs", { library.tabs.current.id != before }); await pause(0.28)
        }
        let beforeOverflow = selection().selectionRect
        key(124)
        await wait("T-39 keyboard selects overflow tab", { library.tabs.current.id == overflow && selection().tabRects[overflow] != nil })
        await pause(0.07)
        let middleOverflow = selection().selectionRect
        let overflowTarget = require(selection().tabRects[overflow], "Overflow target frame")
        check(reduced ? middleOverflow == overflowTarget : middleOverflow.midX > min(beforeOverflow.midX, overflowTarget.midX) + 1 && middleOverflow.midX < max(beforeOverflow.midX, overflowTarget.midX) - 1, "T-39 overflow selection obeys the same motion rule")
        await pause(0.3)
        let moreProbe = require(descendants(pet, NSView.self).first { $0.identifier?.rawValue == "clipboard-more" }, "Measured more control")
        let moreFrame = moreProbe.convert(moreProbe.bounds, to: selection())
        check(abs(selection().selectionRect.midX - moreFrame.midX) <= 1 && abs(selection().selectionRect.midY - moreFrame.midY) <= 1, "T-39 overflow selection lands on the real more control")
        check(field.stringValue == "no matching result", "T-39 overflow selection retains query")
        record("PASS T-39 overflow tab selection and query retention")
        capture("clipboard-overflow-selection")
        do { try JSONSerialization.data(withJSONObject: ["frames": frameSequence], options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("clipboard-tab-frames.json")) }
        catch { fail("T-39 numeric frame sequence write") }
        key(3, .command, chars: "f"); (panel.firstResponder as! NSTextView).selectAll(nil)
        (panel.firstResponder as! NSTextView).insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        library.editTabs { $0.selected = full }; await pause()
        let trash = require(descendants(pet, ClipboardTrashView.self).first, "Native trash control")
        cancelTrackingSoon(); await click(nativePoint(trash)); await pause(); remainsOpen("T-43 trash cancel")
        let card = require(descendants(pet, ClipboardCardView.self).first { !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: pet).intersects(grid().convert(grid().bounds, to: pet)) }, "Visible context card")
        let cardPoint = nativePoint(card)
        check(pet.hitTest(panel.convertPoint(fromScreen: cardPoint)) === card, "T-43 context click reaches a visible card")
        await dismissMenu(at: cardPoint, right: true); remainsOpen("T-43 card menu closes")
        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -100, wheel2: 0, wheel3: 0)!
        let scroll = descendants(grid(), NSScrollView.self).first!
        let beforeScroll = scroll.contentView.bounds.origin
        let scrollPoint = panel.convertPoint(fromScreen: cardPoint)
        scrollEvent.location = CGPoint(x: scrollPoint.x, y: NSScreen.screens.first!.frame.maxY - scrollPoint.y)
        if let native = NSEvent(cgEvent: scrollEvent) { panel.sendEvent(native) }
        await pause(); remainsOpen("T-43 scroll")
        check(scroll.contentView.bounds.origin != beforeScroll, "T-43 wheel reaches the native scrolling grid")
        // T-44: geometry alone, even a forced placement outside the pointer, cannot arm exit.
        await move(tabPoint(full)); let actual = pet.placement!
        let oldTick = pet.onAnimationTick; pet.onAnimationTick = nil
        pet.placement = PetPlacement(globalSprite: actual.globalSprite, globalBubble: actual.globalBubble.offsetBy(dx: 600, dy: 0), userScale: pet.petScale, expanded: false)
        pet.layoutSubtreeIfNeeded(); await pause(2)
        remainsOpen("T-44 layout moves away from stationary pointer")
        pet.placement = actual; pet.onAnimationTick = oldTick; await pause()
        library.delete(library.entries[0]); await wait("T-42 delete card", { library.entries.count == 7 })
        check(pet.placement!.globalBubble == fixed && tabPoint(full) == tabLine, "T-42 deletion preserves frame and tab coordinates")
        library.clear(includingPins: true); await wait("T-44 clear records", { library.entries.isEmpty }); await pause(2)
        remainsOpen("T-44 no records with stationary pointer")
        await move(outside, delay: 0.2); await move(tabPoint(full), delay: 0.2); remainsOpen("T-44 short excursion returns")
        await move(outside, delay: 0.5); check(!pet.clipboardPresented, "T-44 sustained real pointer exit closes")
        library.add(ClipboardInput(kind: .text, text: "revisit", source: "fixture")); await wait("T-40 revisit fixture", { library.entries.count == 1 })
        // T-40: every close path is followed by an actual off-head/on-head event, five times each.
        for cycle in 0..<5 {
            for mode in 0..<5 {
                await move(outside); await move(head()); await clipboardSmokeOpenDrawer(pet, panel: panel); await wait("T-40 shelf reopens", { pet.clipboardPresented }); await pause(0.3)
                switch mode {
                case 0: await move(outside)
                case 1: key(53, chars: "\u{1b}"); await pause(0.05); check(!pet.clipboardPresented, "T-44 Escape closes immediately")
                case 2: await click(outside); await pause(0.05); check(!pet.clipboardPresented, "T-44 outside click closes immediately")
                case 3:
                    library.editTabs { $0.selected = full }; await pause()
                    let live = require(descendants(pet, ClipboardCardView.self).first { !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: pet).intersects(grid().convert(grid().bounds, to: pet)) }, "Visible copy card")
                    let count = board.changeCount; await click(nativePoint(live)); await wait("T-40 card copies", { board.changeCount > count })
                    check(!chatExpanded && pet.clipboardPresented, "T-41 card copies without opening conversation")
                    await move(outside)
                default:
                    await click(head()); await wait("T-41 open-shelf head click opens chat", { chatExpanded && !pet.clipboardPresented })
                    collapseChat(); await pause(0.8); await move(outside)
                }
                await move(outside); await move(head()); await clipboardSmokeOpenDrawer(pet, panel: panel); await wait("T-40 revisit after every close path", { pet.clipboardPresented })
                record("T-40 cycle=\(cycle) closePath=\(mode) reopen=true")
            }
        }
        // T-41: closed shelf, double click and no-history routes keep the existing conversation contract.
        key(53, chars: "\u{1b}"); await pause(0.1)
        await click(head()); await wait("T-41 closed-shelf head click", { chatExpanded && !pet.clipboardPresented })
        await click(head(), clicks: 2); await pause(); check(chatExpanded, "T-41 second click of a double click leaves chat open")
        collapseChat(); await pause(0.8); await move(outside)
        library.clear(includingPins: true); await wait("T-41 zero records", { library.entries.isEmpty })
        await click(head()); await wait("T-41 no-history head click", { chatExpanded })
        collapseChat(); await pause(0.8); await move(outside)
        library.editTabs { $0 = originalTabs }; await wait("interaction restores tabs", { library.tabs.items == originalTabs.items })
        record("PASS T-39 T-40 T-41 T-42 T-43 T-44")
        try! (log.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("clipboard-interaction.txt"), atomically: true, encoding: .utf8)
    }
}
