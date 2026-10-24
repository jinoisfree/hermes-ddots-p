import AppKit
import SwiftUI

extension AppDelegate {
    func verifySidebarInteraction(destination: URL, then finish: @escaping () -> Void) {
        Task { @MainActor [self] in
            @MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
                if !condition() {
                    capture(destination: destination.appendingPathComponent("sidebar-failure"))
                    try? message.write(to: destination.appendingPathComponent("sidebar-failure.txt"), atomically: true, encoding: .utf8)
                    smokeFailed(message)
                }
            }
            @MainActor func settle() async {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                repeat {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                } while ProcessInfo.processInfo.systemUptime < deadline
                    && (widthSliding || pet.hasWidthPicture || web.sliding || perchTransition != nil)
                check(!widthSliding && !pet.hasWidthPicture && !web.sliding && perchTransition == nil,
                      "Sidebar interaction waits for the visible content instead of a transition picture")
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            @MainActor func dispatch(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) async {
                let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                              context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
                NSApp.postEvent(event, atStart: false)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            @MainActor func clickBlank(times: Int = 2) async {
                await settle()
                NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
                pet.layoutSubtreeIfNeeded()
                guard let rect = chat.smokeFrames["sidebar-blank"], rect.height > 10,
                      let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first else {
                    check(false, "Sidebar has measurable blank space"); return
                }
                let local = CGPoint(x: rect.midX, y: host.isFlipped ? rect.midY : host.bounds.height-rect.midY)
                let point = panel.convertPoint(toScreen: host.convert(local, to: nil))
                let hit = pet.hitTest(panel.convertPoint(fromScreen: point))
                let note = "blank=\(rect) host=\(host.bounds) point=\(point) width=\(slack.model.sidebarWidth) snapshot=\(pet.hasWidthPicture) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") key=\(panel.isKeyWindow) hidden=\(host.isHiddenOrHasHiddenAncestor) alpha=\(host.alphaValue) genie=\(pet.genieActive) mask=\(host.layer?.mask != nil)\n"
                let file = destination.appendingPathComponent("sidebar-click.txt")
                try? (((try? String(contentsOf: file, encoding: .utf8)) ?? "") + note).write(to: file, atomically: true, encoding: .utf8)
                // Keep one synthetic double click together; layout work must not split it into separate clicks.
                for click in 1...times {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                            context: nil, eventNumber: click, clickCount: click, pressure: 1)!
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                await settle()
            }
            slack.model.source = .slack; slack.model.foldAll(); slack.model.query = ""
            slack.model.dragSidebar(to: SlackSidebar.width)
            await settle()
            let selected = slack.model.selected, draft = slack.model.draft, column = chat.viewportWidth
            await clickBlank(times: 1)
            check(slack.model.sidebarWidth == SlackSidebar.width, "One click on the blank space changes nothing; actual=\(slack.model.sidebarWidth)")
            await clickBlank()
            check(slack.model.sidebarWidth == SlackSidebar.expandedWidth, "Blank double click expands sidebar from 68 to 212; actual=\(slack.model.sidebarWidth), open=\(chatExpanded)")
            check(chat.viewportWidth == column && slack.model.selected == selected && slack.model.draft == draft,
                  "Sidebar preset preserves conversation width, selected room and draft")
            capture(destination: destination.appendingPathComponent("sidebar-expanded"))
            await clickBlank()
            check(slack.model.sidebarWidth == SlackSidebar.width, "Second blank click returns sidebar to 68")
            slack.model.dragSidebar(to: 250); await settle()
            check(slack.model.sidebarWidth == 250, "Manual sidebar resizing remains available")
            await clickBlank()
            check(slack.model.sidebarWidth == SlackSidebar.width, "Custom width returns to the default on blank click")
            slack.model.toggleSidebar(); slack.model.toggleSidebar()
            check(slack.model.sidebarWidth == SlackSidebar.width, "Hide/show restores the selected preset")
            await settle()

            // Exercise the title text itself, including DDots + version, rather than the small grip.
            @MainActor func handles(_ view: NSView) -> [ChatDragView] {
                (view as? ChatDragView).map { [$0] } ?? view.subviews.flatMap { handles($0) }
            }
            guard let title = handles(pet).filter({ !$0.isHiddenOrHasHiddenAncestor }).max(by: { $0.bounds.width < $1.bounds.width }) else {
                check(false, "Title drag region exists"); return
            }
            check(title.bounds.width > 30 && title.bounds.height >= 38, "Title drag region covers the full header height")
            let local = title.convert(CGPoint(x: 10, y: title.bounds.midY), to: pet)
            check(pet.hitTest(local) === title, "The DDots title receives drag events")
            let point = panel.convertPoint(toScreen: pet.convert(local, to: nil))
            let before = pet.placement!
            await dispatch(.leftMouseDown, at: point)
            await dispatch(.leftMouseDragged, at: CGPoint(x: point.x-30, y: point.y))
            check(chatDrag != nil, "Dragging the title starts group movement")
            await dispatch(.leftMouseUp, at: CGPoint(x: point.x-30, y: point.y))
            await settle()
            let after = pet.placement!
            check(chatDrag == nil && after.globalSprite.origin != before.globalSprite.origin, "Title drag moves the pet")
            check(after.spriteRect == before.spriteRect && after.bubbleRect == before.bubbleRect, "Title drag retains the pair's layout")
            capture(destination: destination.appendingPathComponent("title-drag"))

            // Carrying the pet itself. One long step is what a fast pointer makes; the pet goes the whole way with it.
            // The window sits on whole pixels, so the pet is measured where it really is on the screen, as a drag measures it.
            @MainActor func spot() -> CGRect { panel.convertToScreen(pet.convert(pet.spriteRect, to: nil)) }
            let home = pet.placement!.globalSprite.origin, side = resizedBelow
            let held = spot()
            let grip = CGPoint(x: held.midX, y: held.midY)
            var pointer = grip
            pet.pointerLocation = { pointer }
            defer { pet.pointerLocation = { NSEvent.mouseLocation } }
            @MainActor func resting(_ origin: CGPoint) -> CGPoint {
                let center = CGPoint(x: origin.x + held.width / 2, y: origin.y + held.height / 2)
                let safe = (NSScreen.screens.first { $0.frame.contains(center) } ?? panel.screen!).visibleFrame.insetBy(dx: 12, dy: 12)
                return CGPoint(x: min(max(origin.x, safe.minX), max(safe.minX, safe.maxX - held.width)),
                               y: min(max(origin.y, safe.minY), max(safe.minY, safe.maxY - held.height)))
            }
            @MainActor func carried(to wanted: CGPoint) -> Bool {
                let now = spot().origin, rest = resting(wanted)
                return hypot(now.x - rest.x, now.y - rest.y) < 1
            }
            // Straight across its own conversation: the pointer is inside it, and the pet still comes along.
            let over = pet.placement!.globalBubble
            pointer = CGPoint(x: over.midX, y: over.midY)
            let across = CGPoint(x: held.minX + pointer.x - grip.x, y: held.minY + pointer.y - grip.y)
            let moved = pet.onMoved
            var setDown = 0
            pet.onMoved = { setDown += 1; moved?() }
            defer { pet.onMoved = moved }
            await dispatch(.leftMouseDown, at: grip)
            await dispatch(.leftMouseDragged, at: pointer)
            check(carried(to: across), "A pet carried across its own conversation stays in the hand: \(spot().origin) wanted \(resting(across))")
            await dispatch(.leftMouseUp, at: pointer)
            check(setDown == 1, "Let go over the conversation, it is set down there: \(setDown)")
            await settle()
            // The window has moved and changed size by now, so the event's own place in it is out of date.
            // The pet goes by where the pointer is, not by that.
            let second = spot()
            let stale = CGPoint(x: second.midX, y: second.midY)
            pointer = stale
            await dispatch(.leftMouseDown, at: stale)
            // Toward whichever side has the room, so the screen's edge does not stand in for the answer.
            let step: CGFloat = resting(CGPoint(x: second.minX - 60, y: second.minY)).x == second.minX - 60 ? -60 : 60
            pointer = CGPoint(x: stale.x + step, y: stale.y)
            await dispatch(.leftMouseDragged, at: stale)
            check(carried(to: CGPoint(x: second.minX + step, y: second.minY)) && !carried(to: second.origin),
                  "The pet follows the pointer itself, not an event's stale place in the window: \(spot().origin) from \(second.origin)")
            await dispatch(.leftMouseUp, at: pointer)
            await settle()
            // Put back exactly where it was, on the side it was, for the checks that follow.
            resizedBelow = side; placePet(at: home)
            await settle()
            let back = pet.placement!.globalSprite.origin
            // The window rests on whole pixels, and the pet's place is read back from it.
            check(hypot(back.x - home.x, back.y - home.y) < 1, "The pet is back where it started: \(back) from \(home)")
            try! "PASS: blank click 68→212→68, custom width reset, hide/show, unchanged conversation width/room/draft, full title bar drag moves pet and chat, pet drag follows the pointer across the conversation\n"
                .write(to: destination.appendingPathComponent("sidebar-title.txt"), atomically: true, encoding: .utf8)
            finish()
        }
    }

