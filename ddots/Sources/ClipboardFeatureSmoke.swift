import AppKit
import QuickLookUI
import Carbon
import ScreenCaptureKit
import Vision
import SwiftUI

extension AppDelegate {
    @MainActor func verifyClipboardFeatures(library: ClipboardLibrary, board: NSPasteboard, keychain: ClipboardKeychain, base: URL, png: Data, destination: URL, capture: (String) -> Void) async {
        let originalPointer = pet.pointerLocation, originalSettings = library.settings, originalSize = clipboardPreferredSize
        var pointer = CGPoint(x: -10000, y: -10000)
        pet.pointerLocation = { pointer }
        defer { pet.pointerLocation = originalPointer; library.changeSettings(originalSettings, persist: false); clipboardPreferredSize = originalSize; library.preview.close() }
        var log: [String] = []
        func record(_ value: String) { log.append(value); try! (log.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("clipboard-features.txt"), atomically: true, encoding: .utf8) }
        func check(_ value: @autoclosure () -> Bool, _ name: String) { if !value() { record("FAIL " + name); capture("features-failure"); smokeFailed(name) } }
        func pause(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); pet.layoutSubtreeIfNeeded() }
        func wait(_ name: String, _ predicate: () -> Bool) async { for _ in 0..<500 { if predicate() { return }; await pause(0.02) }; check(false, name) }
        @MainActor func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] { ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) } }
        func card(_ id: UUID) -> ClipboardCardView { guard let result = descendants(pet, ClipboardCardView.self).first(where: { $0.entry.id == id }) else { smokeFailed("visible fixture card") }; return result }
        func event(_ type: NSEvent.EventType, point: CGPoint, flags: NSEvent.ModifierFlags = []) {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: pet.convert(point, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
        }
        func click(_ view: NSView, flags: NSEvent.ModifierFlags = []) async {
            let frame = view.convert(view.bounds, to: pet), point = CGPoint(x: frame.midX, y: frame.midY)
            event(.leftMouseDown, point: point, flags: flags); event(.leftMouseUp, point: point, flags: flags); await pause(0.05)
        }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], chars: String = "") {
            panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        func search() -> NSTextField {
            guard let field = ClipboardSearch.field(in: pet) else { smokeFailed("native clipboard search field") }; return field
        }
        func query(_ text: String) async {
            let field = search(); panel.makeKey(); panel.makeFirstResponder(field)
            field.stringValue = text; NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            // SwiftUI's field editor receives committed input through the normal input client.
            if let editor = field.currentEditor() { editor.selectAll(nil); editor.insertText(text) }
            await pause(0.35)
        }
        func open() async {
            let head = pet.atlas.interactionRect(in: pet.spriteRect)
            pointer = panel.convertPoint(toScreen: pet.convert(CGPoint(x: head.midX, y: head.midY), to: nil))
            event(.mouseMoved, point: CGPoint(x: head.midX, y: head.midY)); await pause(0.15)
            await clipboardSmokeOpenDrawer(pet, panel: panel); await pause(0.6)
        }
        pet.dismissClipboard(); pet.state = .idle; setBubbleActions([])
        library.changeSettings(ClipboardSettings(), persist: false)
        await pause(3.2)
        library.clear(includingPins: true); await wait("feature clean fixture", { library.entries.isEmpty })
        library.editTabs { $0 = ClipboardTabs() }; await wait("feature default tabs", { library.tabs.items.count == 4 })
        let original = base.appendingPathComponent("selected-original.txt"); try! Data("original".utf8).write(to: original)
        let inputs = [ClipboardInput(kind: .text, text: "alpha first", source: "com.apple.Safari"),
                      ClipboardInput(kind: .text, text: "beta second", source: "com.apple.finder"),
                      ClipboardInput(kind: .files, files: [original.path], source: "com.apple.finder"),
                      ClipboardInput(kind: .image, data: png, dataType: "public.png", source: "fixture"),
                      ClipboardInput(kind: .text, text: "secret-feature-fixture", source: "fixture", secret: true)]
        var entries: [ClipboardEntry] = []
        for input in inputs { library.add(input); await wait("feature fixture add", { library.entries.count == entries.count + 1 }); entries.append(library.entries[0]) }
        resetClipboardSize(); await open()
        panel.makeFirstResponder(pet)
        let secret = entries[4], image = entries[3], file = entries[2], second = entries[1], first = entries[0]
        // T-47 text, masked secret and real Quick Look, with exact owned-file cleanup.
        await click(card(first.id)); panel.makeFirstResponder(pet); library.hoveredID = first.id
        key(49, chars: " "); await wait("T-47 text preview opens", { library.preview.isOpen })
        check(library.preview.text == first.text, "T-47 whole text remains selectable in shelf")
        key(53); await pause(0.05); check(!library.preview.isOpen && pet.clipboardPresented, "T-47 Escape closes only preview")
        library.hoveredID = secret.id; key(49, chars: " "); await pause()
        check(library.preview.text == "••••••" && !descendants(pet, NSTextView.self).contains { $0.string.contains("secret-feature-fixture") }, "T-47 masked secret preview has no plaintext")
        key(53); library.hoveredID = image.id; key(49, chars: " ")
        await wait("T-47 real Quick Look window", { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible && !library.preview.exportedURLs.isEmpty })
        let quickLookCapture = destination.appendingPathComponent("clipboard-quicklook-screen.png")
        let reference = NSBitmapImageRep(data: png)!
        let expectedPixel = reference.colorAt(x: reference.pixelsWide / 2, y: reference.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
        var imageVisible = false
        for _ in 0..<50 {
            await pause(0.1)
            do { try await clipboardCaptureWindow(QLPreviewPanel.shared()!, to: quickLookCapture) }
            catch { check(false, "T-47 actual Quick Look capture: \(error)") }
            if let bitmap = NSBitmapImageRep(data: try! Data(contentsOf: quickLookCapture)),
               let pixel = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB),
               abs(pixel.redComponent - expectedPixel.redComponent) < 0.12,
               abs(pixel.greenComponent - expectedPixel.greenComponent) < 0.12,
               abs(pixel.blueComponent - expectedPixel.blueComponent) < 0.12 { imageVisible = true; break }
        }
        check(imageVisible, "T-47 actual Quick Look compositor contains the fixture image")
        let exported = library.preview.exportedURLs
        check(exported.allSatisfy { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int) == 0o600 }, "T-47 Quick Look exports mode 0600")
        let preview = QLPreviewPanel.shared()!
        NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: preview.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!, atStart: true)
        await wait("T-47 Quick Look Escape cleanup", { !library.preview.isOpen })
        check(exported.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } && pet.clipboardPresented, "T-47 owned preview files removed and shelf retained")
        library.hoveredID = nil
        record("PASS T-47 text/secret and actual Quick Look; owned export cleanup")
        // T-48 uses the actual panel key route; second visible is the image fixture.
        panel.makeFirstResponder(pet)
        let visible = library.entries.filter { library.tabs.current.contains($0) }
        key(19, flags: .command, chars: "2"); await pause()
        check(board.data(forType: .png) == png && visible[1].id == image.id, "T-48 command-two copies the current second card")
        let flags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
        NSApp.postEvent(flags, atStart: false); await pause()
        check(card(image.id).shortcutNumber == 2, "T-48 command modifier displays current position badges")
        library.commandHeld = false; await pause()
        // T-49/50 actual rendering and workspace icon lookup.
        check(library.notice == "복사했어요" && pet.clipboardCopyFrame == nil, "T-49 copy feedback stays in shelf status line")
        var fileArtworkFinished = false, fileArtwork: NSImage?
        library.thumbnail(file) { value, _ in fileArtwork = value; fileArtworkFinished = true }
        await wait("T-49 file preview classification", { fileArtworkFinished })
        check(fileArtwork == nil && !card(file.id).displaysThumbnail && card(file.id).previewContent.string.contains("\u{fffc}"), "T-49 ordinary file uses inline document icon without large backdrop")
        check(card(image.id).displaysThumbnail, "T-49 actual image thumbnail remains visible")
        check(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") != nil && card(first.id).accessibilityLabel()?.contains("Safari") == true, "T-50 actual Safari icon lookup and accessible app name")
        check(card(second.id).accessibilityLabel()?.contains("Finder") == true, "T-50 Finder accessible name")
        check(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "fixture") == nil, "T-50 unknown source needs no icon")
        capture("clipboard-features-status-icons")
        record("PASS T-48 T-49 T-50 native key, status and actual app icons")
        // T-51 modifier presses select; Return merges text plus URLs, one undo restores all originals.
        for entry in [first, second, file] { await click(card(entry.id), flags: .command) }
        check(library.selectedIDs == Set([first.id, second.id, file.id]), "T-51 native command-click adds three cards")
        await click(card(first.id))
        check(library.selectedIDs.count == 3, "T-51 a normal press on a selected card preserves the group for dragging")
        check(board.string(forType: .string) == first.text, "T-48 T-51 ordinary card click still copies only that card")
        panel.makeFirstResponder(pet); key(36, chars: "\r"); await pause()
        let text = board.string(forType: .string) ?? ""
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        check(text.contains("alpha first") && text.contains("beta second") && text.contains("\n") && urls == [original], "T-51 mixed copy has merged text and original URL")
        var dragWriters: [NSPasteboardWriting]?
        library.writers([first, second, file], forDrag: true) { dragWriters = $0 }
        await wait("T-51 multi drag data prepared", { dragWriters != nil })
        check(dragWriters!.count == 3, "T-51 multi drag carries three separate items")
        let trash = descendants(pet, ClipboardTrashView.self).first!
        await click(trash); await wait("T-51 selected delete", { !library.entries.contains { [first.id, second.id, file.id].contains($0.id) } })
        key(6, flags: .command, chars: "z"); await wait("T-51 one key restores all", { [first, second, file].allSatisfy { e in library.entries.contains { $0.id == e.id } } })
        check((try? Data(contentsOf: original)) == Data("original".utf8), "T-51 original file never modified or deleted")
        await click(card(first.id), flags: .command); await click(card(file.id), flags: .shift)
        check(library.selectedIDs.count >= 3, "T-51 native shift-click selects range")
        key(53); check(library.selectedIDs.isEmpty && pet.clipboardPresented, "T-51 Escape clears selection before shelf")
        record("PASS T-51 native selection, merged copy, three drag writers, grouped delete/undo and original preservation")
        // T-52 stored order is serialized in the encrypted archive.
        for e in [first, second, file] { library.pin(e) }
        await wait("T-52 pins", { library.entries.filter(\.pinned).count == 3 })
        library.reorderPinned(first.id, before: file.id)
        await wait("T-52 order commit", { library.entries.first { $0.id == first.id }?.pinOrder == 1 && library.entries.first { $0.id == second.id }?.pinOrder == 0 })
        // Open a copy of the committed ciphertext, preserving the live store's trash and queue ownership.
        let copy = base.appendingPathComponent("pinned-restart-copy")
        try! FileManager.default.copyItem(at: library.store.root, to: copy)
        let reopened = try! ClipboardStore(root: copy, temporary: base.appendingPathComponent("pinned-copy-temp"), keychain: keychain).load()
        check(reopened.entries.filter(\.pinned).sorted { ($0.pinOrder ?? Int.max) < ($1.pinOrder ?? Int.max) }.map(\.id) == [second.id, first.id, file.id], "T-52 encrypted archive reload keeps exact pinned order")
        record("PASS T-52 encrypted copy restart exact order")
        // T-53 live input binding updates native attributed preview highlights.
        await query("alpha"); await pause()
        let highlighted = card(first.id).previewContent
        var highlightedRanges = 0
        highlighted.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, _, _ in if value != nil { highlightedRanges += 1 } }
        check(highlightedRanges > 0, "T-53 native preview highlights literal query")
        capture("clipboard-search-highlight")
        let ocrPicture = NSImage(size: CGSize(width: 900, height: 180))
        ocrPicture.lockFocus(); NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 900, height: 180).fill()
        ("MATCH ALPHA" as NSString).draw(at: CGPoint(x: 24, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black]); ocrPicture.unlockFocus()
        let ocrBytes = NSBitmapImageRep(data: ocrPicture.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        library.add(ClipboardInput(kind: .image, data: ocrBytes, dataType: "public.png", source: "fixture.ocr"))
        await wait("T-53 OCR image fixture", { library.entries.first?.source == "fixture.ocr" })
        let ocrID = library.entries[0].id
        await wait("T-53 actual Vision OCR", { library.entries.first { $0.id == ocrID }?.matchesRecognizedText("alpha") == true })
        await query("alpha")
        let ocrCard = card(ocrID)
        check(ocrCard.previewContent.string.replacingOccurrences(of: "\n", with: " ").contains("이미지 속 글자 일치"), "T-53 actual OCR result has in-preview match label")
        var disguised = image; disguised.source = "alpha"; disguised.recognizedText = nil
        check(!disguised.matchesRecognizedText("alpha"), "T-53 app-name match never masquerades as OCR match")
        let masked = ClipboardCardView(entry: secret, library: library, holding: { _ in }); masked.query = "alpha"
        var secretHighlights = 0
        masked.previewContent.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: masked.previewContent.length)) { value, _, _ in if value != nil { secretHighlights += 1 } }
        check(secretHighlights == 0, "T-53 secret preview has zero highlights")
        capture("clipboard-ocr-search-highlight")
        library.delete(library.entries.first { $0.id == ocrID }!)
        await wait("T-53 OCR fixture removed", { !library.entries.contains { $0.id == ocrID } })
        await query(""); panel.makeFirstResponder(pet)
        // T-54 Carbon registration is real; invoke the installed callback without posting a system paste.
        pet.dismissClipboard(); await pause()
        check(clipboardHotKey?.isRegistered == true && !library.hotKeyError, "T-54 Carbon registration succeeds without an event tap")
        pointer = CGPoint(x: -10000, y: -10000); clipboardHotKey?.activate?(); await pause(3.1)
        check(pet.clipboardPresented && panel.firstResponder is NSTextView, "T-54 shortcut opens focused search and remains open outside")
        clipboardHotKey?.activate?(); await pause(); check(!pet.clipboardPresented, "T-54 second shortcut closes")
        var settings = library.settings; settings.hotKeyEnabled = false; library.changeSettings(settings, persist: false); await pause()
        check(clipboardHotKey?.isRegistered == false, "T-54 disabled shortcut unregisters")
        settings.hotKeyEnabled = true; library.changeSettings(settings, persist: false); await pause(); await open()
        let registered = clipboardHotKey
        registered?.disable()
        clipboardHotKey = ClipboardHotKey(registration: { _, _, _ in OSStatus(eventHotKeyExistsErr) })
        library.onChange?(); await pause()
        check(library.hotKeyError, "T-54 injected Carbon conflict exposes settings guidance")
        clipboardHotKey = registered; library.onChange?(); await pause()
        record("PASS T-54 real registration, focus, outside hold, toggle, disable and API failure")
        // T-55 local transform creates an item and leaves the original intact.
        library.transform(first, using: .uppercase)
        await wait("T-55 transformed entry", { library.entries.first?.text == "ALPHA FIRST" })
        check(board.string(forType: .string) == "ALPHA FIRST" && library.entries.first?.source == "ddots" && library.entries.contains { $0.id == first.id && $0.text == "alpha first" }, "T-55 transformed copy and new item preserve source")
        let secretCard = card(secret.id), menuEvent = NSEvent()
        check(secretCard.menu(for: menuEvent)?.items.contains { $0.title == "글자 정리" } == false, "T-55 secret card has no transformations")
        // T-59 inspect real timer frames and the six-point content envelope.
        await query(""); panel.makeFirstResponder(pet)
        let hoverCard = card(first.id)
        hoverCard.mouseExited(with: NSEvent()); await pause(0.2)
        hoverCard.mouseEntered(with: NSEvent())
        var opacity: [CGFloat] = []
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.2 { opacity.append(hoverCard.hoverOpacity); await pause(0.012) }
        let reduced = CommandLine.arguments.contains("--ui-smoke-reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        check(reduced || opacity.contains { $0 > 0 && $0 < 1 }, "T-59 hover has intermediate opacity unless reduced motion")
        check(hoverCard.hoverOpacity == 1 && abs(hoverCard.previewRect.minX - 6) <= 1 && abs(hoverCard.bounds.maxY - hoverCard.previewRect.maxY - 6) <= 1 && abs(hoverCard.timeRect.minY - 6) <= 1, "T-59 hover highlight encloses content with six-point margins")
        hoverCard.mouseExited(with: NSEvent()); await pause(0.2); check(hoverCard.hoverOpacity == 0, "T-59 hover leave has no residue")
        if let viewport = descendants(pet, ClipboardGridView.self).first {
            let visible = viewport.convert(viewport.bounds, to: pet)
            for entry in library.entries.prefix(6) {
                let view = card(entry.id), time = card(entry.id).convert(card(entry.id).timeRect, to: pet)
                check(visible.insetBy(dx: -1, dy: -1).contains(time), "T-45 default two rows include every timestamp with status visible")
                check(view.bounds.height == 96, "T-45 default cards retain uniform height")
            }
        }
        record("T-59 hover samples=" + opacity.map { String(format: "%.3f", $0) }.joined(separator: ","))
        // T-60 real glass captures over both wallpaper extremes, with each appearance.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            for percent in [55.0, 65, 100] {
                library.opacityPercent = percent; await pause(0.3)
                let reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || CommandLine.arguments.contains("--ui-smoke-reduce-transparency")
                let expectedAlpha = reducedTransparency ? 1 : percent / 100
                check(abs(pet.clipboardTintAlpha - expectedAlpha) < 0.01, "T-60 real tint layer opacity applies immediately")
                record("T-60 percent=\(percent) layerAlpha=\(pet.clipboardTintAlpha) reduceTransparency=\(reducedTransparency)")
            }
            for wallpaper in [NSColor.white, NSColor.black] {
                let backdrop = NSWindow(contentRect: panel.frame.insetBy(dx: -10, dy: -10), styleMask: .borderless, backing: .buffered, defer: false)
                backdrop.backgroundColor = wallpaper; backdrop.level = panel.level; backdrop.order(.below, relativeTo: panel.windowNumber)
                library.opacityPercent = 65; await pause(0.2)
                let name = "clipboard-glass-\(appearance == .aqua ? "light" : "dark")-\(wallpaper == .white ? "white" : "black")"
                capture(name)
                do {
                    try await clipboardCaptureWindow(panel, backdrop: backdrop, to: destination.appendingPathComponent(name + "-screen.png"))
                    record("T-60 current-process compositor capture \(name) success")
                } catch { check(false, "T-60 own-window compositor capture: \(error)") }
                backdrop.orderOut(nil)
            }
        }
        panel.appearance = nil
        check(!library.settings.semanticSearch, "T-56 AI search defaults off; actual engine security/timeout evidence in unit log")
        if library.semantic.available {
            library.add(ClipboardInput(kind: .text, text: "서울시 강남구 합성로 10", source: "fixture"))
            await wait("T-56 address fixture", { library.entries.first?.text == "서울시 강남구 합성로 10" })
            let address = library.entries[0]
            library.editTabs { _ = try $0.add(name: "뜻 검색 시험", kind: .custom) }
            await wait("T-56 search fixture tab", { library.tabs.current.name == "뜻 검색 시험" })
            let tab = library.tabs.current.id
            library.membership(address.id, tab: tab, add: true); library.membership(second.id, tab: tab, add: true)
            await wait("T-56 fixture membership", { library.entries.filter { $0.memberships.contains(tab) }.count == 2 })
            var aiSettings = library.settings; aiSettings.semanticSearch = true; library.changeSettings(aiSettings, persist: false)
            await query("주소"); await pause(2.1)
            let matched = library.semantic.ids.contains(address.id)
            record("T-56 actual on-device UI semantic address match=\(matched); deadline preserves literal fallback")
            if matched { check(card(address.id).semanticMatch && !card(address.id).entry.secret, "T-56 actual AI card has marker and excludes secret"); capture("clipboard-ai-meaning-search") }
            else { check(!library.entries.contains { $0.id == address.id && $0.matches("주소") } && library.semantic.ids.isEmpty, "T-56 slow real model keeps literal-only fallback") }
            library.add(ClipboardInput(kind: .text, text: "뜻 검색 대역 메모", source: "fixture"))
            await wait("T-56 literal-first fixture", { library.entries.first?.text == "뜻 검색 대역 메모" })
            let literal = library.entries[0]
            library.membership(literal.id, tab: tab, add: true)
            await wait("T-56 literal membership", { library.entries.first { $0.id == literal.id }?.memberships.contains(tab) == true })
            await query("뜻 검색 대역"); await wait("T-56 injected result reaches rendered card", { library.semantic.ids.contains(address.id) })
            await pause(0.25)
            check(card(address.id).semanticMatch && !card(literal.id).semanticMatch, "T-56 AI marker applies only to semantic extra")
            let literalFrame = card(literal.id).convert(card(literal.id).bounds, to: pet), semanticFrame = card(address.id).convert(card(address.id).bounds, to: pet)
            check(literalFrame.minX < semanticFrame.minX, "T-56 literal result comes before semantic extra")
            capture("clipboard-ai-marker-injected")
            record("PASS T-56 injected-engine UI marker and literal-first order; actual model timing logged separately")
            aiSettings.semanticSearch = false; library.changeSettings(aiSettings, persist: false)
        }
        let unavailable = ClipboardLibrary(root: base.appendingPathComponent("unavailable-store"), temporary: base.appendingPathComponent("unavailable-exports"),
            keychain: keychain, board: board, settings: ClipboardSettings(), allowed: { false }, semantic: ClipboardSemanticSearch(available: false))
        let settingsHost = NSHostingView(rootView: ClipboardSettingsView(library: unavailable, persist: false))
        let settingsWindow = NSWindow(contentRect: CGRect(x: 200, y: 100, width: 620, height: 820), styleMask: .borderless, backing: .buffered, defer: false)
        settingsWindow.contentView = settingsHost; settingsWindow.orderFrontRegardless(); await pause(0.4)
        settingsHost.layoutSubtreeIfNeeded()
        let bitmap = settingsHost.bitmapImageRepForCachingDisplay(in: settingsHost.bounds)!
        settingsHost.cacheDisplay(in: settingsHost.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("clipboard-ai-unavailable-settings.png"))
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["ko-KR", "en-US"]
        try! VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        let visibleSettings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().replacingOccurrences(of: " ", with: "")
        check(visibleSettings.contains("이맥에서는쓸수없어요"), "T-56 actual unavailable settings displays guidance (Vision)")
        check(!descendants(settingsHost, NSButton.self).contains { $0.title == "AI 검색" }, "T-56 unavailable setting has no AI toggle")
        settingsWindow.orderOut(nil); unavailable.monitor.stop()
        let previous = try! JSONDecoder().decode(ClipboardSettings.self, from: Data("{\"enabled\":true,\"days\":1,\"count\":100}".utf8))
        check(!previous.fitsContents && !previous.semanticSearch && previous.hotKeyEnabled && previous.hotKeyCode == 9, "T-45 T-54 T-56 pre-v12 settings keep compatible defaults")
        check(pet.clipboardPresented, "feature testing leaves shelf interaction stable")
        record("PASS T-47 T-48 T-49 T-50 T-51 T-52 T-53 T-54 T-55 T-59 T-60; T-56 actual model in unit engine evidence")
        pet.dismissClipboard()
    }
}
