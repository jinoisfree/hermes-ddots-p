import AppKit
import SwiftUI

private enum ClipboardSmokeCleanup {
    static var keychains: [ClipboardKeychain] = []
    static func clear() { for key in keychains { try? key.delete() }; keychains = [] }
}

extension AppDelegate {
    @MainActor func verifyClipboard(destination: URL) async {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ddots-clipboard-smoke-" + UUID().uuidString)
        do { try fm.createDirectory(at: base, withIntermediateDirectories: true) }
        catch { smokeFailed("clipboard fixture directory") }
        SmokeLeftovers.note(base)
        let key = ClipboardKeychain(service: "ddots.clipboard.smoke." + UUID().uuidString)
        ClipboardSmokeCleanup.keychains.append(key)
        atexit { ClipboardSmokeCleanup.clear() }
        defer { ClipboardSmokeCleanup.clear() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let modelCalls = ClipboardSmokeModelCalls()
        let library = ClipboardLibrary(root: base.appendingPathComponent("clipboard"), temporary: base.appendingPathComponent("exports"), keychain: key, board: board,
                                       settings: ClipboardSettings(), allowed: { true }, semantic: ClipboardSemanticSearch(rank: { query, candidates in
                                           await modelCalls.record()
                                           if query == "뜻 검색 대역" { return candidates.indices.filter { candidates[$0].text == "서울시 강남구 합성로 10" } }
                                           return try await ClipboardSemanticSearch.rankOnDevice(query, candidates: candidates)
                                       }))
        connectClipboard(library)
        var outcomes: [String] = []
        if #available(macOS 15.4, *) {
            // Permission metadata only; the user's general pasteboard contents are never read.
            outcomes.append("METRIC general pasteboard access behavior \(NSPasteboard.general.accessBehavior.rawValue)")
        }
        func passed(_ id: String) { outcomes.append("PASS " + id) }
        func wait(_ name: String, attempts: Int = 500, diagnostic: () -> String = { "" }, _ condition: @escaping () -> Bool) async {
            for _ in 0..<attempts {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            smokeFailed(name + " " + diagnostic())
        }
        func settle() async { try? await Task.sleep(nanoseconds: 300_000_000); pet.layoutSubtreeIfNeeded() }
        func screenshot(_ name: String) {
            pet.layoutSubtreeIfNeeded(); pet.displayIfNeeded()
            guard let bitmap = pet.bitmapImageRepForCachingDisplay(in: pet.bounds) else { smokeFailed("clipboard bitmap") }
            pet.cacheDisplay(in: pet.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { smokeFailed("clipboard png") }
            do { try data.write(to: destination.appendingPathComponent(name + ".png")) }
            catch { smokeFailed("clipboard capture write") }
        }
        var pointer = NSPoint(x: -10000, y: -10000)
        pet.pointerLocation = { pointer }
        pet.bubbleAlwaysShown = false; pet.previewRow = nil; pet.previewLook = false
        pet.state = .idle; setBubbleActions([])
        await wait("T-20 initial store open", { library.ready })
        await settle()
        if CommandLine.arguments.contains("--ui-smoke-clipboard-direction-only") {
            await verifyClipboardDirection(library: library, destination: destination)
            library.monitor.stop(); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--ui-smoke-clipboard-enabled-only") {
            await verifyClipboardEnabled(library: library, board: board, destination: destination, modelCalls: modelCalls)
            library.monitor.stop(); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--ui-smoke-clipboard-chat-only") {
            await verifyClipboardChatVisibility(library: library, destination: destination)
            library.monitor.stop(); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--ui-smoke-clipboard-features-only") {
            let image = NSImage(size: CGSize(width: 160, height: 100)); image.lockFocus(); NSColor.systemBlue.setFill(); CGRect(x: 0, y: 0, width: 160, height: 100).fill(); image.unlockFocus()
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            await verifyClipboardFeatures(library: library, board: board, keychain: key, base: base, png: png, destination: destination, capture: screenshot)
            library.monitor.stop(); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--ui-smoke-clipboard-drawer-only") {
            await verifyClipboardDrawer(library: library, board: board, destination: destination, capture: screenshot)
            library.monitor.stop(); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--ui-smoke-clipboard-interactions-only") {
            await verifyClipboardInteractions(library: library, board: board, destination: destination, capture: screenshot)
            library.monitor.stop(); NSApp.terminate(nil); return
        }
        screenshot("clipboard-empty")
        // T-33: no automatic reader is allowed before explicit permission.
        var permissionReads = 0, captureReads = 0
        library.monitor.allowed = { false }; library.monitor.canRequestPermission = { true }
        library.monitor.permissionReader = { permissionReads += 1; _ = board.string(forType: .string) }
        library.monitor.reader = { _, _, _ in captureReads += 1; return nil }
        library.monitor.poll()
        let permissionHead = pet.atlas.interactionRect(in: pet.spriteRect)
        pointer = panel.convertPoint(toScreen: pet.convert(NSPoint(x: permissionHead.midX, y: permissionHead.midY), to: nil))
        pet.mouseEntered(with: NSEvent())
        await clipboardSmokeOpenDrawer(pet, panel: panel)
        await wait("T-33 empty library permission card", { self.pet.clipboardPresented && library.permissionNeeded && library.permissionRequestAvailable })
        await settle(); screenshot("clipboard-permission")
        smokeCheck(permissionReads == 0 && captureReads == 0 && library.entries.isEmpty, "T-33 no implicit permission read")
        library.requestPermission()
        smokeCheck(permissionReads == 1 && captureReads == 0 && library.entries.isEmpty, "T-33 explicit read discarded")
        library.monitor.canRequestPermission = { false }; library.monitor.poll()
        smokeCheck(!library.permissionRequestAvailable, "T-33 deny hides permission request")
        library.monitor.allowed = { true }; library.monitor.reader = ClipboardPasteboard.read; library.monitor.poll()
        smokeCheck(!library.permissionNeeded, "T-33 allowed poll dismisses permission card")
        library.notice = nil; pointer = NSPoint(x: -10000, y: -10000); clipboardSmokePointerMoved(pointer, panel: panel)
        await settle(); passed("T-33")
        board.clearContents(); board.setString("alpha", forType: .string); library.monitor.poll()
        await wait("T-01 collect text", { library.entries.count == 1 })
        smokeCheck(library.entries[0].kind == .text && library.entries[0].text == "alpha", "T-01 text value")
        passed("T-01")
        let first = base.appendingPathComponent("one.txt"), second = base.appendingPathComponent("two.txt")
        do { try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second) }
        catch { smokeFailed("clipboard file fixtures") }
        board.clearContents(); board.writeObjects([first as NSURL, second as NSURL]); library.monitor.poll()
        await wait("T-02 files", { library.entries.first?.files.count == 2 })
        let files = library.entries[0]
        smokeCheck((try? Data(contentsOf: first)) == Data("first".utf8) && (try? Data(contentsOf: second)) == Data("second".utf8), "T-02 originals unchanged")
        passed("T-02")
        let picture = NSImage(size: NSSize(width: 1000, height: 240))
        picture.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 240).fill()
        ("송장 1234\nINVOICE" as NSString).draw(at: NSPoint(x: 40, y: 35), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        picture.unlockFocus()
        let bitmap = NSBitmapImageRep(data: picture.tiffRepresentation!)!
        let png = bitmap.representation(using: .png, properties: [:])!
        board.clearContents(); board.setData(png, forType: .png); library.monitor.poll()
        await wait("T-03 image", { library.entries.first?.kind == .image })
        let image = library.entries[0]
        // The real macOS 27 engine compiles ANE models on first use (ocr-sample.txt).
        // The spec has no 10-second latency limit: allow bounded initialization, preserving both literal expectations.
        let ocrStart = ProcessInfo.processInfo.systemUptime
        await wait("T-30 real image recognition", attempts: 3000, diagnostic: { "engine=\(library.recognitionStatus[image.id] ?? "none") ready=\(library.ready) bytes=\(image.byteCount)" }, { library.entries.first { $0.id == image.id }?.matches("송장") == true && library.entries.first { $0.id == image.id }?.matches("invoice") == true })
        outcomes.append("METRIC Vision first image seconds \(ProcessInfo.processInfo.systemUptime - ocrStart)")
        passed("T-30")
        let movie = base.appendingPathComponent("movie.mp4")
        do { try Data(repeating: 0, count: 4096).write(to: movie) } catch { smokeFailed("video fixture") }
        board.clearContents(); board.writeObjects([movie as NSURL]); library.monitor.poll()
        await wait("T-03 video file", { library.entries.first?.files == [movie.path] })
        smokeCheck(library.entries[0].isMediaFile, "T-03 movie indicator")
        board.clearContents(); board.setData(Data(repeating: 0, count: 4096), forType: ClipboardPasteboard.video); library.monitor.poll()
        await wait("T-03 video bytes", { library.entries.first?.kind == .video })
        passed("T-03")
        board.clearContents(); board.setString("pw-123", forType: .string); board.setString("1", forType: ClipboardPasteboard.concealed); library.monitor.poll()
        await wait("T-04 secret", { library.entries.first?.secret == true })
        let secret = library.entries[0]
        smokeCheck(secret.kind == .text && secret.text == "pw-123", "T-04 concealed text payload preserved")
        let card = ClipboardCardView(entry: secret, library: library, holding: { _ in })
        smokeCheck(secret.preview == "••••••" && !secret.matches("pw-123") && !(card.accessibilityLabel() ?? "").contains("pw-123"), "T-04 display search accessibility masked")
        card.frame = NSRect(x: 0, y: 0, width: 100, height: ClipboardCardView.height(for: secret))
        smokeCheck(card.previewRect.width > card.previewRect.height && !card.previewContent.string.contains("비밀") && card.previewRect.minY - card.timeRect.maxY == 8, "User revision: uniform rectangular preview, no duplicate secret title, 8pt date gap")
        let mediaCard = ClipboardCardView(entry: image, library: library, holding: { _ in })
        mediaCard.frame = NSRect(x: 0, y: 0, width: 100, height: ClipboardCardView.height(for: image))
        smokeCheck(mediaCard.previewRect.size == card.previewRect.size && mediaCard.bounds.size == card.bounds.size && mediaCard.timeRect == card.timeRect && mediaCard.previewContent.string.contains("이미지") && mediaCard.previewRect.contains(mediaCard.contentRect), "User revision: identical card/preview/date geometry and media title inside preview")
        func opaquePixels(_ view: ClipboardCardView) -> Int {
            view.updateLayer()
            let bitmap = view.layer!.contents as! CGImage
            let bytes = CFDataGetBytePtr(bitmap.dataProvider!.data!)!
            return (0..<bitmap.height).reduce(0) { total, row in
                total + (0..<bitmap.width).filter { bytes[row * bitmap.bytesPerRow + $0 * 4 + 3] > 0 }.count
            }
        }
        card.entry.copiedAt = Date(timeIntervalSince1970: 1_000_000_000) // Stable date pixels across hover frames.
        let idlePixels = opaquePixels(card)
        smokeCheck(idlePixels > 0, "User revision: preview rectangle remains visible")
        card.mouseEntered(with: NSEvent()); await settle(); smokeCheck(opaquePixels(card) > idlePixels, "User revision: hover adds outer card block")
        card.mouseExited(with: NSEvent()); await settle(); smokeCheck(opaquePixels(card) == idlePixels, "User revision: leaving hover removes only outer block without residue")
        smokeCheck(card.subviews.compactMap { $0 as? NSButton }.isEmpty, "User revision: no eye button")
        let secretClick = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 70), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        card.mouseDown(with: secretClick); card.mouseUp(with: secretClick)
        smokeCheck(card.revealsSecret, "User revision: click reveals secret")
        card.mouseDown(with: secretClick); card.mouseUp(with: secretClick)
        smokeCheck(!card.revealsSecret, "User revision: second click conceals")
        _ = card.accessibilityPerformPress(); smokeCheck(card.revealsSecret, "User revision: accessible press reveals")
        library.shelfPresentation(false); smokeCheck(!card.revealsSecret, "User revision: closing shelf conceals")
        passed("T-04 plus user click reveal revision")
        // All reads and writes below use a named pasteboard, preserving the user's actual clipboard.
        library.copy(files)
        await wait("T-09 all file URLs", { (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.count == 2 })
        let count = library.entries.count; library.monitor.poll(); await settle()
        smokeCheck(library.entries.count == count, "T-09 ignores own write")
        smokeCheck(library.entries.first { $0.id == files.id }?.secret == false, "T-09 file copy retains its non-secret classification")
        let rich = ClipboardInput(kind: .text, text: "rich", rtf: Data("{\\rtf1 rich}".utf8), source: "fixture")
        library.add(rich); await wait("T-09 rich stored", { library.entries.first?.text == "rich" })
        let richEntry = library.entries[0]
        library.copy(richEntry)
        await wait("T-09 rich copy", { board.data(forType: .rtf) != nil })
        smokeCheck(board.string(forType: .string) == "rich", "T-09 string plus rtf")
        library.copy(richEntry, plain: true)
        // NSPasteboard.types adds NSStringPboardType as a system alias. Inspect what our writer actually declared.
        await wait("T-10 plain copy", { board.pasteboardItems?.first?.types == [.string] && board.data(forType: .rtf) == nil })
        passed("T-09"); passed("T-10")
        for entry in [richEntry, files, image] {
            var writers: [NSPasteboardWriting]?
            library.writers(entry, forDrag: true) { writers = $0 }
            await wait("T-11 native drag writers", { writers != nil })
            let dragBoard = NSPasteboard.withUniqueName()
            dragBoard.clearContents(); dragBoard.writeObjects(writers!)
            if entry.kind == .text { smokeCheck(dragBoard.string(forType: .string) == "rich", "T-11 text payload") }
            else { smokeCheck(dragBoard.availableType(from: [.fileURL]) != nil, "T-11 file payload") }
            dragBoard.releaseGlobally()
        }
        passed("T-11 data generation only; physical drag remains unverified")
        let drop = ClipboardDrop(library: library)
        board.clearContents(); board.setString("dropped text", forType: .string)
        smokeCheck(drop.receive(board), "T-12 text drop")
        await wait("T-12 drop collected", { library.entries.first?.text == "dropped text" })
        board.clearContents(); board.writeObjects([first as NSURL]); smokeCheck(drop.receive(board), "T-12 file drop")
        await wait("T-12 file drop stored", { library.entries.first?.files == [first.path] })
        board.clearContents(); board.setData(png, forType: .png); smokeCheck(drop.receive(board), "T-12 image drop")
        passed("T-12 folded destination payloads")
        do { try fm.removeItem(at: second) } catch { smokeFailed("T-13 fixture remove") }
        library.copy(files)
        await wait("T-13 remaining original", { (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(\.path) == [first.path] })
        do { try fm.removeItem(at: first) } catch { smokeFailed("T-13 fixture remove remaining") }
        let unchanged = board.changeCount
        library.copy(files)
        await wait("T-13 missing original notice", { library.notice == "원본 없음" })
        smokeCheck(board.changeCount == unchanged, "T-13 all missing keeps clipboard")
        passed("T-13")
        let head = pet.atlas.interactionRect(in: pet.spriteRect)
        pointer = panel.convertPoint(toScreen: pet.convert(NSPoint(x: head.midX, y: head.midY), to: nil))
        pet.mouseEntered(with: NSEvent())
        await clipboardSmokeOpenDrawer(pet, panel: panel)
        await wait("T-17 hover opens grid", { self.pet.clipboardPresented })
        smokeCheck(!panel.isKeyWindow, "T-32 hovering shelf preserves other window focus")
        await settle(); screenshot("clipboard-grid")
        if let live = cards(pet).first {
            live.mouseEntered(with: NSEvent()); await settle(); screenshot("clipboard-hover")
            live.mouseExited(with: NSEvent()); await settle()
        }
        let bubble = pet.placement!.bubbleRect
        pointer = panel.convertPoint(toScreen: pet.convert(NSPoint(x: bubble.midX, y: bubble.midY), to: nil))
        await settle(); smokeCheck(pet.clipboardPresented, "T-17 pointer crosses into grid")
        screenshot("clipboard-secret")
        let approvalHead = pet.atlas.interactionRect(in: pet.spriteRect)
        pointer = panel.convertPoint(toScreen: pet.convert(NSPoint(x: approvalHead.midX, y: approvalHead.midY), to: nil))
        pet.dismissClipboard(); pet.state = .waiting; await settle()
        smokeCheck(!pet.clipboardPresented && !pet.clipboardRowVisible, "T-17 folded approval bubble takes priority; REQ-CB-38")
        pet.state = .idle; await settle(); await clipboardSmokeOpenDrawer(pet, panel: panel)
        await wait("T-17 shelf returns after approval through its row", { self.pet.clipboardPresented })
        pet.dismissClipboard(); pet.revealBubble(); await settle()
        smokeCheck(!pet.clipboardPresented && !pet.clipboardRowVisible, "T-17 folded notification takes priority; REQ-CB-38")
        await wait("T-17 notification expires", { !self.pet.clipboardAttention })
        await clipboardSmokeOpenDrawer(pet, panel: panel)
        // Exercise the native field editor's marked text without rewriting the search binding.
        func searchField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, (field.placeholderString ?? field.placeholderAttributedString?.string) == ClipboardSearch.placeholder { return field }
            for child in view.subviews { if let found = searchField(child) { return found } }
            return nil
        }
        if let field = searchField(pet) {
            panel.makeKey(); panel.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.setMarkedText("알", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                smokeCheck(editor.hasMarkedText(), "T-16 Korean marked composition retained")
                editor.insertText("알파", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                smokeCheck(editor.string == "알파" && !editor.hasMarkedText(), "T-16 Korean composition commits")
                editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            } else { smokeFailed("T-16 native search field editor") }
        } else { smokeFailed("T-16 native search field") }
        passed("T-16")
        library.editTabs { $0.selected = $0.items.first { $0.kind == .secrets }!.id }
        await settle(); screenshot("clipboard-secret")
        library.editTabs { $0.selected = $0.items[0].id }; await settle()
        for (appearance, name) in [(NSAppearance.Name.aqua, "clipboard-light"), (.darkAqua, "clipboard-dark"), (.accessibilityHighContrastAqua, "clipboard-contrast")] {
            panel.appearance = NSAppearance(named: appearance); await settle(); screenshot(name)
        }
        func cardsForKeyboard(_ view: NSView) -> String {
            if let card = view as? ClipboardCardView, card.selected { return card.entry.kind.rawValue }
            return view.subviews.map(cardsForKeyboard).filter { !$0.isEmpty }.joined(separator: ",")
        }
        // Keyboard dispatch goes through the live PetPanel, not an isolated model action.
        func keyEvent(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        panel.appearance = NSAppearance(named: .aqua)
        library.add(ClipboardInput(kind: .text, text: "keyboard first", source: "fixture"))
        await wait("T-32 first keyboard fixture", { library.entries.first?.text == "keyboard first" })
        library.add(ClipboardInput(kind: .text, text: "keyboard second", source: "fixture"))
        await wait("T-32 second keyboard fixture", { library.entries.first?.text == "keyboard second" })
        await settle()
        smokeCheck(panel.performKeyEquivalent(with: keyEvent(3, "f", .command)), "T-32 Command-F handled")
        smokeCheck(panel.firstResponder is NSTextView, "T-32 Command-F focuses native search")
        let searchPointer = pointer; pointer = NSPoint(x: -10000, y: -10000); await settle()
        smokeCheck(pet.clipboardPresented && panel.isKeyWindow, "T-32 focused search survives pointer leaving")
        pointer = searchPointer
        panel.sendEvent(keyEvent(48, "\t")); await settle()
        panel.sendEvent(keyEvent(124, "")); await settle()
        let beforeReturn = board.changeCount
        panel.sendEvent(keyEvent(36, "\r"))
        await wait("T-32 Return copies selected card", diagnostic: { "notice=\(library.notice == nil ? "none" : "present") selectedKinds=\(cardsForKeyboard(self.pet))" }, { board.changeCount > beforeReturn && board.string(forType: .string) == "keyboard first" })
        panel.sendEvent(keyEvent(48, "\t")); await settle()
        let tabBeforeArrow = library.tabs.current.id
        panel.sendEvent(keyEvent(124, ""))
        await wait("T-32 arrow changes focused tab", { library.tabs.current.id != tabBeforeArrow })
        panel.sendEvent(keyEvent(48, "\t")); await settle()
        smokeCheck(panel.firstResponder is NSTextView, "T-32 Tab returns to search")
        library.editTabs { $0.selected = $0.items[0].id }; await settle()
        func cards(_ root: NSView) -> [ClipboardCardView] { (root as? ClipboardCardView).map { [$0] } ?? root.subviews.flatMap(cards) }
        smokeCheck(!cards(pet).isEmpty && cards(pet).allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty && !($0.accessibilityLabel() ?? "").contains("pw-123") }, "T-32 card accessibility names hide secret text")
        smokeCheck(cards(pet).filter { $0.entry.secret && $0.entry.kind == .text }.allSatisfy { $0.auxiliaryText != "원본 없음" }, "V-6 secret text has date, never missing-original label")
        panel.sendEvent(keyEvent(53, "\u{1b}")); await settle()
        smokeCheck(!pet.clipboardPresented, "T-32 Escape closes shelf until pointer leaves")
        passed("T-32 keyboard, accessibility, three appearance captures")
        pointer = NSPoint(x: -10000, y: -10000); clipboardSmokePointerMoved(pointer, panel: panel)
        await wait("T-17 pointer outside closes shelf", { !self.pet.clipboardPresented })
        passed("T-17 synthetic hover and captures")
        await verifyClipboardAlignment(library: library, base: base, destination: destination, samples: [library.entries.first { $0.kind == .text && !$0.secret }!, secret, image, library.entries.first { $0.kind == .video }!, files], capture: screenshot)
        passed("T-37 shared top-leading content frame and reduced row spacing")
        library.paused = true; smokeCheck(!library.monitor.polling, "T-18 pause stops timer")
        smokeCheck(!drop.accepts(board), "T-18 pause disables drop collection")
        board.clearContents(); board.setString("while paused", forType: .string); library.monitor.poll()
        await settle(); smokeCheck(!library.entries.contains { $0.text == "while paused" }, "T-18 paused contents absent")
        library.paused = false; library.monitor.poll()
        await settle(); smokeCheck(!library.entries.contains { $0.text == "while paused" }, "T-18 resume captures only later changes")
        var settings = library.settings; settings.enabled = false; library.changeSettings(settings, persist: false)
        smokeCheck(!library.monitor.polling, "T-18 disabled timer stopped")
        settings.enabled = true; settings.ocr = false; library.changeSettings(settings, persist: false)
        let unrecognized = ClipboardInput(kind: .image, data: png + Data([0]), dataType: "public.png", source: "fixture")
        library.add(unrecognized)
        await wait("T-30 OCR disabled new image", { library.entries.first?.digest == unrecognized.digest })
        let disabledImage = library.entries[0]
        await settle()
        smokeCheck(disabledImage.recognizedText == nil && library.recognitionStatus[disabledImage.id] == nil, "T-30 recognition disabled")
        passed("T-18")
        var reads = 0
        library.monitor.reader = { _, _, _ in reads += 1; return nil }
        library.monitor.allowed = { false }
        board.clearContents(); board.setString("denied", forType: .string); library.monitor.poll()
        smokeCheck(reads == 0 && library.permissionNeeded, "T-19 no content read without permission")
        library.monitor.allowed = { true }; library.monitor.reader = ClipboardPasteboard.read
        passed("T-19")
        library.editTabs { _ = try $0.add(name: "모아두기", kind: .custom) }
        await wait("T-26 custom tab added", { library.tabs.items.count == 5 })
        let custom = library.tabs.items.last!.id
        library.membership(secret.id, tab: custom, add: true); library.membership(image.id, tab: custom, add: true)
        await wait("T-27 two memberships", { library.entries.filter { $0.memberships.contains(custom) }.count == 2 })
        library.membership(secret.id, tab: custom, add: false)
        await wait("T-27 membership removal", { library.entries.filter { $0.memberships.contains(custom) }.count == 1 })
        passed("T-26"); passed("T-27")
        let currentHead = pet.atlas.interactionRect(in: pet.spriteRect)
        pointer = panel.convertPoint(toScreen: pet.convert(NSPoint(x: currentHead.midX, y: currentHead.midY), to: nil))
        await clipboardSmokeOpenDrawer(pet, panel: panel)
        await wait("T-24 tab screenshot opens shelf", { self.pet.clipboardPresented })
        await settle(); screenshot("clipboard-tabs")
        library.editTabs { _ = try $0.add(name: "문서", kind: .files); _ = try $0.add(name: "즐겨찾기", kind: .custom); $0.selected = $0.items[0].id }
        await wait("T-31 seven tabs", { library.tabs.items.count == 7 })
        await settle(); screenshot("clipboard-seven-tabs")
        // T-36 uses the live native destination and owned entry drag format, without opening a clear alert.
        func trashButton(_ root: NSView) -> ClipboardTrashView? {
            (root as? ClipboardTrashView) ?? root.subviews.lazy.compactMap(trashButton).first
        }
        guard let trash = trashButton(pet), let field = searchField(pet) else { smokeFailed("T-36 native controls present") }
        let trashFrame = trash.convert(trash.bounds, to: pet), searchFrame = field.convert(field.bounds, to: pet)
        smokeCheck(trashFrame.width >= 28 && trashFrame.height >= 28 && trashFrame.minX > searchFrame.maxX + 8, "T-36 clear is a separate 28pt destination outside search: trash=\(trashFrame), search=\(searchFrame)")
        let trashOriginal = base.appendingPathComponent("trash-original.txt")
        do { try Data("original".utf8).write(to: trashOriginal) } catch { smokeFailed("T-36 original fixture") }
        library.add(ClipboardInput(kind: .files, files: [trashOriginal.path], source: "fixture"))
        await wait("T-36 original reference", { library.entries.first?.files == [trashOriginal.path] })
        library.pin(secret)
        await wait("T-36 protected peer", { library.entries.first { $0.id == secret.id }?.pinned == true })
        let retainedIDs = Set(library.entries.map(\.id)), fileEntry = library.entries[0]
        let trashBoard = NSPasteboard.withUniqueName()
        defer { trashBoard.releaseGlobally() }
        trashBoard.setString(fileEntry.id.uuidString, forType: .init("app.ddots.clipboard-entry"))
        smokeCheck(trash.targetDrop(trashBoard) == .copy && trash.targeted, "T-36 internal entry target highlight")
        await settle(); screenshot("clipboard-trash-target")
        _ = trash.targetDrop(nil)
        smokeCheck(!trash.targeted && Set(library.entries.map(\.id)) == retainedIDs, "T-36 leaving destination does not delete")
        smokeCheck(trash.receive(trashBoard) && NSApp.modalWindow == nil, "T-36 native destination accepts one entry without alert")
        await wait("T-36 exactly one removed", { Set(library.entries.map(\.id)) == retainedIDs.subtracting([fileEntry.id]) && library.canUndo })
        smokeCheck(fm.fileExists(atPath: trashOriginal.path) && library.entries.first { $0.id == secret.id }?.pinned == true, "T-36 original file and pinned peer remain")
        library.undoDelete()
        await wait("T-36 undo restores single entry", { Set(library.entries.map(\.id)) == retainedIDs })
        trashBoard.clearContents(); trashBoard.setString("external", forType: .string)
        smokeCheck(trash.targetDrop(trashBoard).isEmpty && !trash.receive(trashBoard), "T-36 external payload rejected")
        library.pin(secret)
        await wait("T-36 reset protected peer", { library.entries.first { $0.id == secret.id }?.pinned == false })
        passed("T-36 separate clear, highlight, single delete, undo and originals")
        let clearAlert = library.makeClearAlert()
        smokeCheck(clearAlert.buttons.map(\.title) == ["비우기", "취소"] && clearAlert.buttons[1].keyEquivalent == "\u{1b}", "T-31 native clear verbs and Escape")
        let beforeCancel = library.entries
        var escapedAlert = false
        let escapeTimer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if let window = NSApp.modalWindow { escapedAlert = window.performKeyEquivalent(with: keyEvent(53, "\u{1b}")) }
            }
        }
        let timeoutTimer = Timer(timeInterval: 2, repeats: false) { _ in if NSApp.modalWindow != nil { NSApp.abortModal() } }
        RunLoop.main.add(escapeTimer, forMode: .modalPanel); RunLoop.main.add(timeoutTimer, forMode: .modalPanel)
        library.confirmClear()
        escapeTimer.invalidate(); timeoutTimer.invalidate()
        smokeCheck(escapedAlert && library.entries == beforeCancel, "T-31 Escape cancels native clear without deletion")
        let sampleMenu = card.menu(for: NSEvent())!
        smokeCheck(sampleMenu.items.last?.title == "삭제" && sampleMenu.items[sampleMenu.items.count - 2].isSeparatorItem, "T-31 delete follows separator at end")
        passed("T-31 top search, native alert, seven tabs and delete menu")
        // T-34 exercises the serial disk owner, live key route, expiry clock and lifecycle cleanup.
        let undoBytes = Data("secret-undo-data".utf8)
        library.add(ClipboardInput(kind: .image, data: undoBytes, dataType: "public.png", source: "fixture", secret: true))
        await wait("T-34 secret data captured", { library.entries.first?.dataID != nil && library.entries.first?.secret == true })
        let undoEntry = library.entries[0]
        library.pin(undoEntry); library.membership(undoEntry.id, tab: custom, add: true)
        await wait("T-34 pin and membership", { library.entries.first?.pinned == true && library.entries.first?.memberships.contains(custom) == true })
        let undoSnapshot = library.entries
        library.delete(undoEntry)
        await wait("T-34 deletion without alert", { !library.entries.contains { $0.id == undoEntry.id } && library.canUndo })
        let trashFile = library.store.trash.appendingPathComponent(undoEntry.dataID!.uuidString + ".aes")
        smokeCheck((try? Data(contentsOf: trashFile).range(of: undoBytes)) == nil && fm.fileExists(atPath: trashFile.path), "T-34 trash ciphertext contains no raw secret data")
        await settle()
        smokeCheck(panel.performKeyEquivalent(with: keyEvent(6, "z", .command)), "T-34 Command-Z handled")
        await wait("T-34 metadata and ordering restored", { library.entries == undoSnapshot })
        smokeCheck(!fm.fileExists(atPath: trashFile.path), "T-34 restored blob leaves trash")
        var testNow = Date()
        library.clock = { testNow }
        library.delete(undoEntry); await wait("T-34 clock delete", { library.canUndo })
        library.shelfPresentation(false); await settle()
        testNow = testNow.addingTimeInterval(31); library.expireUndo()
        await wait("T-34 deadline purges undo", { !library.canUndo && !fm.fileExists(atPath: library.store.trash.path) })
        library.undoDelete(); await settle()
        smokeCheck(!library.entries.contains { $0.id == undoEntry.id }, "T-34 expired deletion cannot undo")
        library.clock = Date.init
        for lifecycle in ["clear", "disable", "lock"] {
            library.add(ClipboardInput(kind: .image, data: undoBytes, dataType: "public.png", source: "fixture", secret: true))
            await wait("T-34 lifecycle fixture", { library.entries.first?.kind == .image && library.entries.first?.secret == true })
            let current = library.entries[0]
            library.delete(current); await wait("T-34 lifecycle delete", { library.canUndo })
            switch lifecycle {
            case "clear": library.clearTab(custom)
            case "disable": var value = library.settings; value.enabled = false; library.changeSettings(value, persist: false)
            default: DistributedNotificationCenter.default().postNotificationName(.init("com.apple.screenIsLocked"), object: nil, userInfo: nil, deliverImmediately: true)
            }
            await wait("T-34 lifecycle purges undo", { !library.canUndo && !fm.fileExists(atPath: library.store.trash.path) })
            var value = library.settings; value.enabled = true; library.changeSettings(value, persist: false)
            DistributedNotificationCenter.default().postNotificationName(.init("com.apple.screenIsUnlocked"), object: nil, userInfo: nil, deliverImmediately: true)
        }
        passed("T-34 encrypted trash, Command-Z, deadline, clear, disable and lock")
        pointer = NSPoint(x: -10000, y: -10000); clipboardSmokePointerMoved(pointer, panel: panel)
        // Ensure all mutations have reached disk before opening the same archive with another owner.
        let restartBoard = NSPasteboard.withUniqueName()
        defer { restartBoard.releaseGlobally() }
        let restarter = ClipboardLibrary(root: base.appendingPathComponent("clipboard"), temporary: base.appendingPathComponent("restart-exports"), keychain: key, board: restartBoard, settings: settings, allowed: { true })
        await wait("T-20 restart", { restarter.ready })
        smokeCheck(restarter.entries == library.entries && restarter.tabs.items == library.tabs.items, "T-20 persistence snapshot")
        restarter.monitor.stop()
        let exitKey = ClipboardKeychain(service: "ddots.clipboard.smoke.exit." + UUID().uuidString)
        ClipboardSmokeCleanup.keychains.append(exitKey)
        let exitLibrary = ClipboardLibrary(root: base.appendingPathComponent("exit-clipboard"), temporary: base.appendingPathComponent("exit-exports"), keychain: exitKey, board: restartBoard, settings: settings, allowed: { true })
        await wait("T-34 exit store ready", { exitLibrary.ready })
        exitLibrary.add(ClipboardInput(kind: .image, data: undoBytes, dataType: "public.png", source: "fixture", secret: true))
        await wait("T-34 exit data ready", { !exitLibrary.entries.isEmpty })
        exitLibrary.delete(exitLibrary.entries[0]); await wait("T-34 exit fixture deleted", { exitLibrary.canUndo })
        var closed = false
        let run = ClosingRun(limit: 3) { late in smokeCheck(!late, "T-34 bounded close finishes"); closed = true }
        exitLibrary.prepareClose(run); run.start()
        await wait("T-34 app close purges trash", { closed && !exitLibrary.canUndo && !fm.fileExists(atPath: exitLibrary.store.trash.path) })
        passed("T-34 ClosingRun exit cleanup")
        passed("T-20")
        let quotaKey = ClipboardKeychain(service: "ddots.clipboard.smoke." + UUID().uuidString)
        ClipboardSmokeCleanup.keychains.append(quotaKey)
        let quotaBoard = NSPasteboard.withUniqueName()
        defer { quotaBoard.releaseGlobally() }
        let quota = ClipboardLibrary(root: base.appendingPathComponent("quota"), temporary: base.appendingPathComponent("quota-exports"), keychain: quotaKey, board: quotaBoard, settings: ClipboardSettings(), allowed: { true }, byteLimit: 8)
        await wait("T-34 quota store ready", { quota.ready })
        quota.add(ClipboardInput(kind: .image, data: Data([1, 2, 3, 4]), source: "fixture", secret: true))
        await wait("T-34 quota blob ready", { quota.entries.count == 1 })
        let quotaEntry = quota.entries[0]
        quota.pin(quotaEntry); await wait("T-34 quota pin", { quota.entries[0].pinned })
        quota.delete(quota.entries[0]); await wait("T-34 quota deletion", { quota.entries.isEmpty && quota.canUndo })
        quota.add(ClipboardInput(kind: .text, text: "1234", source: "fixture"))
        await wait("T-34 reserved plus active fits", { quota.entries.first?.text == "1234" })
        quota.add(ClipboardInput(kind: .text, text: "12345", source: "fixture"))
        await wait("T-34 quota rejects oversized addition", { quota.notice == "보관할 수 있는 용량을 넘었어요" })
        smokeCheck(quota.entries.count == 1 && quota.entries[0].text == "1234" && quota.canUndo, "T-34 rejection preserves active data and undo")
        quota.undoDelete()
        await wait("T-34 reserved quota restored", { quota.entries.count == 2 && quota.entries.reduce(0) { $0 + $1.byteCount } == 8 })
        smokeCheck((try? quota.store.data(quotaEntry.dataID!)) == Data([1, 2, 3, 4]), "T-34 quota restore retains exact encrypted blob")
        quota.paused = true
        passed("T-34 total capacity includes undo data")
        library.pin(secret)
        await wait("T-14 pin", { library.entries.first { $0.id == secret.id }?.pinned == true })
        let retainedOriginal = base.appendingPathComponent("retain-original.txt")
        do { try Data("original".utf8).write(to: retainedOriginal) } catch { smokeFailed("T-14 original fixture") }
        library.add(ClipboardInput(kind: .files, files: [retainedOriginal.path], source: "fixture"))
        await wait("T-14 original reference stored", { library.entries.first?.files == [retainedOriginal.path] })
        let systemCount = board.changeCount
        library.clear(includingPins: false)
        await wait("T-14 clear preserves pin", { library.entries.count == 1 && library.entries[0].pinned })
        smokeCheck(fm.fileExists(atPath: retainedOriginal.path) && board.changeCount == systemCount, "T-14 original and clipboard preserved")
        library.clear(includingPins: true)
        await wait("T-14 clear all", { library.entries.isEmpty })
        smokeCheck((try? fm.contentsOfDirectory(atPath: library.store.root.path).filter { $0 != "index.aes" }.isEmpty) == true, "T-14 owned data removed")
        passed("T-14")
        await verifyClipboardCopyFeedback(library: library, board: board, base: base, png: png, destination: destination, capture: screenshot)
        passed("T-38 names, timing, animation, exclusions and secret masking")
        await verifyClipboardInteractions(library: library, board: board, destination: destination, capture: screenshot)
        passed("T-39 T-40 T-41 T-42 T-43 T-44 native interaction regression")
        await verifyClipboardDrawer(library: library, board: board, destination: destination, capture: screenshot)
        await verifyClipboardFeatures(library: library, board: board, keychain: key, base: base, png: png, destination: destination, capture: screenshot)
        await verifyClipboardChatVisibility(library: library, destination: destination)
        passed("T-63 actual title/composer pixels and 1.6.110 frames")
        await verifyClipboardDirection(library: library, destination: destination)
        passed("T-65 actual mirrored drawer and pointer crossing")
        await verifyClipboardEnabled(library: library, board: board, destination: destination, modelCalls: modelCalls)
        passed("T-64 complete feature switch and retained entries")
        passed("T-45 T-46 T-47 T-48 T-49 T-50 T-51 T-52 T-53 T-54 T-55 T-56 T-59 T-60 T-61 T-62 integrated")
        showChat()
        smokeCheck(pet.registeredDraggedTypes.isEmpty, "T-12 expanded conversation leaves drop registration to existing Slack attachment views")
        collapseChat()
        smokeCheck(!pet.registeredDraggedTypes.isEmpty, "T-12 folded pet restores shelf drop registration")
        // The report contains case identifiers only, never captured values or OCR output.
        for name in ["stall-log.txt"] {
            if let log = try? String(contentsOf: destination.appendingPathComponent(name)) {
                smokeCheck(!log.contains("alpha") && !log.contains("pw-123"), "T-06 no content in diagnostics")
            }
        }
        passed("T-06")
        do { try (outcomes.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("clipboard-checks.txt"), atomically: true, encoding: .utf8) }
        catch { smokeFailed("clipboard report write") }
        library.monitor.stop()
        NSApp.terminate(nil)
    }
}
