import AppKit
import Vision

actor ClipboardSmokeModelCalls {
    private var count = 0
    func record() { count += 1 }
    func value() -> Int { count }
}

extension AppDelegate {
    @MainActor func verifyClipboardEnabled(library: ClipboardLibrary, board: NSPasteboard, destination: URL, modelCalls: ClipboardSmokeModelCalls) async {
        let oldPointer = pet.pointerLocation, oldSettings = library.settings, oldAlways = pet.bubbleAlwaysShown
        var pointer = CGPoint(x: -10000, y: -10000)
        pet.pointerLocation = { pointer }; pet.bubbleAlwaysShown = false
        defer { library.changeSettings(oldSettings, persist: false); pet.pointerLocation = oldPointer; pet.bubbleAlwaysShown = oldAlways }
        func pause(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func move(_ p: CGPoint) async {
            pointer = p; clipboardSmokePointerMoved(p, panel: panel); await pause()
        }
        func head() -> CGPoint {
            let r = pet.atlas.interactionRect(in: pet.spriteRect)
            return panel.convertPoint(toScreen: pet.convert(CGPoint(x: r.midX, y: r.midY), to: nil))
        }
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        func capture(_ name: String) async -> String {
            do {
                let url = destination.appendingPathComponent(name + ".png")
                try await clipboardCaptureWindow(panel, to: url)
                let image = NSBitmapImageRep(data: try Data(contentsOf: url))!.cgImage!
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ko-KR", "en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            } catch { failures.append(name + " capture: \(error)"); return "" }
        }
        pet.state = .idle; slack.model.approvalThreads = []; nudges.dismiss(); setBubbleActions([])
        pet.dismissClipboard(); pet.cancelClipboardCopyNotice()
        library.add(ClipboardInput(kind: .text, text: "T64", source: "fixture", secret: true))
        for _ in 0..<300 { if library.entries.first?.text == "T64" { break }; await pause(0.02) }
        await move(CGPoint(x: -10000, y: -10000)); await move(head())
        await clipboardSmokeOpenDrawer(pet, panel: panel); await pause()
        let savedEntries = library.entries, secret = library.entries.first { $0.text == "T64" }!
        library.toggleReveal(secret.id); check(library.revealedID == secret.id, "secret fixture revealed before disable")
        var settings = library.settings; settings.semanticSearch = true; settings.enabled = false
        library.changeSettings(settings, persist: false)
        // Production onChange must close synchronously, including concealment and hot-key release.
        check(!pet.clipboardPresented && !pet.clipboardRowVisible && library.revealedID == nil, "immediate close, row removal and concealment")
        let calls = await modelCalls.value()
        for i in 0..<3 {
            board.clearContents(); board.setString("disabled-\(i)", forType: .string); library.monitor.poll()
            library.searchMeaning("뜻 검색 대역", entries: library.entries)
            await pause(0.55)
        }
        pet.showClipboardCopyNotice("DISABLED COPY CHECK")
        await move(CGPoint(x: -10000, y: -10000)); await move(head()); await pause()
        menuNeedsUpdate(menu)
        let count = await modelCalls.value()
        check(count == calls && library.semantic.ids.isEmpty, "disabled search makes zero model calls")
        check(!library.monitor.running && !library.monitor.polling && library.entries == savedEntries, "three disabled copies record zero and preserve all entries")
        check(!library.available && !pet.clipboardRowVisible && !pet.clipboardPresented && pet.clipboardCopyFrame == nil, "disabled feature has no presentation or copy notice")
        check(clipboardHotKey?.isRegistered == false, "disabled shortcut unregistered")
        check(!ClipboardDrop(library: library).accepts(board) && !ClipboardDrop(library: library).receive(board), "disabled pet drop rejects without reading")
        let menuItems = menu.items.filter { $0.action == #selector(toggleClipboardPause) || $0.action == #selector(clearClipboard) }
        check(menuItems.count == 2 && menuItems.allSatisfy(\.isHidden), "clipboard menu entries hidden")
        check(pet.placement!.globalBubble.size == CGSize(width: 231, height: 56) && pet.foldedHeight == 56,
            "disabled bubble restores original folded frame")
        pet.toggleClipboardFromShortcut(); await pause(0.1); check(!pet.clipboardPresented, "disabled shortcut path cannot reopen")
        let offFrame = pet.placement!.globalBubble, offPixels = await capture("clipboard-disabled")
        check(!offPixels.isEmpty && !offPixels.contains("클립보드") && !offPixels.contains("DISABLED COPY CHECK"), "disabled actual pixels contain original bubble only")
        settings.enabled = true; library.changeSettings(settings, persist: false)
        await move(CGPoint(x: -10000, y: -10000)); await move(head()); await pause()
        check(library.entries == savedEntries && pet.clipboardRowVisible && library.monitor.running, "reenable restores entries and row")
        check(clipboardHotKey?.isRegistered == true, "reenable registers shortcut")
        let onPixels = await capture("clipboard-enabled")
        check(onPixels.contains("클립보드") && !onPixels.contains("T64"), "enabled row pixels return without secret contents")
        try! JSONSerialization.data(withJSONObject: ["failures": failures, "savedCount": savedEntries.count, "finalCount": library.entries.count,
            "disabledCopies": 3, "disabledModelCalls": count - calls, "disabledBubbleSize": [offFrame.width, offFrame.height],
            "disabledPixelsHaveClipboard": offPixels.contains("클립보드"), "enabledPixelsHaveClipboard": onPixels.contains("클립보드")], options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("clipboard-enabled.json"))
        if !failures.isEmpty { smokeFailed("T-64 " + failures.joined(separator: "; ")) }
        print("PASS T-64 complete disabled feature, preserved entries, concealment, shortcut, drop, menu and model calls")
    }
    /// Real window/event/pixel regression for the two directions of the same drawer.
    @MainActor func verifyClipboardDirection(library: ClipboardLibrary, destination: URL) async {
        let oldPointer = pet.pointerLocation, physical = NSEvent.mouseLocation
        let oldAlways = pet.bubbleAlwaysShown, oldPreview = isPreview
        let oldFront = NSWorkspace.shared.frontmostApplication, oldAnchor = placementTarget!.anchorOrigin
        let oldSize = clipboardPreferredSize, oldClick = pet.onClick
        pet.pointerLocation = { NSEvent.mouseLocation }; pet.bubbleAlwaysShown = false; isPreview = false
        NSApp.activate(ignoringOtherApps: true)
        defer {
            pet.dismissClipboard(); pet.pointerLocation = oldPointer; pet.bubbleAlwaysShown = oldAlways; isPreview = oldPreview
            pet.onClick = oldClick; clipboardPreferredSize = oldSize
            placePet(at: oldAnchor)
            CGWarpMouseCursorPosition(CGPoint(x: physical.x, y: NSScreen.screens.first!.frame.maxY - physical.y))
            if oldFront?.processIdentifier != getpid() { oldFront?.activate(options: []) }
        }
        var failures: [String] = [], observations: [[String: Any]] = []
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
        func screen(_ r: CGRect) -> CGRect { panel.convertToScreen(pet.convert(r, to: nil)) }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: p), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseUp ? 0 : 1)!, atStart: false)
        }
        func move(_ p: CGPoint) {
            CGWarpMouseCursorPosition(CGPoint(x: p.x, y: NSScreen.screens.first!.frame.maxY - p.y)); event(.mouseMoved, p)
        }
        func click(_ p: CGPoint) { event(.leftMouseDown, p); event(.leftMouseUp, p) }
        func head() -> CGPoint { let r = screen(pet.atlas.interactionRect(in: pet.spriteRect)); return CGPoint(x: r.midX, y: r.midY) }
        func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
        func sample(_ name: String) {
            observations.append(["name": name, "panel": rect(panel.frame), "bubble": rect(screen(pet.chatVisibilityProbe.surface.frame)),
                "row": rect(screen(pet.clipboardRowRect)), "pointer": [NSEvent.mouseLocation.x, NSEvent.mouseLocation.y],
                "below": pet.placement!.bubbleBelow, "presented": pet.clipboardPresented,
                "exitDeadline": pet.clipboardExitTime ?? -1])
        }
        func capture(_ name: String) async -> String {
            do {
                let url = destination.appendingPathComponent(name + ".png")
                try await clipboardCaptureWindow(panel, to: url)
                let image = NSBitmapImageRep(data: try Data(contentsOf: url))!.cgImage!
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ko-KR", "en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            } catch { failures.append(name + " capture: \(error)"); return "" }
        }
        let visible = panel.screen!.visibleFrame
        if chatExpanded { collapseChat(); await pause(0.8) }
        library.editTabs { tabs in tabs.selected = tabs.items.first { $0.kind == .all }!.id }
        await pause(0.1)
        library.add(ClipboardInput(kind: .text, text: "T65", source: "fixture"))
        for _ in 0..<300 { if library.entries.contains(where: { $0.text == "T65" }) { break }; await pause(0.02) }
        slack.model.approvalThreads = []; nudges.dismiss(); pet.state = .idle; setBubbleActions([])
        for below in [true, false] {
            for activation in ["hover", "click"] {
                let name = (below ? "below" : "above") + "-" + activation
                pet.dismissClipboard(); move(CGPoint(x: visible.minX + 2, y: visible.minY + 2)); await pause(0.4)
                placePet(at: CGPoint(x: visible.midX - 90, y: below ? visible.maxY - 145 : visible.minY + 90)); await pause(0.5)
                move(head()); await pause(0.5)
                check(pet.placement!.bubbleBelow == below && pet.clipboardRowVisible, name + " prepared direction and row")
                let foldedRow = screen(pet.clipboardRowRect), p = CGPoint(x: foldedRow.midX, y: foldedRow.midY)
                let foldedBubble = screen(pet.chatVisibilityProbe.surface.frame)
                let foldedPixels = await capture("clipboard-" + name + "-folded")
                check(foldedPixels.contains("클립보드"), name + " folded row pixels")
                move(p); if activation == "click" { await pause(0.02); click(p) }
                var opened = false
                for index in 0..<40 {
                    await pause(0.02)
                    if pet.clipboardPresented {
                        opened = true; sample(name + "-opening-\(index)")
                        check(screen(pet.clipboardRowRect).contains(p), name + " pointer remains under row during opening \(index)")
                    }
                }
                check(opened && pet.clipboardPresented, name + " opens")
                if let field = ClipboardSearch.field(in: pet) {
                    panel.makeKey(); panel.makeFirstResponder(field)
                    field.stringValue = ""; NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
                    if let editor = field.currentEditor() { editor.selectAll(nil); editor.insertText("") }
                } else { failures.append(name + " search preparation field missing") }
                await pause(2); sample(name + "-stationary")
                check(pet.clipboardPresented && pet.clipboardExitTime == nil, name + " stationary two seconds preserves shelf")
                let openedBubble = screen(pet.chatVisibilityProbe.surface.frame), shelf = screen(pet.clipboardPreviewRect)
                let row = screen(pet.clipboardRowRect)
                check(abs((below ? openedBubble.maxY : openedBubble.minY) - (below ? foldedBubble.maxY : foldedBubble.minY)) <= 1,
                    name + " growth anchored at pet edge")
                check(below ? shelf.maxY <= row.minY + 1 : shelf.minY >= row.maxY - 1, name + " content on far side of row")
                let pixels = await capture("clipboard-" + name + "-open")
                check(pixels.contains("T65"), name + " shelf card pixels")
                // The actual tab hit path, not a direct selected-tab assignment.
                @MainActor func selection(_ root: NSView) -> ClipboardSelectionView? {
                    (root as? ClipboardSelectionView) ?? root.subviews.lazy.compactMap(selection).first
                }
                if let tab = selection(pet), let r = tab.tabRects[library.tabs.current.id] {
                    let q = panel.convertPoint(toScreen: tab.convert(CGPoint(x: r.midX, y: r.midY), to: nil))
                    move(q); click(q); await pause(0.4); check(pet.clipboardPresented, name + " tab click preserves shelf")
                } else { failures.append(name + " tab native hit target missing") }
                // The bridge includes the head, thought-dot trail and gap to the glass.
                let h = screen(pet.atlas.interactionRect(in: pet.spriteRect))
                let bridge = CGPoint(x: h.midX, y: below ? (h.minY + openedBubble.maxY) / 2 : (h.maxY + openedBubble.minY) / 2)
                move(bridge); await pause(0.45); sample(name + "-bridge")
                check(pet.clipboardPresented && pet.clipboardExitTime == nil, name + " thought-dot gap does not exit")
                if below && activation == "click" {
                    let far = CGPoint(x: openedBubble.midX, y: openedBubble.minY + 2)
                    move(far); event(.leftMouseDown, far); await pause(0.02)
                    let dragged = CGPoint(x: far.x, y: far.y - 48)
                    event(.leftMouseDragged, dragged); await pause(0.05); event(.leftMouseUp, dragged); await pause(0.5)
                    check(screen(pet.chatVisibilityProbe.surface.frame).height >= openedBubble.height + 47, name + " bottom edge grows down")
                    check(abs(screen(pet.clipboardRowRect).maxY - row.maxY) <= 1, name + " resize retains pet-side footer")
                    resetClipboardSize(); await pause(0.5)
                }
                let outside = CGPoint(x: openedBubble.maxX + 24, y: openedBubble.midY)
                move(outside); await pause(0.15); check(pet.clipboardPresented, name + " exit grace")
                await pause(0.25); sample(name + "-exit")
                check(!pet.clipboardPresented, name + " physical exit closes after .3 seconds")
                if below && activation == "click" {
                    move(head()); await pause(0.4)
                    let r = screen(pet.clipboardRowRect); move(CGPoint(x: r.midX, y: r.midY)); click(CGPoint(x: r.midX, y: r.midY)); await pause(0.5)
                    pet.state = .waiting; await pause(0.2)
                    check(pet.clipboardPresented && pet.clipboardAttention, name + " notification keeps drawer")
                    let notification = screen(pet.clipboardRowRect)
                    check(abs(notification.maxY - screen(pet.chatVisibilityProbe.surface.frame).maxY) <= 1, name + " notification on pet edge")
                    _ = await capture("clipboard-below-notification")
                    var clicks = 0; pet.onClick = { _ in clicks += 1 }
                    click(CGPoint(x: notification.midX, y: notification.midY)); await pause(0.3)
                    check(clicks == 1 && !pet.clipboardPresented, name + " notification uses existing conversation route")
                    pet.onClick = oldClick; pet.state = .idle
                }
            }
        }
        try! JSONSerialization.data(withJSONObject: ["cases": observations, "failures": failures], options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("clipboard-direction.json"))
        if !failures.isEmpty { smokeFailed("T-65 " + failures.joined(separator: "; ")) }
        print("PASS T-65 actual direction, pointer bridge, row pixels, stationary dwell, tabs and exit")
    }
}
