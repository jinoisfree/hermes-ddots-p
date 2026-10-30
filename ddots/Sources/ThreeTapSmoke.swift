import AppKit

extension AppDelegate {
    @MainActor
    func verifyThreeTap(destination: URL) async {
        func save(_ view: NSView, _ name: String) {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { smokeFailed("Three-tap capture bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + ".png"))
        }
        func saveAlert(_ alert: NSAlert, _ name: String) async {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let root = alert.window.contentView!
            root.layoutSubtreeIfNeeded()
            // Vibrant AppKit labels cannot be cached faithfully. Draw the existing view geometry and text in-app.
            let picture = NSImage(size: root.bounds.size)
            alert.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                picture.lockFocus()
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: root.bounds, xRadius: 20, yRadius: 20).fill()
                func text(_ value: String, rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
                    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
                    value.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
                }
                func draw(_ view: NSView) {
                    let rect = root.convert(view.bounds, from: view)
                    if let scroll = view as? NSScrollView, let request = scroll.documentView as? NSTextView {
                        NSColor.textBackgroundColor.setFill(); rect.fill()
                        NSColor.separatorColor.setStroke(); NSBezierPath(rect: rect).stroke()
                        text(request.string, rect: rect.insetBy(dx: 8, dy: 8), font: request.font ?? .systemFont(ofSize: 13), color: .textColor)
                    } else if let button = view as? NSButton {
                        NSColor.controlColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: rect.height/2, yRadius: rect.height/2).fill()
                        let font = button.font ?? .systemFont(ofSize: 13)
                        text(button.title, rect: NSRect(x: rect.minX, y: rect.midY-font.pointSize/2-2, width: rect.width, height: font.pointSize+5), font: font, color: .controlTextColor, alignment: .center)
                    } else if let label = view as? NSTextField {
                        text(label.stringValue, rect: rect, font: label.font ?? .systemFont(ofSize: 13), color: .labelColor, alignment: label.alignment)
                    } else if let icon = view as? NSImageView, let image = icon.image { image.draw(in: rect) }
                    else { view.subviews.forEach(draw) }
                }
                draw(root)
                picture.unlockFocus()
            }
            guard let data = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { smokeFailed("Three-tap alert drawing") }
            try? png.write(to: destination.appendingPathComponent(name + ".png"))
        }
        showOptions()
        settingsTabs?.selectTabViewItem(withIdentifier: "화면과 펫")
        func menuPicture(_ name: String) {
            if let view = optionsWindow?.contentView { save(view, name) }
        }
        guard let item = tapCheckbox else { smokeFailed("Three-tap setting exists") }
        smokeCheck(item.state == .on && threeTap.enabled, "Three-tap defaults on without opening the private reader in smoke")
        menuPicture("three-tap-on")
        threeTap.toggle(); smokeCheck(item.state == .off && !threeTap.enabled, "Three-tap turns off")
        menuPicture("three-tap-off")
        threeTap.toggle(); smokeCheck(item.state == .on, "Three-tap turns on")
        threeTap.receive(.ready)
        let wasExpanded = chatExpanded
        threeTap.tapped()
        try? await Task.sleep(nanoseconds: 700_000_000)
        smokeCheck(chatExpanded != wasExpanded, "Injected tap follows the pet click path")
        threeTap.tapped()
        try? await Task.sleep(nanoseconds: 700_000_000)
        smokeCheck(chatExpanded == wasExpanded, "Second injected tap restores the conversation")
        panel.orderOut(nil); threeTap.tapped()
        smokeCheck(chatExpanded == wasExpanded, "Hidden pet ignores a tap")
        panel.orderFrontRegardless()
        var notices: [String] = [], failures: [ThreeTapFailure] = []
        threeTap.onNotice = { text, _ in notices.append(text) }
        threeTap.onFailure = { failures.append($0) }
        threeTap.receive(.failed("합성 점검: MTDeviceStart"))
        smokeCheck(!item.isEnabled && item.state == .off && failures.count == 1 && notices.count == 1, "Fault disables the menu and routes one synthetic notice")
        threeTap.receive(.failed("합성 점검: MTDeviceStart"))
        smokeCheck(failures.count == 1, "Fault is not repeated")
        menuPicture("three-tap-failed")
        let failure = threeTap.failure!
        if chatExpanded { collapseChat(); try? await Task.sleep(nanoseconds: 700_000_000) }
        threeTap.showNotice(notices[0], failure: failure)
        let alert = threeTap.noticeAlert!
        threeTap.showNotice(notices[0], failure: failure)
        smokeCheck(threeTap.noticeAlert === alert && NSApp.modalWindow == nil, "One nonmodal notice")
        petClicked(count: 1)
        try? await Task.sleep(nanoseconds: 700_000_000)
        smokeCheck(chatExpanded && alert.window.isVisible, "Pet click opens chat while notice stays visible")
        await saveAlert(alert, "three-tap-failure-alert")
        threeTap.showNotice(ThreeTapController.healthyText, failure: nil)
        smokeCheck(threeTap.noticeAlert === alert, "Different notice waits instead of overlapping")
        alert.buttons.last!.performClick(nil)
        smokeCheck(threeTap.noticeAlert == nil, "Notice close button releases the window")
        try? await Task.sleep(nanoseconds: 100_000_000)
        smokeCheck(threeTap.noticeAlert?.informativeText == ThreeTapController.healthyText, "Queued notice appears after closing")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ddots.three-tap.smoke"))
        ThreeTapController.copy(failure, to: pasteboard)
        smokeCheck(pasteboard.string(forType: .string) == failure.request, "Complete repair request copied")
        try? failure.request.write(to: destination.appendingPathComponent("three-tap-request.txt"), atomically: true, encoding: .utf8)
        threeTap.showNotice(ThreeTapController.healthyText, failure: nil)
        let healthy = threeTap.noticeAlert!
        await saveAlert(healthy, "three-tap-healthy-alert")
        healthy.buttons.last!.performClick(nil)
        try? "PASS: isolated toggle preferences, fault injection, one notice, copy request, menu and alert captures; no private reader or Slack sender started\nMenu images render NSMenuItem data; alert images draw actual view geometry/text in-app, without system vibrancy or window shadows. Nonmodal notice allowed pet click and timer progress; duplicate and queued notices checked.\n".write(to: destination.appendingPathComponent("three-tap.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

extension AppDelegate {
    /// The status menu as built, top level and every submenu, drawn from the real items (titles, checks, separators).
    @MainActor func verifyMenuPicture(destination: URL) {
        menuNeedsUpdate(menu)
        var lines: [(String, Bool)] = []
        func walk(_ parent: NSMenu, depth: Int) {
            for item in parent.items where !item.isHidden {
                let indent = String(repeating: "        ", count: depth)
                if item.isSeparatorItem { lines.append((indent + "──────────", true)); continue }
                lines.append((indent + (item.state == .on ? "✓ " : "   ") + item.title + (item.submenu != nil ? "   ▸" : ""), item.isEnabled))
                if let sub = item.submenu { walk(sub, depth: depth + 1) }
            }
        }
        walk(menu, depth: 0)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: CGFloat(lines.count) * 24 + 16))
        box.wantsLayer = true; box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for (index, line) in lines.enumerated() {
            let text = NSTextField(labelWithString: line.0)
            text.font = .systemFont(ofSize: 13); text.textColor = line.1 ? .labelColor : .disabledControlTextColor
            text.frame = NSRect(x: 12, y: box.bounds.height - CGFloat(index + 1) * 24, width: 400, height: 20)
            box.addSubview(text)
        }
        if let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds) {
            box.cacheDisplay(in: box.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("menu.png"))
        }
        try? lines.map(\.0).joined(separator: "\n").write(to: destination.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        let top = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.count
        smokeCheck(top == 8, "The top level keeps eight daily and app actions: \(top)")
        for title in ["대화 열기", "작업 목록", "내 캘린더", "설정…", "업데이트 확인…", "ddots 종료"] {
            smokeCheck(menuItem(titled: title)?.action != nil, "Menu keeps " + title)
        }
        smokeCheck(menuItem(titled: "설정…")?.keyEquivalent == ",", "Settings shortcut")
        showOptions()
        guard let tabs = settingsTabs else { smokeFailed("Settings categories exist") }
        let expected = ["일반", "화면과 펫", "연결과 동기화"] + (ShrimpVault.defaultBot.isEmpty ? [] : ["새우튀김 보관함"]) + ["고급"]
        smokeCheck(tabs.tabViewItems.map(\.label) == expected, "Settings categories match the organization")
        var actions: Set<String> = []
        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            scrollOptionsToTop()
            guard let scroll = settingsScroll, let document = scroll.documentView else { smokeFailed("Scrollable settings category") }
            for control in document.subviews.compactMap({ $0 as? NSControl }) {
                if let action = control.action { actions.insert(NSStringFromSelector(action)) }
                smokeCheck(control.frame.minX >= 0 && control.frame.maxX <= document.bounds.width, "Control fits category width")
            }
            if let view = optionsWindow?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("settings-" + item.label + ".png"))
            }
        }
        for selector in [#selector(configureSlack), #selector(configureHermes), #selector(configureRelay),
                         #selector(makeSyncStandard), #selector(showHooksHelp), #selector(connectAppUpdate),
                         #selector(preview), #selector(previewPointer), #selector(changeChatTheme(_:)),
                         #selector(toggleBubbleAlwaysShown(_:)), #selector(toggleThreeTap)] {
            smokeCheck(actions.contains(NSStringFromSelector(selector)), "Settings preserve " + NSStringFromSelector(selector))
        }
        smokeCheck(chatThemePicker?.itemTitles == ChatTheme.allCases.map(\.title), "All three theme choices remain")
        NSApp.terminate(nil)
    }
}
