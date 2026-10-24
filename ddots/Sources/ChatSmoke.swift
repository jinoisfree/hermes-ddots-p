import AppKit
import SQLite3
import SwiftUI

/// Explicit UI test mode only; never opens the user's Hermes home or sends messages.
enum ChatSmokeFixture {
    static func create() -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-chat-smoke-\(UUID().uuidString)")
        SmokeLeftovers.note(home)
        let profiles = ["default","personal-secretary","archive-helper","sns-manager","system-doctor"]
        let names = ["default":"위키담당", "personal-secretary":"개인비서", "archive-helper":"보관담당", "sns-manager":"SNS담당", "system-doctor":"진단담당"]
        let colors = ["default":"#8b5cf6", "personal-secretary":"hsl(38 72% 58%)", "archive-helper":"hsl(220 24% 18%)", "sns-manager":"hsl(220 12% 22%)", "system-doctor":"hsl(91 68% 58%)"]
        for profile in profiles {
            let root = profile == "default" ? home : home.appendingPathComponent("profiles/\(profile)")
            try! FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
            if profile == "default" || profile == "archive-helper" {
                let assets = root.appendingPathComponent("assets")
                try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let color: NSColor = profile == "default" ? .systemOrange : .systemBlue
                let rgb = color.usingColorSpace(.sRGB)!
                for y in 0..<80 { for x in 0..<80 {
                    let pixel = bitmap.bitmapData!.advanced(by: y * bitmap.bytesPerRow + x * 4)
                    pixel[0] = UInt8(rgb.redComponent * 255); pixel[1] = UInt8(rgb.greenComponent * 255)
                    pixel[2] = UInt8(rgb.blueComponent * 255); pixel[3] = 255
                } }
                try! bitmap.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("slack-avatar.png"))
            }
            try! "display_name: \(names[profile]!)\nui_meta:\n  hermes-bots:\n    color: '\(colors[profile]!)'\n".write(to:root.appendingPathComponent("profile.yaml"),atomically:true,encoding:.utf8)
            var handle: OpaquePointer?
            smokeCheck(sqlite3_open(root.appendingPathComponent("state.db").path,&handle) == SQLITE_OK)
            let db = handle!
            let schema = """
            CREATE TABLE sessions(id TEXT PRIMARY KEY,source TEXT);
            CREATE TABLE messages(id INTEGER PRIMARY KEY,session_id TEXT,role TEXT,content TEXT,timestamp REAL,tool_calls TEXT);
            CREATE TABLE session_turn_leases(conversation_id TEXT,holder TEXT,acquired_at REAL,expires_at REAL);
            INSERT INTO sessions VALUES ('fixture','photon');
            BEGIN;
            """
            smokeCheck(sqlite3_exec(db,schema,nil,nil,nil) == SQLITE_OK)
            for index in 0..<400 {
                let role = index % 3 == 0 ? "user" : "assistant"
                let body = index == 20 ? "기억용특허 과거 자료 확인" : "특허관련내용 \(index) **자료 검토 완료**\n문서 내용을 검토하고 다음 작업을 정리했습니다. https://example.com/doc"
                let time = Date().timeIntervalSince1970 - 2000 + Double(index * 5)
                let sql = "INSERT INTO messages VALUES (\(index+1),'fixture','\(role)','\(body)',\(time),NULL)"
                smokeCheck(sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK)
            }
            smokeCheck(sqlite3_exec(db,"COMMIT",nil,nil,nil) == SQLITE_OK)
            sqlite3_close(db)
        }
        return home
    }
}