    func verifyChat2(destination: URL) {
        if !IMessageFeature.enabled { verifySlackOnlyChat(destination: destination); return }
        Task { @MainActor [self] in
            @MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String = "Chat2 assertion") {
                if !condition() {
                    try? message.write(to:destination.appendingPathComponent("chat2-failure.txt"),atomically:true,encoding:.utf8)
                    smokeFailed(message)
                }
            }
            func settle(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
            @MainActor func mouse(_ type: NSEvent.EventType, _ global: CGPoint, clicks: Int = 1) -> NSEvent {
                NSEvent.mouseEvent(with:type,location:panel.convertPoint(fromScreen:global),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                  windowNumber:panel.windowNumber,context:nil,eventNumber:1,clickCount:clicks,pressure:1)!
            }
            @MainActor func farCorner() -> CGPoint {
                let p = pet.placement!
                return CGPoint(x:p.globalBubble.maxX-8,y:p.bubbleBelow ? p.globalBubble.minY+8 : p.globalBubble.maxY-8)
            }
            @MainActor func drag(_ delta: CGPoint) {
                let start = farCorner(), end = CGPoint(x:start.x+delta.x,y:start.y+delta.y)
                let local = pet.convert(panel.convertPoint(fromScreen:start),from:nil)
                check(pet.hitTest(local) === pet,"Resize border receives events before SwiftUI")
                pet.mouseDown(with:mouse(.leftMouseDown,start))
                pet.mouseDragged(with:mouse(.leftMouseDragged,end))
                pet.mouseUp(with:mouse(.leftMouseUp,end))
            }
            showChat(); resetChatSize(); chat.requestScroll("chat-bottom")
            await settle(0.7)
            await verifyChatEntry(destination: destination)
            await verifyPetTransition(destination: destination)
            await verifyChatDragging(destination: destination)
            // The pet was just put back and the bubble eases after it; it is measured once it has come to rest.
            await settle(0.6)
            let before = pet.placement!, preferredBefore = preferredChatSize
            pet.layoutSubtreeIfNeeded(); panel.invalidateCursorRects(for: pet); pet.resetCursorRects()
            var cursorLog = ""
            let regions = PetLayout.resizeRegions(bubble: before.bubbleRect, below: before.bubbleBelow)
            for side in [PetLayout.ResizeEdge.left, .right] {
                for (x,y) in [(2.0,10.0),(10,2),(8,8),(3,18),(18,3)] {
                    let r = before.bubbleRect
                    let point = CGPoint(x:side == .left ? r.minX+x : r.maxX-x,y:before.bubbleBelow ? r.minY+y : r.maxY-y)
                    let matches = regions.filter { $0.rect.contains(point) }
                    let edge = PetLayout.resizeEdge(at:point,bubble:r,below:before.bubbleBelow)
                    check(matches.count == 1 && matches[0].edge == edge && edge == [side,.far], "Each corner sample has exactly its diagonal cursor")
                    cursorLog += "inset=(\(x),\(y)), side=\(side.rawValue), matches=\(matches.count), edge=\(edge.rawValue)\n"
                }
            }
            try? cursorLog.write(to:destination.appendingPathComponent("resize-cursors.txt"),atomically:true,encoding:.utf8)
            if let bitmap = pet.bitmapImageRepForCachingDisplay(in: pet.bounds) {
                pet.cacheDisplay(in: pet.bounds, to: bitmap)
                let point = pet.convert(panel.convertPoint(fromScreen: farCorner()), from: nil)
                let x = Int(point.x / pet.bounds.width * CGFloat(bitmap.pixelsWide))
                let y = Int((pet.bounds.height-point.y) / pet.bounds.height * CGFloat(bitmap.pixelsHigh))
                let alpha = bitmap.colorAt(x:x,y:y)?.alphaComponent ?? 0
                check(alpha > 0.05, "The visible resize corner has painted pixels: \(alpha)")
                try? "corner inset=8pt, alpha=\(alpha)\n".write(to:destination.appendingPathComponent("resize-corner.txt"),atomically:true,encoding:.utf8)
            }
            capture(destination:destination.appendingPathComponent("resize-before"))
            drag(CGPoint(x:60,y:before.bubbleBelow ? -35 : 35))
            let diagnostic = "before=\(before.globalBubble), after=\(pet.placement!.globalBubble), preferred=\(preferredChatSize), spriteBefore=\(before.globalSprite), spriteAfter=\(pet.placement!.globalSprite), resizing=\(resizingChat)\n"
            try? diagnostic.write(to:destination.appendingPathComponent("resize-debug.txt"),atomically:true,encoding:.utf8)
            check(preferredChatSize.width > preferredBefore.width && !resizingChat, "Drag must grow preferred width")
            check(pet.placement!.globalSprite == before.globalSprite,"Resize never moves the pet")
            check(abs((before.bubbleBelow ? pet.placement!.globalBubble.maxY-before.globalBubble.maxY : pet.placement!.globalBubble.minY-before.globalBubble.minY)) < 0.1,"Pet-facing edge stays fixed")
            await settle(0.6)
            if let scroll = chat.scrollView, let document = scroll.documentView {
                check(document.bounds.maxY-scroll.contentView.bounds.maxY < 2,"Resizing at bottom stays at bottom: gap=\(document.bounds.maxY-scroll.contentView.bounds.maxY), near=\(chat.nearBottom)")
            }
            capture(destination:destination.appendingPathComponent("resize-after"))
            if let scroll = chat.scrollView, let document = scroll.documentView {
                chat.userScrollGeneration += 1
                scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.height/3)); scroll.reflectScrolledClipView(scroll.contentView)
                await settle(0.1)
                let offset = scroll.contentView.bounds.origin.y
                check(!chat.nearBottom, "Reading test starts away from the bottom")
                drag(CGPoint(x:20,y:0)); await settle(0.6)
                check(abs(scroll.contentView.bounds.origin.y-offset) < 1, "Resizing while reading preserves the offset")
                capture(destination:destination.appendingPathComponent("resize-reading"))
            }
            let grown = pet.placement!
            drag(CGPoint(x:-20,y:grown.bubbleBelow ? 20 : -20)); await settle(0.6)
            check(pet.chatSize.width < grown.globalBubble.width && pet.chatSize.height < grown.globalBubble.height, "Visible corner shrinks both dimensions")
            check(pet.placement!.globalSprite == grown.globalSprite, "Shrinking leaves the pet anchored")
            capture(destination:destination.appendingPathComponent("resize-shrunk"))
            var nearLog = ""
            for side in [PetLayout.ResizeEdge.left, .right] {
                let before = pet.placement!, r = before.globalBubble
                let start = CGPoint(x:side == .left ? r.minX+8 : r.maxX-8,y:before.bubbleBelow ? r.maxY-8 : r.minY+8)
                let end = CGPoint(x:start.x+(side == .left ? 10 : -10),y:start.y+(before.bubbleBelow ? -20 : 20))
                let local = pet.convert(panel.convertPoint(fromScreen:start),from:nil)
                check(pet.hitTest(local) === pet, "Near corner receives events before SwiftUI")
                pet.mouseDown(with:mouse(.leftMouseDown,start))
                pet.mouseDragged(with:mouse(.leftMouseDragged,end))
                pet.mouseUp(with:mouse(.leftMouseUp,end))
                let after = pet.placement!, change = after.globalBubble.height-before.globalBubble.height
                check(abs(change+20) < 0.1, "Near corner changes height by the drag distance")
                check(abs(before.bubbleBelow ? after.globalBubble.minY-r.minY : after.globalBubble.maxY-r.maxY) < 0.1, "Near corner keeps the far edge fixed")
                check(abs(after.globalSprite.minY-before.globalSprite.minY-(before.bubbleBelow ? change : -change)) < 0.1, "Near corner moves the pet by the height change")
                check(after.globalSprite.minX == before.globalSprite.minX && !resizingChat, "Near corner preserves pet x and ends resizing")
                let actualAnchor = panel.convertToScreen(pet.convert(pet.spriteRect, to:nil)).origin
                check(smokePosition["petAnchorX"] == Double(actualAnchor.x) && smokePosition["petAnchorY"] == Double(actualAnchor.y), "Near corner saves the moved pet anchor")
                nearLog += "PASS: near side=\(side.rawValue), below=\(before.bubbleBelow), heightChange=\(change), far edge fixed, pet follows\n"
                await settle(0.6)
            }
            try? nearLog.write(to:destination.appendingPathComponent("resize-near.txt"),atomically:true,encoding:.utf8)
            let saved = preferredChatSize
            collapseChat(); showChat(); await settle(0.6)
            check(preferredChatSize == saved && pet.chatSize.width == saved.width,"Preferred size survives folding")
            capture(destination:destination.appendingPathComponent("resize-reopened"))
            let resetPoint = farCorner()
            pet.mouseDown(with:mouse(.leftMouseDown,resetPoint,clicks:2)); pet.mouseUp(with:mouse(.leftMouseUp,resetPoint,clicks:2))
            check(preferredChatSize == PetLayout.expandedSize,"Border double click resets size")
            await settle()
            // The header: one click does nothing, a double click doubles the width, another brings it back.
            func header(in view: NSView) -> ChatDragView? { (view as? ChatDragView) ?? view.subviews.lazy.compactMap(header).first }
            guard let bar = header(in: pet) else { smokeFailed("The conversation has a header to press") }
            let barPoint = panel.convertPoint(toScreen: bar.convert(CGPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil))
            bar.mouseDown(with:mouse(.leftMouseDown,barPoint)); bar.mouseUp(with:mouse(.leftMouseUp,barPoint))
            check(preferredChatSize == PetLayout.expandedSize,"One click on the header leaves the size alone")
            await measureHeaderSlide(destination: destination)
            let widthBefore = pet.placement!.globalBubble.width
            let reducedWidthMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion")
            if reducedWidthMotion { smokeCheck(pet.genieCaptures == 0, "Reduced motion never captures or blurs a Genie picture") }
            bar.mouseDown(with:mouse(.leftMouseDown,barPoint,clicks:2)); bar.mouseUp(with:mouse(.leftMouseUp,barPoint,clicks:2))
            if reducedWidthMotion { check(!widthSliding && !pet.hasWidthPicture && pet.chatBlur == 0 && !pet.chatHasBlurFilter, "Reduced motion changes width without blur") }
            else {
                await settle(0.12)
                check(pet.placement!.globalBubble.width > widthBefore && pet.placement!.globalBubble.width < placementTarget!.globalBubble.width && pet.widthPictureVisible && pet.widthPictureTransparent && !pet.chatHasBlurFilter, "Header widening has intermediate glass and blur")
                capture(destination: destination.appendingPathComponent("header-widening"))
                if let image = pet.widthPictureImage {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("header-picture.png"))
                }
            }
            check(preferredChatSize == CGSize(width:PetLayout.expandedSize.width*2,height:PetLayout.expandedSize.height),"A double click on the header doubles the width: \(preferredChatSize)")
            await settle(); capture(destination:destination.appendingPathComponent("header-wide"))
            check(!widthSliding && !pet.hasWidthPicture && pet.chatBlur == 0 && !pet.chatHasBlurFilter && pet.placement!.globalBubble.width == placementTarget!.globalBubble.width, "Widening settles sharp at target")
            let widened = pet.placement!.globalBubble.width
            check(pet.chatSize.width <= preferredChatSize.width + slackStrip + 1 && pet.chatSize.width > PetLayout.expandedSize.width,"The window is as wide as asked, or as wide as the screen lets it be: \(pet.chatSize.width)")
            bar.mouseDown(with:mouse(.leftMouseDown,barPoint,clicks:2)); bar.mouseUp(with:mouse(.leftMouseUp,barPoint,clicks:2))
            check(preferredChatSize == PetLayout.expandedSize,"Another double click brings the usual width back")
            if !reducedWidthMotion {
                await settle(0.12)
                check(pet.placement!.globalBubble.width < widened && pet.placement!.globalBubble.width > placementTarget!.globalBubble.width && pet.widthPictureVisible && pet.widthPictureTransparent && !pet.chatHasBlurFilter, "Narrowing slides and blurs too")
                let turning = pet.placement!.globalBubble.width
                let turningPicture = pet.hasWidthPicture
                let headerPoint = CGPoint(x: pet.placement!.bubbleRect.midX, y: pet.placement!.bubbleRect.maxY - PetLayout.headerHeight / 2)
                guard let movingHeader = pet.hitTest(headerPoint) as? ChatDragView else { smokeFailed("Moving picture keeps the header interactive") }
                let screenPoint = panel.convertPoint(toScreen: pet.convert(headerPoint, to: nil))
                movingHeader.mouseDown(with: mouse(.leftMouseDown, screenPoint, clicks: 2))
                movingHeader.mouseUp(with: mouse(.leftMouseUp, screenPoint, clicks: 2))
                check(turningPicture && pet.widthPictureVisible, "Reversal preserves the current picture")
                check(abs(pet.placement!.globalBubble.width - turning) < 2, "Reversal starts at the current width")
                await settle(0.1)
                check(pet.placement!.globalBubble.width > turning, "Reversal moves toward wide")
                await settle(); toggleChatWidth()
            }
            await settle()
            check(pet.chatBlur == 0 && !pet.chatHasBlurFilter && !pet.hasWidthPicture && !widthSliding && pet.placement!.globalBubble.width == placementTarget!.globalBubble.width, "Narrowing settles with no filter")
            if !reducedWidthMotion {
                toggleChatWidth(); await settle(0.1); collapseChat(); toggleChatWidth(); await settle(0.8)
                check(!chatExpanded && !pet.hasWidthPicture && pet.chatBlur == 0 && !pet.chatHasBlurFilter && !pet.chatShown, "Folding during width slide clears blur and hides content")
                showChat(); await settle(0.8)
                check(pet.chatShown && pet.chatBlur == 0 && !pet.chatHasBlurFilter, "Reopening after interrupted width slide is sharp")
            }
            // The pet: one click folds the open conversation, the second click of a double click adds nothing, one more opens it.
            petClicked(count:1); check(!chatExpanded,"One click on the pet folds the conversation")
            petClicked(count:2); check(!chatExpanded,"The second click of a double click does nothing more")
            await settle(0.6)
            petClicked(count:1); check(chatExpanded,"One click on the pet opens it")
            await settle(0.6)
            await settle()
            let minimumBefore = pet.placement!
            drag(CGPoint(x:-1000,y:pet.placement!.bubbleBelow ? 1000 : -1000))
            check(preferredChatSize == PetLayout.minimumChatSize && pet.chatSize == PetLayout.minimumChatSize,"Dragging cannot shrink below the minimum")
            check(pet.placement!.globalSprite == minimumBefore.globalSprite, "Minimum resize leaves the pet anchored")
            await settle(); capture(destination:destination.appendingPathComponent("resize-minimum"))
            resetChatSize(); await settle(); collapseChat(); await settle()

            let now = Date()
            unread = UnreadReplies(launchedAt:now.addingTimeInterval(-30))
            let receipts = (0..<11).map { ChatReceipt(id:"unread:\($0)",fromUser:false,date:now.addingTimeInterval(Double($0)-20)) }
            updateUnread(receipts); updatePet()
            check(pet.unreadCount == 11 && UnreadReplies.badge(pet.unreadCount) == "9+")
            check(pet.badgeRect.size == CGSize(width:22,height:22))
            check(pet.bubbleText.unreadCount == 11 && !pet.bubbleText.statusDotVisible, "Unread count replaces the title status dot")
            check(pet.placement!.bubbleRect.contains(pet.badgeRect) && !pet.spriteRect.intersects(pet.badgeRect), "Badge belongs to the bubble, not the sprite")
            check(statusItem.button!.toolTip!.contains("안 읽은 답 11개"))
            check(pet.accessibilityLabel()!.contains("안 읽은 답 11개"))
            await settle(); capture(destination:destination.appendingPathComponent("unread-badge"))
            pet.unreadCount = 3
            capture(destination: destination.appendingPathComponent("unread-three"))
            pet.unreadCount = 11
            let scale = pet.petScale
            pet.petScale = scale/2; constrainPosition(); await settle()
            check(pet.badgeRect.size == CGSize(width:22,height:22), "Badge size does not scale with the sprite")
            capture(destination:destination.appendingPathComponent("unread-small-pet"))
            pet.petScale = scale; constrainPosition()
            model.paused = true; pet.isPaused = true; updatePet(); await settle()
            check(!pet.badgeVisible && unread.count == 11, "Pause hides the badge without marking answers read")
            check(pet.bubbleText.unreadCount == 0, "Paused bubble does not draw an unread badge")
            capture(destination:destination.appendingPathComponent("unread-paused"))
            model.paused = false; pet.isPaused = false; updatePet()
            panel.orderOut(nil); check(!pet.badgeVisible, "Hidden pet has no visible badge"); panel.orderFrontRegardless()
            showChat(); await settle()
            check(unread.count == 0 && pet.unreadCount == 0,"Opening clears the badge")
            check(pet.bubbleText.unreadCount == 0 && !pet.badgeVisible, "Opening also clears the bubble badge")
            let user = ChatMessage(id:"reply-test:user",fromUser:true,speaker:"",body:"합성 질문",date:Date(),profile:"default")
            let typing = TypingIndicator(id:"reply-test",speaker:"위키담당",profile:"default")
            replyActivity = ChatReplyActivity()
            let characters = chat.characters, avatars = chat.avatars
            applyChat(HermesBridge.PollResult(status:.connected(stores:1),messages:[user],typing:[typing],avatars:avatars,characters:characters,receipts:[ChatReceipt(user)]))
            updatePet(); await settle(0.25)
            check(pet.chatAnimation == .replyWaiting && pet.animationFrame.row == 8,"Typing loops the reply computer")
            if CommandLine.arguments.contains("--ui-smoke-reduce-motion") { check(pet.animationFrame.column == 0) }
            capture(destination:destination.appendingPathComponent("reply-computer"))
            var computerColumns = Set<Int>()
            for _ in 0..<8 { await settle(0.17); computerColumns.insert(pet.animationFrame.column) }
            check(pet.animationFrame.row == 8, "Reply computer stays active after a full cycle")
            if !CommandLine.arguments.contains("--ui-smoke-reduce-motion") && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(computerColumns.count > 1, "Reply computer visibly advances between frames")
            }
            let answer = ChatMessage(id:"default:reply-test",fromUser:false,speaker:"위키담당",body:"합성 답변 완료",date:Date(),profile:"default")
            applyChat(HermesBridge.PollResult(status:.connected(stores:1),messages:[user,answer],avatars:avatars,characters:characters,receipts:[ChatReceipt(user),ChatReceipt(answer)]))
            updatePet(); await settle(0.2)
            check(pet.animationFrame.row == 4,"A reply triggers a jump even with the chat open")
            if CommandLine.arguments.contains("--ui-smoke-reduce-motion") { check(pet.animationFrame.column == 0) }
            capture(destination:destination.appendingPathComponent("reply-jump"))
            await settle(0.9)
            check(pet.animationFrame.row != 4,"Reply jump completes after one cycle")
            pet.state = .waiting; pet.chatAnimation = nil
            await settle(3.2)
            var approvalColumns = Set<Int>()
            for _ in 0..<8 { await settle(0.13); approvalColumns.insert(pet.animationFrame.column) }
            check(pet.animationFrame.row == 6, "Approval phone keeps waving beyond three cycles")
            if !CommandLine.arguments.contains("--ui-smoke-reduce-motion") && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(approvalColumns.count > 1, "Approval phone visibly advances between frames")
            }
            capture(destination:destination.appendingPathComponent("approval-phone"))
            pet.state = .idle
            await settle(0.2)
            check(pet.animationFrame.row != 6, "Resolving approval stops the phone wave")
            finishChatSmoke(destination:destination)
        }
    }

    @MainActor
    private func verifyPetTransition(destination: URL) async {
        guard let screen = panel.screen, let home = placementTarget?.globalSprite.origin else { smokeFailed("Pet transition needs a placement") }
        let side = resizedBelow
        let tick = pet.onAnimationTick
        let tolerance = 0.01 / screen.backingScaleFactor
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion")
        var anchor = CGPoint.zero, phase = "", samples = 0, emptySamples = 0, maximum: CGFloat = 0
        var log = "phase\tsamples\tmaxDeltaPt\ttolerancePt\temptySamples\n"
        func sample() {
            let point = CGPoint(x: panel.frame.minX + pet.spriteRect.minX, y: panel.frame.minY + pet.spriteRect.minY)
            let delta = hypot(point.x - anchor.x, point.y - anchor.y)
            samples += 1; maximum = max(maximum, delta)
            if delta > tolerance {
                try? "\(phase): \(point) from \(anchor), delta \(delta), tolerance \(tolerance)\n"
                    .write(to: destination.appendingPathComponent("pet-transition-failure.txt"), atomically: true, encoding: .utf8)
                smokeFailed("Pet stays fixed throughout opening and folding")
            }
            let content = pet.spriteRect.union(pet.placement!.bubbleRect).insetBy(dx: -12, dy: -12)
            for x in [CGFloat(0.5), pet.bounds.maxX - 0.5] {
                for y in [CGFloat(0.5), pet.bounds.maxY - 0.5] {
                    let point = CGPoint(x: x, y: y)
                    if !content.contains(point) {
                        emptySamples += 1
                        smokeCheck(pet.hitTest(pet.convert(point, to: pet.superview)) == nil, "Transparent transition space takes no clicks")
                    }
                }
            }
        }
        func resting() -> Bool {
            guard let target = placementTarget else { return false }
            return bubbleMotion.position == target.globalBubble.origin && bubbleMotion.size == target.globalBubble.size && transitionFrame == nil
        }
        func settle() async {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            repeat { try? await Task.sleep(nanoseconds: 20_000_000) }
            while !resting() && ProcessInfo.processInfo.systemUptime < deadline
            smokeCheck(resting(), "Pet transition reaches its resting placement")
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        defer { pet.onAnimationTick = tick }
        for below in [false, true] {
            collapseChat(); resizedBelow = nil
            let size = PetLayout(scale: pet.petScale).spriteSize
            placePet(at: CGPoint(x: screen.visibleFrame.midX - size.width / 2,
                                 y: below ? screen.visibleFrame.maxY - size.height - 26 : screen.visibleFrame.minY + 40))
            await settle()
            anchor = CGPoint(x: panel.frame.minX + pet.spriteRect.minX, y: panel.frame.minY + pet.spriteRect.minY)
            pet.onAnimationTick = { tick?(); sample() }
            for repeatIndex in 1...2 {
                for opening in [true, false] {
                    phase = "\(below ? "below" : "above")-\(opening ? "open" : "fold")-\(repeatIndex)"
                    samples = 0; emptySamples = 0; maximum = 0
                    if opening { showChat() } else { collapseChat() }
                    sample(); await settle(); sample()
                    smokeCheck(samples > 2 || reduced, "Pet transition samples every animation tick")
                    log += "\(phase)\t\(samples)\t\(maximum)\t\(tolerance)\t\(emptySamples)\n"
                }
            }
            pet.onAnimationTick = tick
        }
        resizedBelow = side; placePet(at: home); showChat(); await settle()
        let restored = CGPoint(x: panel.frame.minX + pet.spriteRect.minX, y: panel.frame.minY + pet.spriteRect.minY)
        smokeCheck(hypot(restored.x - home.x, restored.y - home.y) <= tolerance, "Repeated folding keeps the original pet anchor")
        try! log.write(to: destination.appendingPathComponent("pet-transition.tsv"), atomically: true, encoding: .utf8)
    }

    @MainActor
    private func verifyChatDragging(destination: URL) async {
        func check(_ condition: @autoclosure () -> Bool, _ message: String = "Header drag assertion") {
            if !condition() {
                try? message.write(to: destination.appendingPathComponent("header-drag-failure.txt"), atomically: true, encoding: .utf8)
                smokeFailed(message)
            }
        }
        func settle() async { try? await Task.sleep(nanoseconds: 350_000_000) }
        func handles(_ view: NSView) -> [ChatDragView] {
            (view as? ChatDragView).map { [$0] } ?? view.subviews.flatMap { handles($0) }
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                              context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func dispatch(_ type: NSEvent.EventType, at point: CGPoint) async {
            NSApp.postEvent(event(type, at: point), atStart: false)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        func handlePoint() -> CGPoint {
            let candidates = handles(pet).filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 8 }
            check(!candidates.isEmpty, "Visible header drag handle exists")
            let handle = candidates[0]
            let local = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: pet)
            check(pet.hitTest(local) === handle, "Header handle receives real hit testing")
            return panel.convertPoint(toScreen: pet.convert(local, to: nil))
        }
        let original = pet.placement!, originalDraft = chat.draft, preferred = preferredChatSize
        var start = handlePoint()
        await dispatch(.leftMouseDown, at: start)
        await dispatch(.leftMouseDragged, at: CGPoint(x: start.x+2, y: start.y))
        await dispatch(.leftMouseUp, at: CGPoint(x: start.x+2, y: start.y))
        check(chatDrag == nil && pet.placement!.windowFrame == original.windowFrame, "Small header motion is not a drag")
        let scroll = chat.scrollView?.contentView.bounds.origin
        let end = CGPoint(x: start.x-45, y: start.y+25)
        await dispatch(.leftMouseDown, at: start)
        await dispatch(.leftMouseDragged, at: end)
        check(chatDrag != nil, "Window dispatch starts header dragging")
        await dispatch(.leftMouseUp, at: end)
        let moved = pet.placement!
        check(chatDrag == nil && moved.globalSprite.origin != original.globalSprite.origin, "Drag ends and changes sprite origin")
        check(moved.spriteRect == original.spriteRect && moved.bubbleRect == original.bubbleRect,
              "Header moves the pair rigidly: \(original.spriteRect), \(original.bubbleRect) → \(moved.spriteRect), \(moved.bubbleRect)")
        await settle()
        check(pet.placement!.windowFrame == moved.windowFrame, "Animation tick cannot snap a dragged pair back")
        check(chat.draft == originalDraft && preferredChatSize == preferred, "Drag retains draft and preferred size")
        check(chat.scrollView?.contentView.bounds.origin == scroll, "Header movement preserves scroll")
        // AppKit may round a window frame to backing pixels; persistence uses the actual view position.
        let actualAnchor = panel.convertToScreen(pet.convert(pet.spriteRect, to: nil)).origin
        check(smokePosition["petAnchorX"] == Double(actualAnchor.x) && smokePosition["petAnchorY"] == Double(actualAnchor.y), "Drag saves the actual pet anchor")
        capture(destination: destination.appendingPathComponent("header-drag"))
        collapseChat(); showChat(); await settle()
        check(hypot(pet.placement!.globalSprite.minX-actualAnchor.x, pet.placement!.globalSprite.minY-actualAnchor.y) < 1,
              "Folding keeps the dragged anchor within a backing pixel")

        chat.openSearch(); await settle()
        start = handlePoint()
        await dispatch(.leftMouseDown, at: start)
        await dispatch(.leftMouseDragged, at: CGPoint(x: start.x+20, y: start.y))
        check(chatDrag != nil && chat.searchOpen, "Search retains its dedicated drag handle")
        await dispatch(.leftMouseUp, at: CGPoint(x: start.x+20, y: start.y))
        chat.closeSearch()
        placePet(at: original.globalSprite.origin); await settle()
        try! "PASS: header hit testing, click threshold, window mouse dispatch, rigid movement, no snapback, draft/scroll/size retention, saved anchor, folding, search handle\n"
            .write(to: destination.appendingPathComponent("header-drag.txt"), atomically: true, encoding: .utf8)
    }
}

