import AppKit
import SwiftUI
import Carbon

extension AppDelegate {
    /// Exercise selection and card clicks through AppKit; restore user state before reporting failure.
    func verifySlackSelection(destination: URL) {
        Task { @MainActor [self] in
            let originalApp = smokeForeground
            defer { originalApp?.activate(options: []) }
            let board = NSPasteboard.general
            let originalInput = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            var failures: [String] = [], checks: [String] = []
            @MainActor func check(_ ok: Bool, _ title: String) {
                checks.append("\(ok ? "PASS" : "FAIL"): \(title)")
                if !ok { failures.append(title) }
                try? checks.joined(separator: "\n").write(to: destination.appendingPathComponent("selection-checks.txt"), atomically: true, encoding: .utf8)
            }
            let saved = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
            let backup = try? PropertyListSerialization.data(fromPropertyList: saved.map { pairs in Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.rawValue, $0.1) }) }, format: .binary, options: 0)
            try? backup?.write(to: destination.appendingPathComponent("pasteboard-backup.plist"), options: .atomic)
            defer {
                check(TISSelectInputSource(originalInput) == noErr, "Restore the original input source")
                board.clearContents()
                board.writeObjects(saved.map { pairs in
                    let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1, forType: $0.0) }; return item
                })
                let restored = (board.pasteboardItems ?? []).map { item in Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType:type).map { (type.rawValue,$0) } }) }
                let expected = saved.map { pairs in Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.rawValue,$0.1) }) }
                check(restored == expected, "Restore every original pasteboard item and type")
                try? "restored: \(restored == expected)\n".write(to: destination.appendingPathComponent("pasteboard-restored.txt"), atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: destination.appendingPathComponent("pasteboard-backup.plist"))
            }
            let model = slack.model
            var results: [[String: Any]] = []
            @MainActor func write() {
                if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: destination.appendingPathComponent("selection.json"))
                }
            }
            @MainActor func settle() async { try? await Task.sleep(nanoseconds: 350_000_000) }
            @MainActor func event(_ type: NSEvent.EventType, _ point: NSPoint, _ count: Int = 1) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
            }
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            @MainActor func textPoints(_ id: String) -> [NSPoint] {
                guard let view = model.rowViews.object(forKey: ("message:" + id) as NSString), let content = panel.contentView else { return [] }
                let rect = view.convert(view.bounds, to: nil)
                var points: [NSPoint] = []
                for y in stride(from: rect.maxY - 2, through: rect.minY + 2, by: -3) {
                    for x in stride(from: rect.minX + 2, through: rect.maxX - 2, by: 3) {
                        let point = NSPoint(x: x, y: y)
                        if let hit = content.hitTest(point), String(describing: type(of: hit)).contains("TextInteraction") || hit is NSTextView {
                            points.append(point)
                        }
                    }
                }
                return points
            }
            @MainActor func message(_ id: String, _ text: String, own: Bool = false) -> ChatMessage {
                var item = ChatMessage(id: id, fromUser: own, speaker: own ? "나" : "SNS담당", body: text, date: Date(), profile: own ? "" : "sns-manager")
                if text.hasPrefix("기존 값 수정 ·") { item.slackUserID = ShrimpVault.defaultBot }
                return item
            }
            @MainActor func fixture(_ body: String, replies: Int = 0, expanded: Bool = false, own: Bool = false) async {
                model.onSend = nil; model.onOpen = { _ in }
                model.typing = [:]; model.open = []; model.picked = nil
                model.threads = []; await settle()
                let root = message("selection-root", body, own: own)
                let answers = (0..<replies).map { message("selection-reply-\($0)", "Reply\($0) delta epsilon zeta 답글 선택 확인") }
                model.threads = [SlackThread(id: "selection-thread", room: model.selected ?? "CCOW", ts: "9000.1", root: root,
                                            replies: answers, replyCount: replies, loaded: true, latest: root.date.timeIntervalSince1970, latestFromUser: own)]
                if expanded { model.open = ["selection-thread"] }
                // Selection trials start at the root, including when a taller header pushes it above the viewport.
                model.requestScroll("message:selection-root")
                await settle()
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(nil)
            }
            @MainActor func trial(_ name: String, start: NSPoint?, end: NSPoint? = nil, clicks: Int = 1, korean: Bool = false, required: Bool = true, copies: Bool = true, openAfter: Bool? = nil, exact: String? = nil, messageID: String = "selection-root") async {
                guard let start else { results.append(["case": name, "error": "No selectable text hit target"]); if required { check(false, name + ": missing mouse target") }; write(); capture(destination: destination.appendingPathComponent(name)); return }
                let before = model.open.sorted()
                let activeBefore = NSApp.isActive
                let keyBefore = panel.isKeyWindow
                let frame = panel.frame
                let hit = panel.contentView?.hitTest(start)
                board.clearContents(); board.setString("SELECTION-SENTINEL", forType: .string)
                // Queue the whole gesture: native text's mouseDown runs a tracking loop until mouseUp.
                if clicks > 1 {
                    NSApp.postEvent(event(.leftMouseDown, start), atStart: false)
                    NSApp.postEvent(event(.leftMouseUp, start), atStart: false)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                NSApp.postEvent(event(.leftMouseDown, start, clicks), atStart: false)
                if let end {
                    for step in 1...8 {
                        let t = CGFloat(step) / 8
                        NSApp.postEvent(event(.leftMouseDragged, NSPoint(x: start.x + (end.x-start.x)*t, y: start.y + (end.y-start.y)*t)), atStart: false)
                    }
                }
                NSApp.postEvent(event(.leftMouseUp, end ?? start, clicks), atStart: false)
                await settle()
                let responder = String(describing: panel.firstResponder)
                let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil, characters: korean ? "ㅊ" : "c",
                                          charactersIgnoringModifiers: korean ? "ㅊ" : "c", isARepeat: false, keyCode: 8)!
                NSApp.sendEvent(key)
                await settle()
                let menu = panel.contentView?.hitTest(start)?.menu(for: event(.rightMouseDown, start))
                results.append(["case": name, "clipboard": board.string(forType: .string) ?? "<nil>",
                                "acceptsFirstMouse": hit?.acceptsFirstMouse(for: event(.leftMouseDown, start)) ?? false,
                                "hit": String(describing: hit.map { type(of: $0) }), "responder": responder,
                                "menu": menu?.items.map { $0.title } ?? [], "menuPresent": menu != nil,
                                "openBefore": before, "openAfter": model.open.sorted(), "windowMoved": frame != panel.frame,
                                "active": NSApp.isActive, "key": panel.isKeyWindow, "activeBefore": activeBefore, "keyBefore": keyBefore,
                                "start": NSStringFromPoint(start), "end": end.map(NSStringFromPoint) ?? "click"])
                if required {
                    if copies {
                        let copied = board.string(forType: .string) ?? ""
                        let bodies = model.threads.flatMap(\.messages).filter { $0.id == messageID }.map(\.body)
                        check(!copied.isEmpty && copied != "SELECTION-SENTINEL" && bodies.contains(where: { $0.contains(copied) }), name + ": copies text from the displayed message")
                        if let exact { check(copied == exact, name + ": copies the selected word") }
                        check(menu?.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }) == true, name + ": selection menu has Copy")
                    }
                    if let openAfter { check(model.open.contains("selection-thread") == openAfter, name + ": expected expanded state") }
                    if end != nil {
                        check(model.open.sorted() == before, name + ": drag does not open or fold the card")
                        check(panel.frame == frame, name + ": drag does not move or resize the window")
                    }
                }
                write(); capture(destination: destination.appendingPathComponent(name))
            }
            @MainActor func range(_ id: String = "selection-root") -> (NSPoint?, NSPoint?) {
                let points = textPoints(id)
                guard let top = points.first else { return (nil, nil) }
                let line = points.filter { abs($0.y - (top.y-6)) < 2 }
                guard let first = line.first, let last = line.last else { return (top, NSPoint(x: top.x+80, y: top.y)) }
                return (NSPoint(x: first.x+8, y: first.y), NSPoint(x: min(first.x+105,last.x-2), y: first.y))
            }
            /// The native list draws links inside AppKit text; this finds the first one's glyphs in the window.
            @MainActor func nativeLinkPoint() -> NSPoint? {
                guard NativeListFeature.enabled else { return nil }
                for text in descendants(panel.contentView!).compactMap({ $0 as? NSTextView }) where !text.isEditable && !text.isHiddenOrHasHiddenAncestor {
                    guard let storage = text.textStorage, let manager = text.layoutManager, let container = text.textContainer else { continue }
                    var found: NSRange?
                    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                        if let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true { found = range; stop.pointee = true }
                    }
                    guard let range = found else { continue }
                    let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                    rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
                    return text.convert(NSPoint(x: rect.minX + 8, y: rect.midY), to: nil)
                }
                return nil
            }
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
            var opened: [URL] = []
            chat.onOpenLink = { opened.append($0) }
            await fixture("Alpha bravo charlie 한글 선택 확인", replies: 3)
            var pair = range()
            await trial("a-collapsed-drag", start: pair.0, end: pair.1)
            await fixture("Alpha bravo charlie 한글 선택 확인", replies: 3)
            pair = range()
            await trial("card-collapsed-text-click", start: pair.0, copies: false, openAfter: true)
            await fixture("Alpha bravo charlie 한글 선택 확인", replies: 3, expanded: true)
            pair = range()
            await trial("card-expanded-text-click", start: pair.0, copies: false, openAfter: true)
            if let view = model.rowViews.object(forKey: "selection-thread") {
                let rect = view.convert(view.bounds, to: nil)
                await trial("card-expanded-blank-click", start: NSPoint(x: rect.maxX-4, y: rect.maxY-6), copies: false, openAfter: false)
            } else { check(false, "Expanded card has a measured blank click target") }
            await fixture("Alpha bravo charlie 한글 선택 확인", replies: 3, expanded: true)
            pair = range(); await trial("b-expanded-root", start: pair.0, end: pair.1)
            pair = range("selection-reply-0"); await trial("b-expanded-reply", start: pair.0, end: pair.1, messageID: "selection-reply-0")
            await fixture("Alpha bravo charlie 한글 선택 확인", replies: 2)
            pair = range(); await trial("c-short", start: pair.0, end: pair.1)
            await trial("h-double", start: pair.0, clicks: 2, exact: "Alpha")
            await fixture("Alpha bravo charlie 한글 선택 확인", replies: 3)
            pair = range()
            await trial("h-collapsed-double", start: pair.0, clicks: 2, exact: "Alpha")
            await fixture("Alpha bravo charlie 한글 선택 확인", replies: 2)
            pair = range()
            let inputs = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
            if let korean = inputs.first(where: { source in
                guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
                return (Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String) == "com.apple.inputmethod.Korean.2SetKorean"
            }) {
                check(TISSelectInputSource(korean) == noErr, "Select the Korean two-set input source")
                await settle()
                await trial("i-korean-key-event", start: pair.0, clicks: 2, korean: true, exact: "Alpha")
                TISSelectInputSource(originalInput)
            } else { check(false, "Korean two-set input source is available for the shortcut check") }
            let reply = range("selection-reply-0")
            await trial("g-across-messages", start: pair.0, end: reply.1, required: false)
            await fixture("Alpha bravo charlie\n\nDelta epsilon zeta")
            pair = range(); await trial("e-within-paragraph", start: pair.0, end: pair.1)
            let points = textPoints("selection-root")
            await trial("e-across-paragraphs", start: pair.0, end: points.last.map { NSPoint(x: $0.x-10,y:$0.y+6) }, required: false)
            await fixture("Alpha bravo charlie\n> Delta epsilon zeta\nEcho foxtrot golf")
            pair = range()
            let quotePoints = textPoints("selection-root")
            await trial("e-across-quote-blocks", start: pair.0, end: quotePoints.last.map { NSPoint(x:$0.x-10,y:$0.y+6) }, required: false)
            await fixture("Alpha bravo charlie 내가 작성한 글", own: true)
            pair = range(); await trial("f-own-message", start: pair.0, end: pair.1)
            await fixture("Alpha bravo charlie 내가 작성한 글", replies: 3, own: true)
            pair = range(); await trial("f-own-collapsed-drag", start: pair.0, end: pair.1)
            await trial("f-own-collapsed-click", start: pair.0, copies: false, openAfter: true)
            await fixture("Alpha bravo https://example.com/doc charlie delta")
            pair = range(); await trial("d-adjacent-text", start: pair.0, end: pair.1)
            await fixture("Alpha bravo https://example.com/doc charlie delta", replies: 3)
            let links = descendants(panel.contentView!).compactMap { $0 as? LinkCursorView }
            if let link = links.first(where: { view in view.rects.contains { rect in panel.contentView?.hitTest(view.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil)) === view } }), let rect = link.rects.first {
                let point = link.convert(NSPoint(x:rect.minX+8,y:rect.midY),to:nil)
                let count = opened.count
                await trial("d-link-start", start: point, end: NSPoint(x:point.x+80,y:point.y), required: false)
                await trial("link-click", start: point, required: false, copies: false)
                check(opened.count == count+1 && opened.last?.absoluteString == "https://example.com/doc", "A link click opens its URL exactly once")
            } else if let point = nativeLinkPoint() {
                let count = opened.count
                await trial("d-link-start", start: point, end: NSPoint(x:point.x+80,y:point.y), required: false)
                await trial("link-click", start: point, required: false, copies: false)
                check(opened.count == count+1 && opened.last?.absoluteString == "https://example.com/doc", "A link click opens its URL exactly once")
            } else { check(false, "Link click has a live glyph target") }
            // A real foreground application must keep its place while the panel starts selection.
            await fixture("Alpha bravo charlie 한글 선택 확인", replies: 3)
            pair = range()
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                other.activate(options: [.activateAllWindows])
                for _ in 0..<10 {
                    if !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier { break }
                    await settle()
                }
                let inactive = !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier
                check(inactive, "Finder is foreground and the panel application is inactive before the first drag")
                results.append(["case": "inactive-setup", "confirmed": inactive, "active": NSApp.isActive, "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"])
                if inactive {
                    await trial("inactive-first-drag", start: pair.0, end: pair.1)
                    check(NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier, "First drag preserves the foreground application")
                    await trial("inactive-second-drag", start: pair.0, end: pair.1)
                }
            } else { check(false, "Finder is available for the first-drag check") }
            @MainActor func makeInactive(_ title: String) async -> Bool {
                guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { check(false, title + ": Finder missing"); return false }
                panel.resignKey(); NSApp.deactivate()
                other.activate(options: [.activateAllWindows])
                for _ in 0..<10 {
                    if !NSApp.isActive && !panel.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier { break }
                    await settle()
                }
                let ready = !NSApp.isActive && !panel.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier
                check(ready, title + ": starts inactive with Finder foreground")
                return ready
            }
            @MainActor func measuredPoint(_ identifier: String) -> NSPoint? {
                // In the native list the approval row is a hosted piece; its first button starts where the words start.
                if NativeListFeature.enabled, identifier.hasPrefix("approve-"), let host = model.rowViews.object(forKey: "approval:selection-root") {
                    let rect = host.convert(host.bounds, to: nil)
                    return NSPoint(x: rect.minX + ChatMetrics.avatar + 9 + 24, y: rect.midY)
                }
                guard let rect = chat.smokeFrames[identifier], rect.width > 0, rect.height > 0,
                      let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first else { return nil }
                return host.convert(NSPoint(x: rect.midX, y: host.isFlipped ? rect.midY : host.bounds.height-rect.midY), to: nil)
            }
            await fixture("Alpha bravo charlie", replies: 3)
            pair = range()
            if await makeInactive("Inactive collapsed card") {
                await trial("inactive-card-open", start: pair.0, copies: false, openAfter: true)
            }
            await fixture("Alpha bravo charlie", replies: 3, expanded: true)
            if let view = model.rowViews.object(forKey: "selection-thread") {
                let rect = view.convert(view.bounds, to: nil)
                if await makeInactive("Inactive expanded card") {
                    await trial("inactive-card-fold", start: NSPoint(x: rect.maxX-4, y: rect.maxY-6), copies: false, openAfter: false)
                }
            } else { check(false, "Inactive expanded card has a blank target") }
            await fixture("Alpha bravo https://example.com/doc charlie", replies: 3)
            let inactiveLinks = descendants(panel.contentView!).compactMap { $0 as? LinkCursorView }
            if let link = inactiveLinks.first(where: { view in view.rects.contains { rect in panel.contentView?.hitTest(view.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil)) === view } }), let rect = link.rects.first {
                let point = link.convert(NSPoint(x: rect.minX+8, y: rect.midY), to: nil)
                let count = opened.count
                if await makeInactive("Inactive link") {
                    await trial("inactive-link-click", start: point, required: false, copies: false)
                    check(opened.count == count+1, "Inactive link opens exactly once on its first click")
                }
            } else if let point = nativeLinkPoint() {
                let count = opened.count
                if await makeInactive("Inactive link") {
                    await trial("inactive-link-click", start: point, required: false, copies: false)
                    check(opened.count == count+1, "Inactive link opens exactly once on its first click")
                }
            } else { check(false, "Inactive link has a target") }
            await fixture("변경하려면 승인해 주세요.")
            var approvals: [String] = []
            model.onSend = { text, _, _, _ in approvals.append(text) }
            if await makeInactive("Inactive approval") {
                await trial("inactive-approve-click", start: measuredPoint("approve-selection-thread"), copies: false)
                check(approvals == ["승인"], "Inactive approval first click sends exactly one synthetic answer")
            }
            model.onSend = nil
            model.writeNewPost(); model.draft = ""; await settle()
            if let editor = descendants(panel.contentView!).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }) {
                let point = editor.convert(NSPoint(x: min(10, editor.bounds.width/2), y: min(10, editor.bounds.height/2)), to: nil)
                if await makeInactive("Inactive input") {
                    await trial("inactive-input-click", start: point, copies: false)
                    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
                    NSApp.sendEvent(key); await settle()
                    check(model.draft == "x", "Inactive input accepts typing immediately after its first click")
                }
            } else { check(false, "Inactive input has an editable target") }
            if let room = model.rooms.first(where: { $0.id != model.selected && measuredPoint("room-" + $0.id) != nil }) {
                let point = measuredPoint("room-" + room.id)
                if await makeInactive("Inactive room tab") {
                    await trial("inactive-room-click", start: point, copies: false)
                    check(model.selected == room.id, "Inactive room tab selects its room on the first click")
                }
            } else { check(false, "Inactive room tab has a target") }
            let fieldsText = "선택: 가짜표.xlsx → Sheet1 시트 → 김가짜\n- 이름: 김가짜\n- id: FAKE-ID\n- pw: 0011000\n- 홈페이지: 444"
            await fixture(fieldsText, replies: 3, expanded: true)
            model.clipboard = NSPasteboard.withUniqueName()
            if let thread = model.threads.first { model.copy(thread) }
            check(model.clipboard.string(forType: .string)?.contains(fieldsText) == true, "Whole-message copy retains all copyable fields")
            model.clipboard.releaseGlobally(); model.clipboard = .general
            capture(destination: destination.appendingPathComponent("worksheet-fields"))
            originalApp?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            for _ in 0..<10 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApp?.processIdentifier { break }
                await settle()
            }
            results.append(["case": "restore-foreground", "original": originalApp?.bundleIdentifier ?? "nil", "actual": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", "originalIsSmoke": originalApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier])
            check(originalApp == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApp?.processIdentifier, "Restore the original foreground application")
            write()
            DispatchQueue.main.async {
                smokeCheck(failures.isEmpty, failures.joined(separator: "; "))
                print("PASS: \(checks.count) Slack selection and card-click checks")
                NSApp.terminate(nil)
            }
        }
    }
}