extension AppDelegate {
    func verifyChatSearch(destination: URL, draft: String) {
        if !IMessageFeature.enabled { verifySlackOnlyChat(destination: destination); return }
        chat.loadOlder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            smokeCheck(chat.messages.count == 80,"Older history loads forty rows")
            collapseChat(); showChat()
            smokeCheck(chat.messages.count == 40,"Reopening returns to forty recent rows")
            let find = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"f",charactersIgnoringModifiers:"f",isARepeat:false,keyCode:3)!
            smokeCheck(panel.performKeyEquivalent(with:find) && chat.searchOpen,"Command-F opens search")
            // Type after the search field has appeared and acquired focus, as a user does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                chat.query = "없는검색어"
                chat.query = "기억용특허" // Debounce must discard the previous request.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                    smokeCheck(chat.results.count == 5 && !chat.searching,"Debounced search merges profiles")
                    capture(destination:destination.appendingPathComponent("search"))
                    panel.cancelOperation(nil)
                    smokeCheck(chatExpanded && !chat.searchOpen,"Escape first closes search only")
                    chat.openSearch()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        let down = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:125)!
                        panel.sendEvent(down)
                        smokeCheck(chat.selection == 1,"Down arrow selects the next result")
                        let target = chat.results[chat.selection].id
                        let enter = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
                        panel.sendEvent(enter)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                            smokeCheck(!chat.searchOpen && chat.historical && chat.messages.count == 41)
                            smokeCheck(chat.messages.contains { $0.id == target } && chat.highlightedID == target,"Old result is loaded and highlighted")
                            smokeCheck(chat.draft == draft,"Search preserves the draft")
                            capture(destination:destination.appendingPathComponent("search-target"))
                            chat.resetPage()
                            smokeCheck(!chat.historical && chat.messages.count == 40)
                            chat.typing = [TypingIndicator(id:"fixture-typing",speaker:"보관담당",profile:"archive-helper")]
                            pet.chatAnimation = .replyWaiting
                            DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [self] in
                                capture(destination:destination.appendingPathComponent("typing"))
                                panel.cancelOperation(nil)
                                smokeCheck(!chatExpanded && !panel.canBecomeKey)
                                smokeCheck(pet.subtitle == "보관담당 작성 중…")
                                DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [self] in
                                    capture(destination:destination.appendingPathComponent("typing-collapsed"))
                                    verifyAvatarPresentation(destination: destination)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func verifyAvatarPresentation(destination: URL) {
        showChat()
        chat.messages = [("default", "위키담당"), ("archive-helper", "보관담당")].enumerated().map { index, character in
            ChatMessage(id: "avatar-preview:\(index)", fromUser: false, speaker: character.1, body: "합성 사진·첫 글자 표시 확인", date: Date(), profile: character.0)
        }
        chat.hasOlder = false
        chat.typing = [TypingIndicator(id: "avatar-preview-typing", speaker: "개인비서", profile: "personal-secretary")]
        chat.requestScroll("chat-bottom")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            capture(destination: destination.appendingPathComponent("avatars"))
            let normal = chat.smokeFrames["name:default"]!, typing = chat.smokeFrames["name:typing"]!
            smokeCheck(abs(normal.minX-typing.minX) < 0.5, "Typing and normal speaker labels align")
            smokeCheck(abs(chat.smokeFrames["bubble:default"]!.minX-chat.smokeFrames["bubble:typing"]!.minX) < 0.5, "Typing and normal reply edges align")
            smokeCheck(chat.smokeFrames["avatar:default"]!.size == NSSize(width:ChatMetrics.avatar,height:ChatMetrics.avatar), "Actual avatar frame matches the shared metric")
            smokeCheck(chat.smokeFrames["caller:default"]!.width == ChatMetrics.callerAvatar)
            smokeCheck(chat.darkPalettes["default"]!.background != chat.darkPalettes["archive-helper"]!.background && chat.lightPalettes["default"]!.background != chat.lightPalettes["archive-helper"]!.background, "Characters have distinct bubble colors")
            try! "speaker x: \(normal.minX), typing x: \(typing.minX), avatar: \(chat.smokeFrames["avatar:default"]!.size)\n".write(to:destination.appendingPathComponent("style-layout.txt"),atomically:true,encoding:.utf8)
            verifyStyleControls(destination: destination)
        }
    }
    private func pressChatControl(_ key: String) {
        let rect = chat.smokeFrames[key]!
        let host = pet.subviews.compactMap { $0 as? NSHostingView<ChatView> }.first!
        let point = host.convert(NSPoint(x:rect.midX,y:host.isFlipped ? rect.midY : host.bounds.height-rect.midY),to:nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!,atStart:false)
        }
    }
    private func verifyStyleControls(destination: URL) {
        let draft = chat.draft
        pressChatControl("caller:default")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [self] in
            smokeCheck(chat.draft == "위키담당, " + draft, "Photo button inserts the character name")
            pressChatControl("caller:archive-helper")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [self] in
                smokeCheck(chat.draft == "보관담당, " + draft, "Photo button replaces the character prefix")
                guard let editor = panel.firstResponder as? NSTextView else { smokeFailed("Calling must focus the draft") }
                smokeCheck(editor.selectedRange().location == (editor.string as NSString).length, "Calling moves the caret to the end")
                capture(destination:destination.appendingPathComponent("calling"))
                pressChatControl("caller:archive-helper")
                DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [self] in
                    smokeCheck(chat.draft == draft, "Calling the same character again removes the prefix")
                    verifyLongReply(destination:destination)
                }
            }
        }
    }
    private func verifyLongReply(destination: URL) {
        let body = (1...16).map { "**긴 답 \($0)** · [링크](https://example.com)" }.joined(separator:"\n") + "\n검색표적"
        let message = ChatMessage(id:"style-long:1",fromUser:false,speaker:"위키담당",body:body,date:Date(),profile:"default")
        chat.typing = []; chat.messages = [message]; chat.requestScroll("chat-bottom")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [self] in
            smokeCheck(!chat.expandedReplies.contains(message.id) && String(chat.displayedText(message).characters).components(separatedBy:"\n").count <= LongReply.lineLimit)
            capture(destination:destination.appendingPathComponent("long-collapsed"))
            pressChatControl("fold:" + message.id)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [self] in
                smokeCheck(chat.expandedReplies.contains(message.id), "More button expands the long reply")
                capture(destination:destination.appendingPathComponent("long-expanded"))
                chat.toggleReply(message.id)
                chat.query = "검색표적"
                chat.showContext([message],target:message.id)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [self] in
                    smokeCheck(chat.expandedReplies.contains(message.id) && chat.displayedText(message).runs.contains { $0.backgroundColor != nil }, "Search expands and highlights a hidden phrase")
                    let match = chat.smokeFrames["search-match"]!, viewport = chat.smokeFrames["viewport"]!
                    smokeCheck(match.minY >= viewport.minY && match.maxY <= viewport.maxY, "Hidden search match is visible inside the scroll viewport")
                    capture(destination:destination.appendingPathComponent("long-search"))
                    collapseChat(); showChat()
                    smokeCheck(chat.expandedReplies.contains(message.id), "Expanded replies survive window folding")
                    collapseChat()
                    verifyAvatarNudge(destination:destination)
                }
            }
        }
    }
    private func verifyAvatarNudge(destination: URL) {
        smokeCheck(chat.avatars["default"]?.image != nil && chat.avatars["archive-helper"]?.image != nil, "Two synthetic avatars are decoded")
        smokeCheck(chat.avatars["personal-secretary"]?.image == nil, "Missing avatar uses the initial")
        chat.typing = []; isPreview = false; model.tasks = []; model.paused = false
        nudges = NudgeEngine()
        let now = Date()
        _ = nudges.update(messages: [], now: now.addingTimeInterval(-2), chatOpen: false, muted: false)
        let reply = ChatMessage(id: "default:avatar-nudge", fromUser: false, speaker: "위키담당", body: "사진이 있는 새 답 알림", date: now, profile: "default")
        _ = nudges.update(messages: [reply], now: now, chatOpen: false, muted: false)
        updatePet()
        smokeCheck(pet.bubbleText.avatarName == reply.speaker && pet.bubbleText.avatar?.image != nil, "Collapsed nudge shares the profile avatar")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            capture(destination: destination.appendingPathComponent("avatar-nudge"))
            verifyChat2(destination: destination)
        }
    }
    func finishChatSmoke(destination: URL) {
            let result = "PASS: latest initially visible, inside click/drag, other window single/right click preserved, windowless/panel/file-picking double click preserved, no global outside monitor, other ddots window double click collapses, monitor cleanup, character single opens/double closes, closed double stays open, accessibility toggle, folding draft/latest entry, older paging/reset, Command-F, debounce, arrow/Enter, search context/highlight, Escape precedence, typing open/collapsed, two profile avatars, fallback initials, avatar nudge, aligned speaker/typing frames, character button click/prefix/caret, distinct palettes, long reply fold/expand/search, resize/retain/reset/minimum, unread badge, looping reply computer and approval phone, one-shot reply jump\nsearch ms: \(lastSearchMilliseconds)\n"
            try! result.write(to:destination.appendingPathComponent("interaction.txt"),atomically:true,encoding:.utf8)
            print(result)
            NSApp.terminate(nil)
    }

}