extension AppDelegate {
    @MainActor func verifyChatEntry(destination: URL) async {
        func settle(_ seconds: Double = 0.7) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        guard let scroll = chat.scrollView, let document = scroll.documentView else { smokeFailed("The conversation has a scroll view") }
        func readOlder() {
            chat.userScrollGeneration += 1
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height / 3))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func checkFirstVisible(_ label: String, action: () -> Void) async {
            action()
            var sawVisible = false, firstAligned = false, remainedAligned = true, beganPrepared = true
            var frames: [String] = []
            for frame in 0..<55 {
                if pet.genieActive && pet.genieProgress > 0 { beganPrepared = beganPrepared && !pet.openingEntryPending }
                let visible = slack.model.source == .imessage && scroll.alphaValue > 0 && !pet.openingEntryPending
                    && (pet.genieActive ? pet.genieProgress > 0 : pet.chatShown)
                frames.append("frame=\(frame) visible=\(visible) gap=\(document.bounds.maxY - scroll.contentView.bounds.maxY) sameScroll=\(chat.scrollView === scroll) sameDocument=\(scroll.documentView === document) opening=\(pet.openingEntryPending) genie=\(pet.genieProgress) document=\(document.bounds) clip=\(scroll.contentView.bounds) \(chat.entryViewportDiagnostic)")
                if visible {
                    let aligned = !chat.entryViewportPending && document.bounds.maxY - scroll.contentView.bounds.maxY < 2
                    if !sawVisible { firstAligned = aligned; sawVisible = true }
                    remainedAligned = remainedAligned && aligned
                }
                await settle(0.016)
            }
            if !sawVisible || !firstAligned || !remainedAligned || !beganPrepared {
                try? frames.joined(separator: "\n").write(to: destination.appendingPathComponent("entry-" + label.replacingOccurrences(of: " ", with: "-") + ".txt"), atomically: true, encoding: .utf8)
            }
            smokeCheck(sawVisible && firstAligned, "\(label) starts visibly at the latest line")
            smokeCheck(remainedAligned && beganPrepared, "\(label) has no visible late jump or unprepared opening frame")
        }
        let draft = chat.draft
        readOlder(); await settle()
        smokeCheck(!chat.nearBottom, "Entry checks start while reading older text")
        slack.model.source = .slack; await settle(0.4)
        await checkFirstVisible("Returning to iMessage") { slack.model.source = .imessage }
        smokeCheck(document.bounds.maxY - scroll.contentView.bounds.maxY < 2, "Returning to iMessage shows the latest conversation")
        // Work started before leaving the tab must not replace its fresh entry after the result arrives.
        // Exercise the two requests separately: selecting a result also invalidates an earlier page request.
        for context in [false, true] {
            let recent = chat.messages.map(\.id)
            guard let target = chat.messages.first else { smokeFailed("Entry checks have synthetic messages") }
            let gate = DispatchSemaphore(value: 0)
            monitorQueue.async { _ = gate.wait(timeout: .now() + 5) }
            if context { selectChatResult(target) } else { chat.loadOlder() }
            slack.model.source = .slack; slack.model.source = .imessage
            gate.signal()
            // The serial worker has posted both results before this main-queue barrier runs.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                monitorQueue.async { DispatchQueue.main.async { done.resume() } }
            }
            smokeCheck(chat.messages.count == 40 && chat.messages.map(\.id) == recent && !chat.historical && !chat.loadingOlder,
                       "Returning to iMessage ignores a late \(context ? "search context" : "older page")")
            smokeCheck(chat.scrollTarget == "chat-bottom" && chat.draft == draft,
                       "A stale \(context ? "search context" : "older page") cannot replace latest entry or its draft")
        }
        await settle()
        readOlder(); collapseChat(); await settle()
        await checkFirstVisible("Reopening iMessage") { showChat() }
        collapseChat(); await settle(); showChat(); await settle(0.2)
        readOlder()
        let manual = scroll.contentView.bounds.minY
        await settle()
        smokeCheck(abs(scroll.contentView.bounds.minY - manual) < 2, "Manual reading cancels reopening's delayed bottom corrections")
        let revision = chat.scrollRevision
        showChat(); await settle()
        smokeCheck(chat.scrollRevision == revision && abs(scroll.contentView.bounds.minY - manual) < 2,
                   "Focusing an open conversation leaves older text in view")
        // An explicit target made after entry wins over every queued bottom correction.
        chat.enterLatest()
        guard let target = chat.messages.first?.id else { smokeFailed("Entry checks have synthetic messages") }
        chat.requestScroll(target); await settle()
        smokeCheck(chat.scrollTarget == target && !chat.nearBottom, "An explicit target supersedes the entry's queued bottom correction")
        smokeCheck(chat.draft == draft, "Returning, reopening and manual reading retain the draft")
        chat.enterLatest(); await settle()
        try? "PASS: first visible latest without late jumps, source return/reopen, stale older/search response cancellation, manual scroll cancellation, open-window focus, explicit target precedence and draft retention\n"
            .write(to: destination.appendingPathComponent("chat-entry.txt"), atomically: true, encoding: .utf8)
    }
}


