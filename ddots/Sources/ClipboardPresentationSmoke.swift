import SwiftUI
import AppKit

@MainActor private func clipboardUIWait(_ name: String, _ condition: () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    smokeFailed(name)
}

extension AppDelegate {
    @MainActor func verifyClipboardAlignment(library: ClipboardLibrary, base: URL, destination: URL,
                                             samples: [ClipboardEntry], capture: (String) -> Void) async {
        let originalTabs = library.tabs, originalPointer = pet.pointerLocation
        var pointer = NSPoint(x: -10000, y: -10000)
        pet.pointerLocation = { pointer }
        let file = base.appendingPathComponent("alignment.txt")
        do { try Data("fixture".utf8).write(to: file) } catch { smokeFailed("T-37 file fixture") }
        library.add(ClipboardInput(kind: .files, files: [file.path], source: "fixture"))
        await clipboardUIWait("T-37 file recorded", { library.entries.first?.files == [file.path] })
        let entries = samples + [library.entries[0]], ids = Set(entries.map(\.id))
        library.editTabs { _ = try $0.add(name: "정렬 확인", kind: .custom); $0.selected = $0.items.last!.id }
        await clipboardUIWait("T-37 alignment tab", { library.tabs.current.name == "정렬 확인" })
        let tab = library.tabs.current.id
        for entry in entries { library.membership(entry.id, tab: tab, add: true) }
        await clipboardUIWait("T-37 six kinds in one tab", { library.entries.filter { $0.memberships.contains(tab) }.count == 6 })
        let head = pet.atlas.interactionRect(in: pet.spriteRect)
        pointer = panel.convertPoint(toScreen: pet.convert(NSPoint(x: head.midX, y: head.midY), to: nil))
        pet.mouseEntered(with: NSEvent())
        await clipboardSmokeOpenDrawer(pet, panel: panel)
        await clipboardUIWait("T-37 alignment shelf opens", { pet.clipboardPresented })
        try? await Task.sleep(nanoseconds: 500_000_000)
        pet.layoutSubtreeIfNeeded()
        func cards(_ root: NSView) -> [ClipboardCardView] {
            if let card = root as? ClipboardCardView { return [card] }
            return root.subviews.flatMap(cards)
        }
        let live = cards(pet).filter { ids.contains($0.entry.id) && !$0.isHiddenOrHasHiddenAncestor }
        smokeCheck(live.count == 6 && Set(live.map { $0.entry.id }) == ids, "T-37 six live cards")
        var lines: [String] = []
        for card in live {
            let content = card.contentRect, preview = card.previewRect
            smokeCheck(abs(content.minX - preview.minX - 8) <= 1 && abs(preview.maxY - content.maxY - 8) <= 1, "T-37 all text starts at eight-point top-leading inset")
            smokeCheck(abs(card.timeRect.midX - card.bounds.midX) <= 1 && abs(card.timeRect.minY - 6) <= 1, "T-37 centred date with compact bottom space")
            card.previewContent.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: card.previewContent.length)) { value, _, _ in
                smokeCheck((value as? NSParagraphStyle)?.alignment == .left, "T-37 no centred preview text")
            }
            lines.append("kind=\(card.entry.kind.rawValue) concealed=\(card.entry.secret) content=\(content) preview=\(preview) time=\(card.timeRect) view=\(card.convert(card.bounds, to: pet))")
        }
        let rows = Set(live.map { Int($0.convert($0.bounds, to: pet).midY.rounded()) }).sorted()
        smokeCheck(rows.count == 2 && abs(rows[1] - rows[0] - 104) <= 1, "V-9 card row pitch reduced to 104pt with hover block retained")
        for (appearance, name) in [(NSAppearance.Name.aqua, "clipboard-alignment-light"), (.darkAqua, "clipboard-alignment-dark")] {
            panel.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(nanoseconds: 250_000_000); capture(name)
        }
        do { try (lines.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("clipboard-alignment.txt"), atomically: true, encoding: .utf8) }
        catch { smokeFailed("T-37 numeric frame report") }
        library.editTabs { $0 = originalTabs }
        await clipboardUIWait("T-37 original tabs restored", { library.tabs.items == originalTabs.items })
        pointer = NSPoint(x: -10000, y: -10000); clipboardSmokePointerMoved(pointer, panel: panel); pet.mouseExited(with: NSEvent())
        await clipboardUIWait("T-37 shelf closes", { !pet.clipboardPresented })
        pet.pointerLocation = originalPointer
    }

    @MainActor func verifyClipboardCopyFeedback(library: ClipboardLibrary, board: NSPasteboard, base: URL,
                                                png: Data, destination: URL, capture: (String) -> Void) async {
        let originalSettings = library.settings, originalPointer = pet.pointerLocation
        let normalHeadline = pet.headline, normalSubtitle = pet.subtitle
        var pointer = NSPoint(x: -10000, y: -10000)
        pet.pointerLocation = { pointer }; pet.bubbleAlwaysShown = false
        var settings = originalSettings; settings.copyNotifications = true
        library.changeSettings(settings, persist: false)
        let legacy = Data(#"{"enabled":true,"days":7,"count":200,"media":false,"ocr":false,"excludedApps":["fixture.app"]}"#.utf8)
        guard let decoded = try? JSONDecoder().decode(ClipboardSettings.self, from: legacy) else { smokeFailed("T-38 decode old settings") }
        smokeCheck(decoded.copyNotifications && decoded.days == 7 && decoded.count == 200 && !decoded.media && decoded.excludedApps == ["fixture.app"], "T-38 old settings retain values with notifications enabled by default")
        var disabled = decoded; disabled.copyNotifications = false
        smokeCheck((try? JSONDecoder().decode(ClipboardSettings.self, from: JSONEncoder().encode(disabled)).copyNotifications) == false, "T-38 notification setting persists")
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func copy(_ value: String, secret: Bool = false) {
            board.clearContents(); board.setString(value, forType: .string)
            if secret { board.setString("1", forType: ClipboardPasteboard.concealed) }
            library.monitor.poll()
        }
        func expect(_ expected: String) async {
            await clipboardUIWait("T-38 copy feedback appears", { pet.clipboardCopyFrame?.text == expected })
            smokeCheck(pet.clipboardCopyText.accessibilityLabel() == expected, "T-38 accessible feedback matches safe screen text")
        }
        func absent(_ name: String) async {
            await pause(0.35); smokeCheck(pet.clipboardCopyFrame == nil && pet.clipboardCopyText.isHidden, name)
        }
        func captured(_ value: String) async { await clipboardUIWait("T-38 suppressed copy still stored", { library.entries.first?.text == value }) }
        pet.cancelClipboardCopyNotice()
        copy("회의 자료 정리")
        await expect("“회의 자료 정리”가 복사되었습니다")
        let began = ProcessInfo.processInfo.systemUptime
        await pause(0.1)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion")
        smokeCheck(pet.clipboardCopyFrame!.alpha > 0 && pet.clipboardCopyFrame!.alpha < 1 && (reduced ? pet.clipboardCopyFrame!.offset == 0 : pet.clipboardCopyFrame!.offset < 0), "T-38 actual entrance uses opacity and optional upward motion")
        await pause(0.2)
        for (appearance, name) in [(NSAppearance.Name.aqua, "clipboard-copy-light"), (.darkAqua, "clipboard-copy-dark")] {
            panel.appearance = NSAppearance(named: appearance); await pause(0.25); capture(name)
        }
        await clipboardUIWait("T-38 feedback expires", { pet.clipboardCopyFrame == nil })
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        print("T-38 feedback elapsed seconds=\(elapsed)")
        smokeCheck((3.7...4.3).contains(elapsed), "T-38 actual duration four seconds plus/minus 0.3")
        smokeCheck(pet.headline == normalHeadline && pet.subtitle == normalSubtitle && !pet.bubbleText.isHidden, "T-38 original bubble text restored")
        copy("책상"); await expect("“책상”이 복사되었습니다")
        await pause(2)
        copy("다시 정리"); await expect("“다시 정리”가 복사되었습니다")
        let replacedAt = ProcessInfo.processInfo.systemUptime
        smokeCheck(pet.clipboardCopyFrame?.previous != nil, "T-38 live replacement crossfade")
        await pause(2.2); smokeCheck(pet.clipboardCopyFrame != nil, "T-38 replacement survives original deadline")
        await clipboardUIWait("T-38 replacement expires", { pet.clipboardCopyFrame == nil })
        let replacedElapsed = ProcessInfo.processInfo.systemUptime - replacedAt
        smokeCheck((3.7...4.3).contains(replacedElapsed), "T-38 replacement restarts four seconds")
        let report = base.appendingPathComponent("report.pdf")
        let peers = [report, base.appendingPathComponent("peer-2.txt"), base.appendingPathComponent("peer-3.txt")]
        do { for file in peers { try Data("fixture".utf8).write(to: file) } } catch { smokeFailed("T-38 file fixtures") }
        board.clearContents(); board.writeObjects([report as NSURL]); library.monitor.poll()
        await expect("report.pdf이(가) 복사되었습니다")
        board.clearContents(); board.writeObjects(peers.map { $0 as NSURL }); library.monitor.poll()
        await expect("파일 3개가 복사되었습니다")
        board.clearContents(); board.setData(png, forType: .png); library.monitor.poll()
        await expect("이미지가 복사되었습니다")
        board.clearContents(); board.setData(Data([1, 2, 3, 4]), forType: ClipboardPasteboard.video); library.monitor.poll()
        await expect("동영상이 복사되었습니다")
        copy("pw-123", secret: true); await expect("비밀 항목이 복사되었습니다")
        await pause(0.3); capture("clipboard-copy-secret")
        smokeCheck(!(pet.clipboardCopyText.accessibilityLabel() ?? "").contains("pw-123") && !(pet.clipboardCopyFrame?.text ?? "").contains("pw-123"), "T-38 secret never appears in feedback or accessibility")
        pet.cancelClipboardCopyNotice()
        if let entry = library.entries.first(where: { $0.kind == .text && !$0.secret }) {
            library.copy(entry); await pause(0.2); library.monitor.poll()
            await absent("T-38 own pasteboard write has no copy feedback")
        }
        let dropBoard = NSPasteboard.withUniqueName(); defer { dropBoard.releaseGlobally() }
        dropBoard.setString("drop-only", forType: .string)
        smokeCheck(ClipboardDrop(library: library).receive(dropBoard), "T-38 drop fixture accepted")
        await captured("drop-only"); await absent("T-38 drop-in has no copy feedback")
        settings.copyNotifications = false; library.changeSettings(settings, persist: false)
        copy("notice disabled"); await captured("notice disabled"); await absent("T-38 disabled notice setting")
        settings.copyNotifications = true; library.changeSettings(settings, persist: false)
        library.paused = true; copy("monitor paused"); await absent("T-38 paused monitor")
        library.paused = false
        settings.enabled = false; library.changeSettings(settings, persist: false)
        copy("monitor disabled"); await absent("T-38 disabled monitor")
        settings.enabled = true; library.changeSettings(settings, persist: false)
        library.monitor.allowed = { false }; copy("permission denied"); await absent("T-38 denied permission")
        library.monitor.allowed = { true }
        board.clearContents(); board.setString("transient", forType: .string); board.setString("1", forType: ClipboardPasteboard.transient); library.monitor.poll()
        await absent("T-38 transient copy")
        settings.excludedApps = ["excluded.fixture"]; library.changeSettings(settings, persist: false)
        board.clearContents(); board.setString("excluded", forType: .string); board.setString("excluded.fixture", forType: ClipboardPasteboard.source); library.monitor.poll()
        await absent("T-38 excluded source")
        settings.excludedApps = originalSettings.excludedApps; library.changeSettings(settings, persist: false)
        board.clearContents(); board.setString(String(repeating: "x", count: 10 * 1024 * 1024 + 1), forType: .string); library.monitor.poll()
        await clipboardUIWait("T-38 oversized capture rejected", { library.notice == "너무 커서 보관하지 못했어요" })
        await absent("T-38 unsaved copy")
        pet.state = .waiting; copy("approval waiting"); await captured("approval waiting"); await absent("T-38 approval priority")
        pet.state = .idle; pet.actions = ["승인"]
        copy("approval button"); await captured("approval button"); await absent("T-38 approval button priority")
        pet.actions = []; pet.isPaused = true
        copy("pet paused"); await captured("pet paused"); await absent("T-38 pet pause")
        pet.isPaused = false; pet.resting = true
        copy("pet resting"); await captured("pet resting"); await absent("T-38 pet resting")
        pet.resting = false; panel.orderOut(nil)
        copy("pet hidden"); await captured("pet hidden"); await absent("T-38 hidden pet")
        panel.orderFrontRegardless()
        let head = pet.atlas.interactionRect(in: pet.spriteRect)
        pointer = panel.convertPoint(toScreen: pet.convert(NSPoint(x: head.midX, y: head.midY), to: nil))
        pet.mouseEntered(with: NSEvent())
        await clipboardSmokeOpenDrawer(pet, panel: panel)
        await clipboardUIWait("T-38 shelf opened", { pet.clipboardPresented })
        copy("shelf open"); await captured("shelf open"); await absent("T-38 open shelf")
        pointer = NSPoint(x: -10000, y: -10000); clipboardSmokePointerMoved(pointer, panel: panel); pet.mouseExited(with: NSEvent())
        await clipboardUIWait("T-38 shelf closed", { !pet.clipboardPresented })
        await pause(0.5) // Let the shelf's window settle before targeting the live head, as a real pointer would.
        copy("hover cancels"); await expect("“hover cancels”이(가) 복사되었습니다")
        for _ in 0..<100 {
            let currentHead = pet.atlas.interactionRect(in: pet.spriteRect)
            pointer = panel.convertPoint(toScreen: pet.convert(NSPoint(x: currentHead.midX, y: currentHead.midY), to: nil))
            pet.mouseEntered(with: NSEvent())
        await clipboardSmokeOpenDrawer(pet, panel: panel); await pause(0.02)
            if pet.clipboardPresented && pet.clipboardCopyFrame == nil { break }
        }
        smokeCheck(pet.clipboardPresented && pet.clipboardCopyFrame == nil, "T-38 hover opens shelf and ends notice")
        pointer = NSPoint(x: -10000, y: -10000); clipboardSmokePointerMoved(pointer, panel: panel); pet.mouseExited(with: NSEvent())
        await clipboardUIWait("T-38 shelf closes after hover", { !pet.clipboardPresented })
        showChat(); copy("chat open"); await captured("chat open"); await absent("T-38 expanded conversation")
        collapseChat(); await pause(1)
        pet.cancelClipboardCopyNotice(); library.changeSettings(originalSettings, persist: false)
        library.clear(includingPins: true); await clipboardUIWait("T-38 fixture cleanup", { library.entries.isEmpty })
        pet.pointerLocation = originalPointer
        do { try "PASS T-38 phrase, opacity, motion, replacement, exclusions and masking\nduration=\(elapsed) replacement=\(replacedElapsed) reduced=\(reduced)\n".write(to: destination.appendingPathComponent("clipboard-notice-checks.txt"), atomically: true, encoding: .utf8) }
        catch { smokeFailed("T-38 report write") }
    }
}


@MainActor func clipboardSmokePointerMoved(_ point: CGPoint, panel: PetPanel) {
    let event = NSEvent.mouseEvent(with: .mouseMoved, location: panel.convertPoint(fromScreen: point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
    NSApp.postEvent(event, atStart: false)
}