extension AppDelegate {
    /// Drive the real key path with the clipboard put back afterwards.
    /// Selection and pointer checks need a key window; a locked screen cannot count as a passing check.
    func verifyEditKeys(destination: URL, then next: @escaping () -> Void) {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        let draft = chat.draft
        let pointer = NSEvent.mouseLocation
        var log = ""
        func finish(_ note: String) {
            CGWarpMouseCursorPosition(CGPoint(x: pointer.x, y: NSScreen.screens[0].frame.maxY - pointer.y))
            board.clearContents()
            board.writeObjects(saved.map { pairs in let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1, forType: $0.0) }; return item })
            try? (log + note + "\n").write(to: destination.appendingPathComponent("edit-keys.txt"), atomically: true, encoding: .utf8)
            chat.draft = draft; chat.focusDraftRevision += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: next)
        }
        // A failed check must still hand the clipboard back.
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                let detail = "\(message); active=\(NSApp.isActive), key=\(panel.isKeyWindow), front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"), pointer=\(NSEvent.mouseLocation), cursor=\(NSCursor.current), responder=\(String(describing:panel.firstResponder))"
                finish("failed: " + detail); smokeFailed(detail)
            }
        }
        func key(_ character: String, code: UInt16, shift: Bool = false) {
            let flags: NSEvent.ModifierFlags = shift ? [.command, .shift] : .command
            NSApp.sendEvent(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:code)!)
        }
        func step(_ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                if panel.isKeyWindow { work() } else {
                    finish("not checked: another app held the focus (active=\(NSApp.isActive), front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"))")
                    if #available(macOS 15.0, *) { smokeFailed("Link pointer check requires an unlocked screen and a key conversation window") }
                }
            }
        }
        func click(_ point: NSPoint, count: Int) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!, atStart: false)
            }
        }
        let host = pet.subviews.compactMap { $0 as? NSHostingView<ChatView> }.first!
        // Recorded bubble frames go stale once the list scrolls, so find selectable text under the pointer instead.
        // Latest entry can show only right-aligned messages from the user; inspect both sides of the viewport.
        let found = stride(from: host.bounds.height - 120, to: 60, by: -6).flatMap { y in
            stride(from: CGFloat(40), to: host.bounds.width - 40, by: 12).map { host.convert(NSPoint(x: $0, y: y), to: nil) }
        }
            .first { point in panel.contentView?.hitTest(point).map { String(describing: type(of: $0)).contains("TextInteraction") } ?? false }
        guard let edge = found else { smokeFailed("No selectable bubble text on screen") }
        // The scan stops at the lower edge of the text, and the last line is the address; aim at the line above it.
        var point = NSPoint(x: edge.x, y: edge.y + 26)
        board.clearContents()
        // Record link clicks instead of opening a browser.
        var opened: [URL] = []
        var linkPoint: NSPoint?
        chat.onOpenLink = { opened.append($0) }
        // Every spot of selectable text on screen, to find the one address by clicking as a reader would.
        let texts = stride(from: host.bounds.height - 120, to: 60, by: -5).flatMap { y in stride(from: CGFloat(40), to: host.bounds.width - 40, by: 12).map { host.convert(NSPoint(x: $0, y: y), to: nil) } }
            .filter { point in panel.contentView?.hitTest(point).map { $0 is LinkCursorView || String(describing: type(of: $0)).contains("TextInteraction") } ?? false }
        func clickLinks(_ index: Int, done: @escaping () -> Void) {
            guard opened.isEmpty, index < texts.count, panel.isKeyWindow else { done(); return }
            click(texts[index], count: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                if !opened.isEmpty { linkPoint = texts[index] }
                clickLinks(index + 1, done: done)
            }
        }
        func pointerCheck(_ done: @escaping () -> Void) {
            guard #available(macOS 15.0, *) else { log += "pointer: unchanged on macOS < 15\n"; done(); return }
            guard let clickedPoint = linkPoint else { check(false, "The clicked link has a pointer target"); return }
            func regions(_ view: NSView) -> [LinkCursorView] {
                (view as? LinkCursorView).map { [$0] } ?? view.subviews.flatMap(regions)
            }
            // A click can hit the line's padding; hover over the letters and verify that their centre also opens the link.
            let clickedText = panel.contentView?.hitTest(clickedPoint)
            let centers = regions(host).flatMap { view in view.rects.map { view.convert(CGPoint(x: $0.midX, y: $0.midY), to: nil) } }
                .filter { point in
                    let hit = panel.contentView?.hitTest(point)
                    // Native text handles link padding; the glyph itself belongs to its link cursor view.
                    return hit === clickedText || (abs(point.y-clickedPoint.y)<24 && hit is LinkCursorView)
                }
            guard let linkPoint = centers.min(by: { hypot($0.x-clickedPoint.x, $0.y-clickedPoint.y) < hypot($1.x-clickedPoint.x, $1.y-clickedPoint.y) }) else {
                let targets = regions(host).flatMap { view in view.rects.map { view.convert(CGPoint(x:$0.midX,y:$0.midY),to:nil) } }
                let diagnostic = "clicked=\(clickedPoint), hit=\(String(describing:clickedText)), glyph targets=\(targets.count), nearby hits=\(targets.filter { abs($0.y-clickedPoint.y)<24 }.map { String(describing:panel.contentView?.hitTest($0)) })"
                try? diagnostic.write(to:destination.appendingPathComponent("link-glyph-failure.txt"),atomically:true,encoding:.utf8)
                check(false, "The clicked link has a glyph rectangle"); return
            }
            func move(_ target: NSPoint) {
                let screen = panel.convertPoint(toScreen: target)
                CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y))
                NSApp.postEvent(NSEvent.mouseEvent(with: .mouseMoved, location: target, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!, atStart: false)
            }
            let region = regions(host).first { view in view.rects.contains { view.convert($0, to: nil).contains(linkPoint) } }!
            let margin = region.convert(CGPoint(x: -8, y: region.bounds.midY), to: nil)
            // Use the plain line immediately above this live link, not the pre-click scan's stale position.
            let glyph = region.rects.first { region.convert($0,to:nil).contains(linkPoint) }!
            let plainPoint = region.convert(CGPoint(x:glyph.minX+12,y:glyph.minY-10),to:nil)
            check(panel.contentView?.hitTest(plainPoint).map { String(describing:type(of:$0)).contains("TextInteraction") } == true,
                  "The plain pointer target is live selectable text")
            log += "plain target: previous=\(point), live=\(plainPoint), previous hit=\(String(describing:panel.contentView?.hitTest(point)))\n"
            // Selection must use the same live text as the pointer check; layout can move the initial scan's bubble.
            point = plainPoint
            func sample(_ remaining: Int) {
                check(NSCursor.current == .pointingHand, "Link pointer stays a pointing hand while selectable text updates: \(NSCursor.current), point=\(linkPoint)")
                if remaining > 0 {
                    move(linkPoint)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { sample(remaining - 1) }
                } else {
                    move(plainPoint)
                    step {
                        log += "pointer: link 30/30 pointingHand; plain IBeam=\(NSCursor.current == .iBeam)\n"
                        check(NSCursor.current != .pointingHand, "Plain text in the same bubble keeps its text pointer")
                        check(NSCursor.current == .iBeam, "Plain selectable text returns to its I-beam cursor")
                        move(linkPoint)
                        step {
                            check(NSCursor.current == .pointingHand, "Returning from plain text restores the link pointer")
                            move(margin)
                            step {
                                check(NSCursor.current == .arrow, "Leaving a link for the bubble margin restores the arrow")
                                log += "pointer exit: plain IBeam, bubble margin arrow\n"
                                done()
                            }
                        }
                    }
                }
            }
            let clicks = opened.count
            click(linkPoint, count: 1)
            step {
                check(opened.count == clicks + 1 && opened.last?.absoluteString == "https://example.com/doc", "The hovered link letters still open the address")
                move(margin)
                step {
                    check(NSCursor.current == .arrow, "The bubble margin starts with an arrow cursor")
                    move(linkPoint)
                    step { sample(29) }
                }
            }
        }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true); NSRunningApplication.current.activate(options: [.activateAllWindows]) }
        panel.makeKeyAndOrderFront(nil)
        // The first click also makes the panel key, as a real click does.
        click(point, count: 1)
        step { clickLinks(0) { step {
            log += "link clicks=\(opened.map(\.absoluteString))\n"
            check(opened.first?.absoluteString == "https://example.com/doc", "Clicking a bare address in a reply opens it")
            pointerCheck {
            click(point, count: 1)
        step { click(point, count: 1); click(point, count: 2)
        step {
            key("c", code: 8)
            let word = board.string(forType: .string) ?? ""
            key("a", code: 0); key("c", code: 8)
            let whole = board.string(forType: .string) ?? ""
            log += "bubble word=[\(word)] whole=[\(whole)]\n"
            check(!word.isEmpty && whole.count > word.count && whole.contains(word), "Command-C copies selected bubble text and Command-A widens it to the whole bubble")
            self.chat.draft = "단축키 확인"; self.chat.focusDraftRevision += 1
        step {
            board.clearContents()
            key("a", code: 0); key("c", code: 8)
            check(board.string(forType: .string) == "단축키 확인", "Command-A and Command-C copy the draft")
            key("x", code: 7)
        step {
            check(self.chat.draft.isEmpty && board.string(forType: .string) == "단축키 확인", "Command-X cuts the draft")
            key("v", code: 9)
        step {
            check(self.chat.draft == "단축키 확인", "Command-V pastes into the draft")
            key("v", code: 9)
        step {
            check(self.chat.draft == "단축키 확인단축키 확인", "Command-V pastes again at the caret")
            key("z", code: 6)
        step {
            // How many edits one undo takes back is AppKit's grouping; it only has to take something back.
            check(self.chat.draft != "단축키 확인단축키 확인", "Command-Z undoes: [\(self.chat.draft)]")
            log += "after undo=[\(self.chat.draft)]\n"
            key("z", code: 6, shift: true)
        step {
            check(self.chat.draft == "단축키 확인단축키 확인", "Shift-Command-Z redoes it: [\(self.chat.draft)]")
            ChatView.moveCaretToEnd(in: self.panel)
            NSApp.sendEvent(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:self.panel.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!)
        step {
            // Sending would have emptied the draft.
            check(self.chat.draft == "단축키 확인단축키 확인\n", "Shift-Return starts a new line in the draft instead of sending it: [\(self.chat.draft.debugDescription)]")
            finish("checked: link pointer, plain text pointer, link click, bubble copy, draft copy, cut, paste, undo, redo, line break")
        } } } } } } } } } } } } }
    }
}