extension AppDelegate {
    @MainActor
    private func checkHeaderContent(_ phase: String) {
        guard let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first,
              let glass = pet.placement?.bubbleRect,
              let mask = host.layer?.mask as? CAShapeLayer, let path = mask.path else {
            smokeFailed("Header \(phase) restores the content clipping mask")
        }
        let expected = CGRect(x: glass.minX, y: glass.maxY-pet.chatSize.height, width: pet.chatSize.width, height: pet.chatSize.height)
        smokeCheck(abs(host.frame.minX-expected.minX) < 0.5 && abs(host.frame.minY-expected.minY) < 0.5 && host.frame.size == expected.size,
                   "Header \(phase) aligns content with the glass: \(host.frame) vs \(expected)")
        let visible = path.boundingBoxOfPath
        smokeCheck(abs(visible.width-min(glass.width, host.bounds.width)) < 0.5 && abs(visible.height-min(glass.height, host.bounds.height)) < 0.5,
                   "Header \(phase) clips content to the glass")
    }

    @MainActor
    func measureHeaderSlide(destination: URL) async {
        var log = "direction\tframes\tmean_ms\tmax_ms\tover_20ms\tmax_width_delta\tcapture_ms\treflow_ms\tviewport_changes\tfilter_applications\n"
        var raw = "direction\tuptime\tadvance_ms\twidth\tprogress\tphase\ttimer_work\n"
        pet.onAnimationWork = { [weak self] start, cost in
            if self?.widthSample != nil { self?.transitionWork.append(("pet60hz", start, cost)) }
        }
        defer { widthSample = nil; pet.onAnimationWork = nil; transitionWork = [] }
        for direction in ["widen", "narrow"] {
            var samples: [(Double, Double, CGFloat, CGFloat)] = []
            transitionWork = []
            var expectedViewport: CGFloat?
            widthSample = { [self] time, cost, width, progress in
                if let expectedViewport { smokeCheck(chat.viewportWidth == expectedViewport, "Moving content keeps its prepared width") }
                if pet.chatShown { checkHeaderContent("fade") }
                samples.append((time, cost, width, progress))
                let work = transitionWork.map { "\($0.0):\($0.1):\($0.2 * 1000)" }.joined(separator: ";")
                raw += "\(direction)\t\(time)\t\(cost * 1000)\t\(width)\t\(progress)\t\(widthPhase)\t\(work)\n"
                transitionWork = []
            }
            let filters = pet.widthFilterApplications
            toggleChatWidth()
            let viewport = chat.viewportWidth
            expectedViewport = viewport
            try? await Task.sleep(nanoseconds: 600_000_000)
            smokeCheck(widthViewportChanges == 0 && chat.viewportWidth == viewport && pet.widthFilterApplications == filters, "Width slide changes neither content layout nor live filters")
            smokeCheck(!pet.hasWidthPicture && !pet.chatHasBlurFilter && !widthSliding && pet.chatShown && pet.chatAlpha == 1, "Width slide removes its picture and restores visible opaque content")
            checkHeaderContent(direction)
            widthSample = nil
            let intervals = zip(samples, samples.dropFirst()).map { ($1.0 - $0.0) * 1000 }
            let changes = zip(samples, samples.dropFirst()).map { abs($1.2 - $0.2) }
            log += "\(direction)\t\(samples.count)\t\(intervals.reduce(0,+) / Double(max(1, intervals.count)))\t\(intervals.max() ?? 0)\t\(intervals.filter { $0 > 20 }.count)\t\(changes.max() ?? 0)\t\(pet.widthCaptureMS)\t\(widthReflowMS)\t\(widthViewportChanges)\t\(pet.widthFilterApplications - filters)\n"
        }
        try? (log + "\n" + raw).write(to: destination.appendingPathComponent("header-slide.tsv"), atomically: true, encoding: .utf8)
        // A shrinking union window changes local coordinates even when the final size is already prepared.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !CommandLine.arguments.contains("--ui-smoke-reduce-motion"),
           let saved = pet.placement {
            smokeCheck(pet.beginWidthPicture(), "Header regression can cover the conversation")
            pet.prepareWidthContent()
            pet.placement = PetPlacement(globalSprite: saved.globalSprite, globalBubble: saved.globalBubble,
                                         windowFrame: saved.windowFrame.offsetBy(dx: -73, dy: -41), userScale: pet.petScale, expanded: true)
            pet.updateWidthPicture(progress: 1, fade: 0.5)
            checkHeaderContent("shifted fade")
            pet.endWidthPicture()
            checkHeaderContent("shifted cleanup")
            pet.placement = saved; pet.layoutSubtreeIfNeeded()
            checkHeaderContent("restored")
        }
    }
}
