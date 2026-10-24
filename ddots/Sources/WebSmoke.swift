import AppKit
import SwiftUI
import WebKit

extension AppDelegate {
    /// `--ui-smoke-web`: the page beside the conversation, checked with pages written for the check. Nothing is fetched
    /// from the network, nothing is kept between runs and no other app is opened.
    func verifyWeb(destination: URL) {
        Task { @MainActor [self] in
            let board = NSPasteboard.general
            let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
            var usedBoard = false
            var external: [URL] = []
            let originalExternal = web.onExternal
            web.onExternal = { external.append($0) }
            defer { web.onExternal = originalExternal }
            @MainActor func restoreBoard() {
                guard usedBoard else { return }
                board.clearContents()
                board.writeObjects(saved.map { pairs in let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1, forType: $0.0) }; return item })
                usedBoard = false
            }
            @MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
                if !condition() {
                    capture(destination: destination.appendingPathComponent("web-failure"))
                    try? message.write(to: destination.appendingPathComponent("web-failure.txt"), atomically: true, encoding: .utf8)
                    restoreBoard()
                    smokeFailed(message)
                }
            }
            func settle(_ seconds: Double = 1.5) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            @MainActor func script(_ source: String) async -> String {
                guard let page = web.current?.view else { return "" }
                return (try? await page.evaluateJavaScript(source)).map { "\($0)" } ?? ""
            }
            @MainActor func loaded(_ title: String) async -> Bool {
                for _ in 0..<50 {
                    if web.current?.title == title, web.current?.loading == false { return true }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                return false
            }
            /// The page is drawn by another process and is left out of a view's own picture, so it is laid over it here.
            @MainActor func shot(_ name: String) async {
                pet.layoutSubtreeIfNeeded()
                guard let bitmap = pet.bitmapImageRepForCachingDisplay(in: pet.bounds) else { return }
                pet.cacheDisplay(in: pet.bounds, to: bitmap)
                if let page = web.current?.view, page.window != nil, let placement = pet.placement {
                    let image: NSImage? = await withCheckedContinuation { done in page.takeSnapshot(with: nil) { image, _ in done.resume(returning: image) } }
                    if let image, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                        NSBezierPath(roundedRect: placement.bubbleRect, xRadius: PetLayout.cornerRadius, yRadius: PetLayout.cornerRadius).addClip()
                        image.draw(in: page.convert(page.bounds, to: pet))
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + ".png"))
            }

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-web-smoke-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            SmokeLeftovers.note(folder)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let page = folder.appendingPathComponent("page.html"), second = folder.appendingPathComponent("second.html")
            let note = folder.appendingPathComponent("메모.txt"), paper = folder.appendingPathComponent("보기.pdf")
            let style = "<style>body{font:15px -apple-system;margin:0;color:#1d1d1f;background:#fff}header{background:#03c75a;color:#fff;padding:18px 22px;font-size:20px;font-weight:700}main{padding:22px}h1{font-size:24px;margin:0 0 6px}p{line-height:1.6}input{font:15px -apple-system;padding:8px 10px;border:1px solid #c7c7cc;border-radius:8px;width:70%}.card{border:1px solid #e5e5ea;border-radius:12px;padding:14px 16px;margin:14px 0}a{color:#0a66d8}</style>"
            try! ("<!doctype html><html lang=ko><meta charset=utf-8><title>합성 페이지</title>" + style
                + "<header>지어낸 지도</header><main><h1>스타벅스 선릉역점</h1><p>카페 · 리뷰 4,192<br>영업 전 · 06:30에 영업 시작</p>"
                + "<div class=card><b id=where>ddots</b><p>이 페이지는 점검을 위해 지어낸 것이며 네트워크에서 가져오지 않습니다.</p></div>"
                + "<input id=field placeholder='여기에 입력'> <p><a id=next href='second.html' target='_blank'>새 창으로 열리는 링크</a></p></main>"
                // Focus and key events with their times, read back only when a check fails.
                + "<script>window.trail=[];function note(e){trail.push(Math.round(performance.now())+':'+e.type+':'+(e.target.id||e.target.nodeName||'window'))}"
                + "['focus','blur','keydown','keyup'].forEach(function(t){document.getElementById('field').addEventListener(t,note);window.addEventListener(t,function(e){if(e.target===window)note(e)})});"
                + "document.addEventListener('selectionchange',function(){trail.push(Math.round(performance.now())+':selection:'+window.getSelection().toString().length)})</script></html>")
                .write(to: page, atomically: true, encoding: .utf8)
            try! ("<!doctype html><html lang=ko><meta charset=utf-8><title>둘째 페이지</title>" + style + "<main><h1>둘째 페이지</h1></main></html>")
                .write(to: second, atomically: true, encoding: .utf8)
            try! "한글 메모\n둘째 줄".write(to: note, atomically: true, encoding: .utf8)
            var box = CGRect(x: 0, y: 0, width: 420, height: 595)
            let pdf = CGContext(paper as CFURL, mediaBox: &box, nil)!
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            ("지어낸 PDF" as NSString).draw(at: CGPoint(x: 40, y: 520), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 28)])
            ("대화창 옆에서 열리는 문서입니다." as NSString).draw(at: CGPoint(x: 40, y: 480), withAttributes: [.font: NSFont.systemFont(ofSize: 15)])
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage(); pdf.closePDF()

            await settle()
            guard let screen = panel.screen else { check(false, "The window is on a screen"); return }
            let safe = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let originalHeight = pet.chatSize.height, originalAnchor = placementTarget!.anchorOrigin
            let originalSprite = placementTarget!.globalSprite
            let base = pet.chatSize.width, left = placementTarget!.globalBubble.minX, column = chat.viewportWidth, preferred = preferredChatSize
            check(!web.open && web.width == 0 && web.tabs.isEmpty, "No page is open to begin with")
            check(!showBeside(folder.appendingPathComponent("문서.hwp")) && !web.open, "A file the page cannot draw is left to its own app")
            check(paneFits, "The check needs a screen with room for a page: \(screen.visibleFrame)")

            let trace = MotionTrace()
            motionTrace = trace; trace.begin("open")
            check(showBeside(page) && web.open && web.tabs.count == 1, "A saved page opens beside the conversation")
            check(web.sliding || ChatView.reducesMotionForChecks, "The window eases to its new width")
            check(ChatView.reducesMotionForChecks ? !pet.hasWidthPicture : pet.widthPictureVisible, "The pane uses a picture only with motion enabled")
            if !ChatView.reducesMotionForChecks {
                check(web.current?.loadedView == nil && !web.ready, "Opening defers the web process until the glass stops")
            }
            await settle()
            motionTrace = nil; trace.end(snapshotMS: paneSnapshotMS, settleMS: paneSettlementMS)
            check(trace.lastLayouts == 0 && trace.lastFilters == 0 && trace.lastPageLayouts == 0 && widthViewportChanges == 0, "Opening freezes live content and page geometry")
            check(!pet.hasWidthPicture && pet.chatShown && pet.chatAlpha == 1, "Opening removes the picture and restores content")
            try? "creation_ms=\(web.current?.creationMS ?? 0) load_ms=\(web.loadMS) settle_ms=\(paneSettlementMS) capture_ms=\(pet.widthCaptureMS)\n"
                .write(to: destination.appendingPathComponent("pane-prepare.txt"), atomically: true, encoding: .utf8)
            if CommandLine.arguments.contains("--ui-smoke-motion-only") {
                motionTrace = trace; trace.begin("close"); web.close(); await settle()
                motionTrace = nil; trace.end(snapshotMS: paneSnapshotMS, settleMS: paneSettlementMS)
                check(trace.lastLayouts == 0 && trace.lastFilters == 0 && trace.lastPageLayouts == 0, "Measured closing freezes live content")
                check(!pet.hasWidthPicture && !web.open && web.tabs.isEmpty, "Measured closing removes its cover and page")
                trace.write(to: destination.appendingPathComponent("pane-slide.tsv"))
                NSApp.terminate(nil); return
            }
            let split = paneSplit(on: screen)
            let expectedTall = PetPlacement(spriteOrigin: originalAnchor, scale: pet.petScale, visibleFrame: screen.visibleFrame,
                screenFrame: screen.frame, expanded: true, preferredSize: CGSize(width: split.base, height: PetLayout.defaultPaneHeight),
                trailing: split.pane, expandToFit: true)
            check(!web.sliding && web.width == split.pane && split.pane >= PetLayout.usablePaneWidth, "The page has slid out: \(web.width) of \(split)")
            check(abs(pet.chatSize.width - (split.base + split.pane)) < 0.5 && abs(pet.placement!.globalBubble.width - pet.chatSize.width) < 0.5,
                  "The window is wider by the page: \(pet.chatSize.width) for \(split)")
            if split.base == base {
                check(split.pane == min(PetLayout.defaultPaneWidth, safe.width - base), "The default page is twice the usual chat width when the screen has room: \(split) for \(base)")
                check(chat.viewportWidth == column, "The conversation keeps its width: \(chat.viewportWidth) was \(column)")
                check(abs(pet.placement!.globalBubble.minX - expectedTall.globalBubble.minX) < 1,
                      "The tall conversation follows the pet placement and screen bounds: \(pet.placement!.globalBubble) was at \(left)")
            }
            check(pet.placement!.globalBubble.maxX <= safe.maxX + 0.5 && pet.placement!.globalBubble.minX >= safe.minX - 0.5, "The window stays on the screen")
            let seen1 = await loaded("합성 페이지")
            check(seen1, "The page is drawn: \(web.current?.title ?? "")")
            let seen2 = await script("document.getElementById('where').textContent")
            check(seen2 == "ddots", "Its scripts run")
            check(web.current?.view.frame.width == split.pane, "The page is laid out at the pane's width: \(String(describing: web.current?.view.frame))")
            check(abs(pet.chatSize.height - expectedTall.globalBubble.height) < 0.5 && pet.chatSize.height > originalHeight,
                  "The pane grows to the default height limited by placement: \(pet.chatSize.height), expected \(expectedTall.globalBubble.height)")
            check(pet.placement!.globalBubble.minY >= safe.minY - 0.5 && pet.placement!.globalBubble.maxY <= screen.visibleFrame.maxY + 0.5,
                  "The tall pane stays within the screen vertically")
            check(preferredChatSize == preferred, "Opening the tall pane preserves the saved conversation size")
            try! "height_pt=\(pet.chatSize.height) original_height_pt=\(originalHeight) anchor_rise_pt=\(placementTarget!.anchorOrigin.y-originalAnchor.y) sprite_rise_pt=\(placementTarget!.globalSprite.minY-originalSprite.minY)\n"
                .write(to: destination.appendingPathComponent("web-tall.txt"), atomically: true, encoding: .utf8)
            await shot("web-tall")
            await shot("web")

            @MainActor func pageCover(in view: NSView) -> Bool {
                if let surface = view as? WebPictureSurface, surface.hasPicture || surface.revealing { return true }
                return view.subviews.contains { pageCover(in: $0) }
            }
            check(!pageCover(in: pet), "A settled page has no reveal cover left")
            check(web.current?.loadedView?.layer?.filters?.isEmpty ?? true, "The page has no live blur filter")
            /// What the layer tree holds right now, covers included; `cacheDisplay` leaves out layers a view did not draw.
            @MainActor func rendered(_ name: String) -> NSBitmapImageRep? {
                guard let layer = pet.layer, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pet.bounds.width), pixelsHigh: Int(pet.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
                layer.render(in: context.cgContext)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + ".png"))
                return bitmap
            }
            /// The test page has a green bar across its top: the page's picture is on screen when that green is drawn there.
            @MainActor func pageDrawn(_ name: String) -> Bool {
                guard let rect = pet.panePageRect, rect.width > 40, let bitmap = rendered(name),
                      let color = bitmap.colorAt(x: Int(rect.midX), y: Int(pet.bounds.height - (rect.maxY - rect.height * 0.06)))?.usingColorSpace(.deviceRGB) else { return false }
                return color.alphaComponent > 0.5 && color.greenComponent > color.redComponent + 0.2 && color.greenComponent > color.blueComponent + 0.2
            }
            @MainActor func coveredPage(_ name: String) -> Bool {
                guard let rect = pet.panePageRect, rect.width > 80, let bitmap = rendered(name) else { return false }
                for fraction in stride(from: CGFloat(0.15), through: 0.95, by: 0.05) {
                    guard let color = bitmap.colorAt(x: Int(rect.maxX - 24), y: Int(pet.bounds.height - (rect.maxY - rect.height * fraction)))?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.9, color.redComponent > 0.65, color.greenComponent > 0.65, color.blueComponent > 0.65 else { return false }
                }
                return true
            }
            @MainActor func savePicture(_ picture: WebPicture, _ name: String) {
                try? NSBitmapImageRep(cgImage: picture.sharp).representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + "-sharp.png"))
                try? NSBitmapImageRep(cgImage: picture.soft).representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + "-soft.png"))
            }
            if !ChatView.reducesMotionForChecks {
                check(web.current!.revealCount > 0, "A new page reveals a blurred picture after settling; trace:\n" + (web.current?.revealTrace.joined(separator: "\n") ?? ""))
                web.current?.takePicture(); await settle(0.6)
                check(web.current?.picture != nil, "WebKit returns a cached page picture")
                if let picture = web.current?.picture { savePicture(picture, "page-picture") }
                try? "snapshot_and_blur_ms=\(web.current?.snapshotMS ?? 0)\n".write(to: destination.appendingPathComponent("page-picture-time.txt"), atomically: true, encoding: .utf8)
            } else {
                check(web.current?.picture == nil && !pet.hasPanePagePicture, "Reduced motion has no page pictures")
            }

            // Oversized local content exercises AppKit's event routing into the web process.
            _ = await script("document.body.insertAdjacentHTML('beforeend', '<div style=\"width:1600px;height:1800px;background:linear-gradient(135deg,#eee,#bfd)\">가로·세로 스크롤 점검</div>')")
            await settle(0.3)
            @MainActor func wheel(_ x: Int32, _ y: Int32) async {
                guard let page = web.current?.view else { return }
                let point = page.convert(CGPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
                // CGEvent creates an NSEvent without a window. sendEvent reads locationInWindow directly,
                // so supply window coordinates, converted from Quartz's downward Y axis.
                event.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
                panel.sendEvent(NSEvent(cgEvent: event)!)
                await settle(0.5)
            }
            let pagePoint = web.current!.view.convert(CGPoint(x: 100, y: 100), to: pet)
            let hit = pet.hitTest(pagePoint)
            let frameBefore = panel.frame
            await wheel(0, -180)
            let scrollY = await script("window.scrollY")
            await wheel(-180, 0)
            let scrollX = await script("window.scrollX")
            let scrolling = "scrollX=\(scrollX), scrollY=\(scrollY), hit=\(String(describing: hit)), pageFrame=\(web.current!.view.frame), stableFrame=\(frameBefore == panel.frame), key=\(panel.isKeyWindow)\n"
            try! scrolling.write(to: destination.appendingPathComponent("web-scrolling.txt"), atomically: true, encoding: .utf8)
            check((Double(scrollY) ?? 0) > 0 && (Double(scrollX) ?? 0) > 0, "Wheel events scroll both axes: " + scrolling)
            await shot("web-scrolled")
            _ = await script("window.scrollTo(0,0)")
            await settle(0.3)

            let tab = web.current!
            check(tab.view.allowsMagnification, "Trackpad magnification is enabled")
            tab.view.setMagnification(1.5, centeredAt: CGPoint(x:100,y:100))
            await settle(0.3)
            check(abs(tab.view.magnification-1.5) < 0.01, "The page can zoom in")
            _ = await script("window.scrollTo(0,0)")
            await settle(0.5)
            await wheel(0, -160); await wheel(-160, 0)
            let zoomX = await script("window.visualViewport.pageLeft"), zoomY = await script("window.visualViewport.pageTop")
            check((Double(zoomX) ?? 0) > 0 && (Double(zoomY) ?? 0) > 0, "Both axes scroll while magnified: \(zoomX), \(zoomY)")
            await shot("web-magnified")
            tab.view.setMagnification(1, centeredAt: .zero)
            check(abs(tab.view.magnification-1) < 0.01, "The page can zoom back out")
            _ = await script("window.scrollTo(0,0)")
            // A synthetic URL tests presentation without asking the network for a page.
            let savedFile = tab.file, savedURL = tab.url
            let address = "https://example.invalid/maps/place?name=ddots#details"
            tab.file = nil; tab.url = URL(string: address); tab.address = tab.shownAddress
            check(tab.address == address, "The whole web address, including query and fragment, is retained")
            await settle(0.3)
            await shot("web-address")

            var typed = "skipped: the window is not key", editing = "SKIPPED: not key"
            if panel.isKeyWindow, let view = web.current?.view {
                panel.makeFirstResponder(view)
                _ = await script("document.getElementById('field').focus()")
                check(web.hasFocus(in: panel), "The keyboard is in the page")
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: panel.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!)
                }
                await settle(0.5)
                typed = await script("document.getElementById('field').value")
                check(!typed.isEmpty && chatExpanded, "A key typed in the page lands in its field and the conversation stays open: '\(typed)'")
                @MainActor func command(_ key: String, _ code: UInt16) -> NSEvent {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                                     characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
                }
                usedBoard = true
                final class KeyChanges { var list: [String] = [] }
                let keyChanges = KeyChanges()
                let keyWatch = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                        keyChanges.list.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + note.name.rawValue + " " + String(describing: (note.object as? NSWindow).map { type(of: $0) }))
                    }
                }
                defer { keyWatch.forEach(NotificationCenter.default.removeObserver) }
                for (copy, paste) in [("c", "v"), ("ㅊ", "ㅍ")] {
                    let state = "[document.hasFocus(), document.activeElement ? document.activeElement.id || document.activeElement.tagName : 'none', window.getSelection().toString()].join('|')"
                    // The page is made first responder before anything is selected: WebKit can hand focus back to the field it
                    // last had once the view takes the keyboard, which empties a selection made before. Wait until that has settled.
                    let wasResponder = panel.firstResponder === view
                    panel.makeFirstResponder(view)
                    var afterResponder = ""
                    for _ in 0..<20 {
                        let focus = await script("[document.hasFocus(), document.activeElement ? document.activeElement.id || document.activeElement.tagName : 'none'].join('|')")
                        if focus == afterResponder, focus.hasPrefix("true") { break }
                        afterResponder = focus; await settle(0.1)
                    }
                    let made = await script("document.getElementById('field').blur(); var r=document.createRange(); r.selectNodeContents(document.getElementById('where')); var s=window.getSelection(); s.removeAllRanges(); s.addRange(r); " + state)
                    await settle(0.3)
                    let selected = await script("window.getSelection().toString()")
                    let trail = await script("'now='+Math.round(performance.now())+' '+trail.slice(-14).join(' ')")
                    let selectionTrace = "trail=\(trail) keyChanges=\(keyChanges.list.suffix(6)) made=\(made) responderBefore=\(wasResponder) afterResponder=\(afterResponder) active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"), "
                    let target = NSApp.target(forAction: #selector(NSText.copy(_:)))
                    board.clearContents()
                    NSApp.sendEvent(command(copy, 8)); await settle(0.3)
                    let copyLog = selectionTrace + "key=\(panel.isKeyWindow), appKey=\(NSApp.keyWindow === panel), responder=\(String(describing: panel.firstResponder)), target=\(String(describing: target)), selected=\(selected), copied=\(board.string(forType: .string) ?? "nil")\n"
                    try? copyLog.write(to: destination.appendingPathComponent("web-copy.txt"), atomically: true, encoding: .utf8)
                    check(board.string(forType: .string) == "ddots", "Page selection copies with \(copy): " + copyLog)
                    board.clearContents(); board.setString("붙여넣기 점검", forType: .string)
                    _ = await script("window.getSelection().removeAllRanges(); var f=document.getElementById('field'); f.value=''; f.focus()")
                    NSApp.sendEvent(command(paste, 9)); await settle(0.3)
                    let pasted = await script("document.getElementById('field').value")
                    check(pasted == "붙여넣기 점검", "Page field pastes with \(paste): \(pasted)")
                    web.addressFocus += 1; await settle(0.3)
                    guard let editor = panel.firstResponder as? NSTextView else { check(false, "Address editor has focus"); return }
                    check(editor.string == address, "The visible address editor contains the whole URL: \(editor.string)")
                    NSApp.sendEvent(command("a", 0)); NSApp.sendEvent(command(copy, 8)); await settle(0.3)
                    check(board.string(forType: .string) == address, "Address copies with \(copy)")
                    board.clearContents(); board.setString("https://example.invalid/pasted", forType: .string)
                    NSApp.sendEvent(command(paste, 9)); await settle(0.3)
                    check(editor.string == "https://example.invalid/pasted" && tab.address == editor.string, "Address pastes with \(paste)")
                    panel.makeFirstResponder(view); await settle(0.3)
                }
                restoreBoard()
                editing = "PASS: address and page, Latin and Korean key characters"
                check(panel.performKeyEquivalent(with: command("t", 17)) && web.tabs.count == 2, "⌘T opens a tab")
                await settle(0.5)
                check(web.addressFocused, "A new tab waits for an address")
                check(panel.performKeyEquivalent(with: command("w", 13)) && web.tabs.count == 1, "⌘W closes it")
                await settle(0.3)
            }

            tab.file = savedFile; tab.url = savedURL; tab.address = tab.shownAddress
            _ = await script("document.getElementById('next').click()")
            await settle(1)
            check(web.tabs.count == 2 && web.selected == web.tabs[1].id, "A link that asks for a window gets a tab: \(web.tabs.count)")
            let seen3 = await loaded("둘째 페이지")
            check(seen3, "The new tab shows the linked page")
            check(web.current!.view.allowsMagnification && web.current!.view.magnification == 1, "New tabs start at normal zoom and allow gestures")
            web.current!.view.setMagnification(1.2, centeredAt: .zero)
            web.current!.view.loadFileURL(second, allowingReadAccessTo: folder)
            await settle(0.5)
            check(web.current!.view.allowsMagnification, "Navigation keeps magnification available")

            check(showBeside(paper) && web.tabs.count == 3 && web.current?.file == paper, "A PDF opens in a tab of its own")
            await settle(1)
            check(web.current?.label == "보기.pdf" && web.current?.address == "보기.pdf", "A file is named by its name: \(web.current?.label ?? "")")
            await shot("web-pdf")
            check(showBeside(paper) && web.tabs.count == 3, "A file already open is brought forward, not opened twice")
            check(showBeside(note) && web.tabs.count == 4, "A text file opens too")
            await settle(1)
            let seen4 = await script("document.body.innerText")
            check(seen4.contains("한글 메모"), "Korean text is read as written")
            web.selected = web.tabs[0].id
            await settle(0.3)
            let seen5 = await script("document.title")
            check(seen5 == "합성 페이지", "Going back to a tab finds its page as it was")

            let height = pet.chatSize.height
            resizePane(to: 300); pet.layoutSubtreeIfNeeded()
            check(paneWanted == 300 && web.width == 300 && abs(pet.chatSize.width - (split.base + 300)) < 0.5 && chat.viewportWidth == column, "The page can be made narrower")
            resizePane(to: 10)
            check(web.width == PetLayout.minimumPaneWidth, "It stops at its least width")
            resizeChat(to: CGSize(width: pet.chatSize.width - web.width, height: height))
            check(preferredChatSize == preferred, "Sizing with a page open leaves the conversation's own width alone")
            resizeChat(to: CGSize(width: pet.chatSize.width - web.width, height: 650))
            await settle()
            check(savedPaneHeight == 650 && pet.chatSize.height == 650 && preferredChatSize == preferred,
                  "Dragging the tall pane stores only its height")
            resetPaneSize()
            check(savedPaneHeight == nil && abs(pet.chatSize.height - expectedTall.globalBubble.height) < 0.5,
                  "Reset restores the default pane height")
            check(savedPaneWidth == nil && web.width == split.pane, "Reset restores the twice-usual default width")

            collapseChat(); await settle()
            check(web.open && web.tabs.count == 4 && !pet.chatShown, "Folding the conversation keeps the pages")
            showChat(); await settle()
            check(web.width == split.pane && abs(pet.chatSize.width - (split.base + split.pane)) < 0.5, "Opened again, the page is back beside it")

            web.closeTab(web.tabs[3].id)
            check(web.tabs.count == 3 && web.open, "Closing a tab leaves the others")
            @MainActor func blankBar(in view: NSView) -> WebTabBlankView? { (view as? WebTabBlankView) ?? view.subviews.lazy.compactMap(blankBar).first }
            guard let bar = blankBar(in: pet), let tabRect = bar.occupied.first else { check(false, "The tab row exposes its occupied areas"); return }
            @MainActor func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: bar.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            }
            let onTab = CGPoint(x: tabRect.midX, y: tabRect.midY)
            check(!bar.handle(event(.leftMouseDown, onTab, clicks: 2)) && !bar.handle(event(.leftMouseUp, onTab, clicks: 2)) && web.open, "Double clicking a tab is left to the tab")
            guard let blank = stride(from: CGFloat(8), to: bar.bounds.width-8, by: 4).map({ CGPoint(x: $0, y: bar.bounds.midY) }).first(where: bar.blank) else { check(false, "The test tab row has blank space"); return }
            check(!bar.handle(event(.leftMouseDown, blank, clicks: 1)) && !bar.handle(event(.leftMouseUp, blank, clicks: 1)) && web.open, "A blank single click passes through")
            _ = bar.handle(event(.leftMouseDown, blank, clicks: 2))
            _ = bar.handle(event(.leftMouseDragged, CGPoint(x: blank.x+10, y: blank.y), clicks: 2))
            check(!bar.handle(event(.leftMouseUp, blank, clicks: 2)) && web.open, "Dragging blank space passes through without closing")
            if !ChatView.reducesMotionForChecks { web.current?.takePicture(); await settle(0.6) }
            let closedPage = web.current?.file ?? web.current?.url
            motionTrace = trace; trace.begin("close")
            _ = bar.handle(event(.leftMouseDown, blank, clicks: 2))
            check(bar.handle(event(.leftMouseUp, blank, clicks: 2)), "A blank double click closes the pane")
            if !ChatView.reducesMotionForChecks { check(pet.hasPanePagePicture, "Closing shows its cached page on the first frame") }
            if !ChatView.reducesMotionForChecks {
                check(pageDrawn("closing-first"), "The closing page is drawn over the glass at once")
                await settle(0.12)
                check(coveredPage("web-tall-closing-middle"), "The shrinking page picture covers its whole height without a blank strip")
                check(pageDrawn("closing-middle"), "The closing page stays drawn over the glass while it slides")
            }
            check(!web.open && (ChatView.reducesMotionForChecks ? web.tabs.isEmpty : !web.tabs.isEmpty), "Closing keeps the page only while it slides out")
            await settle()
            motionTrace = nil; trace.end(snapshotMS: paneSnapshotMS, settleMS: paneSettlementMS)
            trace.write(to: destination.appendingPathComponent("pane-slide.tsv"))
            check(trace.lastLayouts == 0 && trace.lastFilters == 0 && trace.lastPageLayouts == 0 && widthViewportChanges == 0, "Closing freezes live content and page geometry")
            check(!pet.hasWidthPicture && pet.chatShown && pet.chatAlpha == 1, "Closing removes the picture and restores content")
            try? "snapshot_ms=\(paneSnapshotMS), page=\(paneSnapshotUsed)\n".write(to: destination.appendingPathComponent("pane-snapshot.txt"), atomically: true, encoding: .utf8)
            check(web.tabs.isEmpty && web.width == 0 && !web.sliding, "Then the pages are let go")
            check(abs(pet.chatSize.width - base) < 0.5 && chat.viewportWidth == column && abs(pet.placement!.globalBubble.minX - left) < 1,
                  "The window is as it was: \(pet.chatSize.width) was \(base), \(pet.placement!.globalBubble.minX) was \(left)")
            check(abs(pet.chatSize.height - originalHeight) < 0.5 && hypot(placementTarget!.anchorOrigin.x-originalAnchor.x, placementTarget!.anchorOrigin.y-originalAnchor.y) < 0.5,
                  "Closing restores the original height and pet anchor: \(pet.chatSize.height), \(placementTarget!.anchorOrigin), expected \(originalHeight), \(originalAnchor)")
            check(preferredChatSize == preferred, "The saved conversation size survives opening, resizing, folding and closing")
            await shot("web-closed")
            try! "PASS: page beside the conversation, width shared with the chat window, tabs, new-window links, PDF and text files, resizing, folding, closing\nwheel routing: \(scrolling)zoom scrolling: \(zoomX), \(zoomY)\ncopy/paste: \(editing)\ntyped in the page: \(typed)\nsplit: \(split) on \(screen.visibleFrame)\n"
                .write(to: destination.appendingPathComponent("web.txt"), atomically: true, encoding: .utf8)
            if !ChatView.reducesMotionForChecks {
                if let closedPage {
                    _ = showBeside(closedPage)
                    check(pet.hasPanePagePicture, "Reopening uses the recently closed picture during motion")
                    await settle(0.12)
                    check(coveredPage("web-tall-opening-middle"), "The growing page picture covers its whole height without a blank strip")
                    check(pageDrawn("reopening-middle"), "The reopening page is drawn over the glass while it slides")
                    await settle()
                    check(!pet.hasPanePagePicture && web.open, "Reopening removes its picture")
                    if let tab = web.current {
                        tab.discardPicture(); web.close(); await settle(0.2)
                        check(pet.hasPanePagePicture, "An uncached close accepts a picture without delaying motion")
                        if let picture = tab.picture { savePicture(picture, "closing-picture") }
                        try? "snapshot_and_blur_ms=\(tab.snapshotMS)\n".write(to: destination.appendingPathComponent("closing-picture-time.txt"), atomically: true, encoding: .utf8)
                        await settle()
                        _ = showBeside(closedPage)
                        check(pet.hasPanePagePicture, "A picture received while closing survives for reopening")
                        await settle(); web.close(); await settle()
                    }
                }
                _ = showBeside(page); await settle(0.12)
                check(pet.widthPictureVisible && pet.widthPictureTransparent, "An opening pane has a transparent-background picture")
                capture(destination: destination.appendingPathComponent("pane-opening"))
                web.close(); await settle(0.1)
                check(pet.hasWidthPicture, "Closing during opening keeps a picture")
                _ = showBeside(page); await settle()
                check(web.open && !pet.hasWidthPicture, "Reversing a pane transition settles open")
                web.close(); await settle(0.12)
                capture(destination: destination.appendingPathComponent("pane-closing"))
                await settle()
                check(!pet.hasWidthPicture && !web.open && web.tabs.isEmpty, "A reversed pane leaves no picture or tab behind")
                _ = showBeside(page); await settle()
                if let tab = web.current {
                    tab.takePicture(); await settle(0.6)
                    web.closeTab(tab.id)
                    check(tab.picture == nil, "Explicitly closing a tab discards its picture")
                }
                resetChatSize(); await settle(0.1)
                check(!widthSliding && !pet.hasWidthPicture && web.tabs.isEmpty && web.width == 0, "Reset settles deferred page content without restarting the slide")
            }
            // Outside opens are recorded only: this check must never launch another app.
            web.openOutside()
            check(external.isEmpty && !web.open, "An empty pane has nothing to open outside")
            web.newTab(); await settle()
            web.openOutside()
            check(external.isEmpty && web.open, "A blank tab stays open when there is no destination")
            web.close(); await settle()
            _ = showBeside(page); await settle()
            let outsideLoaded = await loaded("합성 페이지")
            check(outsideLoaded, "The outside-open fixture has loaded")
            await shot("web-open-outside")
            // Present a web URL without loading anything from the network.
            let outsideURL = URL(string: "https://example.invalid/outside")!
            web.current?.file = nil; web.current?.url = outsideURL
            web.openOutside()
            check(external == [outsideURL] && !web.open, "Opening a web URL outside records it once and closes the pane")
            await settle()
            check(web.tabs.isEmpty && web.width == 0, "Opening outside unloads the page after closing")

            _ = showBeside(page); await settle()
            _ = showBeside(paper); await settle()
            check(web.tabs.count == 2, "There are two tabs before opening the PDF outside")
            web.openOutside()
            check(external == [outsideURL, paper] && !web.open, "Opening a file outside closes the entire pane")
            await settle()
            check(web.tabs.isEmpty && web.width == 0, "All tabs are unloaded after opening outside")

            let originalPersists = slack.persists
            slack.persists = false
            defer { slack.persists = originalPersists }
            slack.showTemporary(note); await settle()
            check(web.open && web.current?.file == note, "A temporary Slack attachment opens beside the conversation")
            let temporaryTab = web.current!
            check(!temporaryTab.view.configuration.websiteDataStore.isPersistent, "The temporary attachment uses a nonpersistent store")
            _ = showBeside(page); await settle()
            check(temporaryTab.view.configuration.websiteDataStore !== web.current!.view.configuration.websiteDataStore,
                  "The confidential attachment has a separate store from ordinary tabs")
            slack.showTemporary(note)
            check(web.current === temporaryTab && web.tabs.count == 2, "Reopening a temporary attachment selects its existing tab")
            web.close(); await settle()

            let vaultModel = SlackModel()
            vaultModel.source = .slack; vaultModel.selected = "FAKE-VAULT"
            vaultModel.vaultOverride = ShrimpVault(root: folder.path)
            var selectionMessage = ChatMessage(id: "fake-web-vault", fromUser: false, speaker: "새우튀김",
                body: "선택: 메모.txt", date: Date())
            selectionMessage.slackUserID = ShrimpVault.defaultBot
            let vaultThread = SlackThread(id: "fake-web-vault-thread", room: "FAKE-VAULT", ts: "1", root: selectionMessage,
                replies: [], replyCount: 0, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
            vaultModel.threads = [vaultThread]
            vaultModel.onShowFile = { [self] url in
                check(slack.model.onShowFile?(url) == true, "The vault file is accepted by the app's pane callback")
                return true // A failure must never fall through to NSWorkspace in this check.
            }
            guard let selection = vaultModel.vaultSelection(vaultThread) else { check(false, "The synthetic vault selection is valid"); return }
            vaultModel.vaultAction("파일오픈", thread: vaultThread, selection: selection)
            await settle()
            check(vaultModel.notice == nil && web.current?.file == note && web.open, "Vault file-open resolves the file and opens it in the pane")
            web.close(); await settle()

            // A preloaded local page stands in for a web address so bubble routing never uses the network.
            _ = showBeside(page); await settle()
            let bubbleTab = web.current!
            bubbleTab.file = nil; bubbleTab.url = outsideURL
            _ = showBeside(second); await settle()
            collapseChat(); await settle()
            perform(PetAction(kind: .openLink(outsideURL), title: "링크 열기"))
            if !ChatView.reducesMotionForChecks {
                check(web.current !== bubbleTab, "The bubble link waits for the conversation to unfold")
            }
            await settle(2)
            check(chatExpanded && perchTransition == nil && !web.sliding && web.current === bubbleTab && web.tabs.count == 2,
                  "The bubble link selects its page after unfolding without overlapping transitions")
            check(external == [outsideURL, paper], "Pane routing caused no additional outside opens")
            web.close(); await settle()
            // Replace the queued web request with a local page before WebKit starts, retaining the real opening path.
            let originalLayout = web.onLayout
            var bubbleOpenedAfterUnfold = false
            web.onLayout = { [self] in
                if let tab = web.current, tab.pendingURL == outsideURL {
                    bubbleOpenedAfterUnfold = chatExpanded && perchTransition == nil && !pet.genieActive
                    tab.pendingURL = page
                }
                originalLayout?()
            }
            defer { web.onLayout = originalLayout }
            collapseChat(); await settle()
            perform(PetAction(kind: .openLink(outsideURL), title: "링크 열기"))
            if !ChatView.reducesMotionForChecks { check(!web.open, "A new pane waits for unfolding to finish") }
            await settle(3)
            check(bubbleOpenedAfterUnfold && chatExpanded && web.open && web.current?.file == page && !web.sliding,
                  "A bubble link opens a new pane only after the folded conversation settles")
            web.onLayout = originalLayout
            web.close(); await settle()
            try! "PASS: outside web/file opens close all tabs; empty destinations stay; temporary attachments use a separate nonpersistent store; vault file-open; bubble link after unfolding\n"
                .write(to: destination.appendingPathComponent("web-routing.txt"), atomically: true, encoding: .utf8)
            web.showShrimpList(); await settle()
            check(abs(pet.chatSize.height - expectedTall.globalBubble.height) < 0.5 && preferredChatSize == preferred,
                  "The native list uses the same tall pane without changing the saved conversation size")
            web.toggleShrimpList(); await settle()
            check(web.shrimpCollapsed && pet.chatSize.height == originalHeight, "A folded list restores the conversation height")
            web.toggleShrimpList(); await settle()
            check(web.open && abs(pet.chatSize.height - expectedTall.globalBubble.height) < 0.5, "Unfolding the list restores the tall pane")
            web.close(); await settle()
            _ = showBeside(page); await settle()
            let moved = CGPoint(x: placementTarget!.anchorOrigin.x + 60, y: placementTarget!.anchorOrigin.y)
            movePet(to: moved); await settle()
            let movedAnchor = placementTarget!.anchorOrigin
            web.close(); await settle()
            check(hypot(placementTarget!.anchorOrigin.x-movedAnchor.x, placementTarget!.anchorOrigin.y-movedAnchor.y) < 0.5,
                  "Closing after a manual pet move keeps the new anchor")
            check(preferredChatSize == preferred, "The tall pane never changes the saved conversation size")
            restoreBoard()
            NSApp.terminate(nil)
        }
    }
}