extension AppDelegate {
    func verifyPetEdges(destination: URL) {
        let probe = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        probe.isOpaque = false; probe.backgroundColor = .clear
        probe.orderFront(nil)
        defer { probe.orderOut(nil) }
        var report = ""
        for screen in NSScreen.screens {
            let frame = screen.visibleFrame
            for scale in [CGFloat(0.25), 0.41, 1, 2] {
                for expanded in [false, true] {
                    let start = PetPlacement(spriteOrigin: CGPoint(x:frame.midX,y:frame.minY+30),
                                             scale:scale,visibleFrame:frame,screenFrame:screen.frame,expanded:true)
                    for right in [false,true] { for top in [false,true] {
                        let point = CGPoint(x:right ? 99999 : -99999,y:top ? 99999 : -99999)
                        let placement = expanded ? start.dragged(by:point,visibleFrame:frame,screenFrame:screen.frame)
                            : PetPlacement(spriteOrigin:point,scale:scale,visibleFrame:frame,screenFrame:screen.frame)
                        let window = placement.windowFrame, backing = screen.backingScaleFactor
                        let x0 = floor(window.minX*backing)/backing, y0 = floor(window.minY*backing)/backing
                        let aligned = CGRect(x:x0,y:y0,width:ceil(window.maxX*backing)/backing-x0,
                                             height:ceil(window.maxY*backing)/backing-y0)
                        probe.setFrame(aligned, display: true)
                        smokeCheck(probe.frame == aligned, "AppKit preserves the off-screen transparent window frame")
                        let visible = PetLayout.placementSprite(in:placement.globalSprite)
                        let x = right ? frame.maxX-visible.maxX : visible.minX-frame.minX
                        let y = top ? frame.maxY-visible.maxY : visible.minY-frame.minY
                        smokeCheck(abs(x-4)<0.001,"Pet retains its horizontal margin")
                        if top && expanded {
                            smokeCheck(abs(placement.globalBubble.maxY-PetLayout.maximumHeader(visibleFrame:frame,screenFrame:screen.frame))<0.001,
                                       "Perched header reaches the menu bar")
                        } else {
                            let gap = top ? screen.frame.maxY-visible.maxY : y
                            smokeCheck(abs(gap-(top ? 0 : 4))<0.001,"Pet reaches its vertical limit")
                        }
                        report += "PASS: scale=\(scale), expanded=\(expanded), right=\(right), top=\(top), gaps=\(x),\(y), panel frame unchanged\n"
                    } }
                }
            }
        }
        try? report.write(to:destination.appendingPathComponent("pet-edges.txt"),atomically:true,encoding:.utf8)
    }
}
