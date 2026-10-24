import AppKit

extension AppDelegate {
    func verifyFormatting(destination: URL) {
        Task { @MainActor [self] in
            func settle(_ milliseconds: UInt64 = 300) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
            smokeCheck(isSmoke && !slack.persists && slack.connected, "Formatting uses synthetic data only")
            var sent: [String] = []
            chat.onSend = { sent.append($0) }
            slack.model.onSend = { text, _, _, _ in sent.append(text) }
            slack.model.select("CTRUTH")
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
            let replyBody = "# 오늘의 계획\n<span style=\"font-size:16px;color:#4285E8\"><b>중요한 안내</b></span>와 <u>확인할 부분</u>\n    - [ ] 첫 번째 할 일\n    - [x] 끝낸 일\n**굵은 글씨** · 일반 글씨 · [문서](https://example.com)"
            let sources: [ChatSource] = IMessageFeature.enabled ? [.imessage, .slack] : [.slack]
            for source in sources {
                slack.model.source = source; await settle()
                let original = "오늘 계획\n첫 항목\n둘째 항목"
                if source == .imessage { chat.draft = original; chat.focusDraftRevision += 1 }
                else { slack.model.draft = original; slack.model.focusRevision += 1 }
                await settle(600)
                guard let editor = panel.firstResponder as? DraftTextView, let controls = editor.formattingController else { smokeFailed("Formatting editor has focus") }
                editor.setSelectedRange(NSRange(location: 0, length: 5)); await settle()
                controls.size(20); controls.color("#4285E8"); controls.bold(); controls.underline(); await settle()
                let attrs = editor.attributedString().attributes(at: 0, effectiveRange: nil)
                smokeCheck((attrs[.font] as? NSFont)?.pointSize == 20 && NSFontManager.shared.traits(of: attrs[.font] as! NSFont).contains(.boldFontMask), "Size and bold appear in the editor")
                smokeCheck(MessageFormat.hex(attrs[.foregroundColor] as! NSColor) == "#4285E8" && (attrs[.underlineStyle] as? Int) == 1, "Colour and underline appear in the editor")
                let saved = source == .imessage ? chat.draft : slack.model.draft
                smokeCheck(MessageFormat.editor(saved).string == original && saved.contains("font-size:20px") && saved.contains("<u>"), "Rich draft has a transport representation without losing text")
                editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
                controls.lines(.indent); await settle()
                smokeCheck(editor.string.hasPrefix("    오늘 계획"), "Paragraph indentation is visible")
                smokeCheck((editor.attributedString().attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.pointSize == 20, "Indentation retains inline formatting")
                controls.lines(.outdent); await settle()
                smokeCheck(editor.string == original, "Outdent restores the paragraphs")
                editor.setSelectedRange((editor.string as NSString).range(of: "첫 항목")); controls.lines(.checkbox); await settle()
                smokeCheck(editor.string.contains("☐ 첫 항목"), "Checkbox insertion keeps the item")
                controls.lines(.checkbox); await settle()
                smokeCheck(editor.string.contains("☑ 첫 항목"), "Checkbox toggles to checked")
                let rich = source == .imessage ? chat.draft : slack.model.draft
                collapseChat(); await settle(500); showChat(); await settle(600)
                smokeCheck((source == .imessage ? chat.draft : slack.model.draft) == rich, "Folding preserves all formatting")
                let rendered = MessageFormat.render(rich)
                smokeCheck(rendered.runs.contains { $0.foregroundColor != nil } && rendered.runs.contains { $0.underlineStyle != nil }, "Message display retains colour and underline")
                let reply = ChatMessage(id: "format-reply", fromUser: false, speaker: "위키담당", body: replyBody, date: Date(), profile: "default")
                if source == .imessage { chat.messages = [reply] }
                else {
                    slack.model.threads = [SlackThread(id: "format-thread", room: "CTRUTH", ts: "100.1", root: reply, replies: [], replyCount: 0, loaded: true, latest: 100, latestFromUser: false)]
                }
                await settle()
                if #available(macOS 15.0, *) {
                    let plain = String(MessageFormat.render(replyBody).characters)
                    let offset = plain.distance(from: plain.startIndex, to: plain.firstIndex(of: "☐")!)
                    let url = URL(string: "ddots-check://toggle/\(offset)")!
                    func target(_ view: NSView) -> (NSView, CGRect)? {
                        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
                        if let link = view as? LinkCursorView, link.enabled, let rect = link.rect(forLink: url) { return (link, rect) }
                        if let text = view as? NativeThreadCard.Text, let storage = text.textStorage,
                           let layout = text.layoutManager, let container = text.textContainer {
                            var match: NSRange?
                            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                                if value as? URL == url { match = range }
                            }
                            if let match {
                                layout.ensureLayout(for: container)
                                let glyphs = layout.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
                                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                                    .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
                                return (text, rect)
                            }
                        }
                        return view.subviews.lazy.compactMap(target).first
                    }
                    guard let (link, rect) = target(pet) else { smokeFailed("Agent checkbox has a clickable glyph") }
                    let point = link.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
                    let key = MessageChecklist.key(reply.id + (source == .slack ? ":block:0" : ""), text: replyBody)
                    let sendsBefore = sent.count
                    for checked in [true, false] {
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
                        }
                        await settle()
                        smokeCheck(MessageChecklist.shared.checked(key, offset: offset, original: false) == checked && sent.count == sendsBefore,
                                   "Clicking an agent checkbox toggles only the reader's state")
                    }
                }
                capture(destination: destination.appendingPathComponent(source == .imessage ? "imessage" : "slack"))
                if source == .imessage { chat.onSend?(rich) } else { slack.model.send() }
                smokeCheck(sent.last == rich, "Synthetic send carries the same formatted draft")
                if source == .imessage { chat.draft = "제목 확인"; chat.focusDraftRevision += 1 }
                else { slack.model.draft = "제목 확인"; slack.model.focusRevision += 1 }
                await settle()
                editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length)); controls.heading(1); await settle()
                smokeCheck((editor.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 24, "Title paragraph applies its size")
                controls.clear(); await settle()
                smokeCheck(MessageFormat.serialize(editor.attributedString()) == "제목 확인", "Clear formatting restores plain text")
                controls.lines(.bullet); await settle()
                smokeCheck(editor.string == "• 제목 확인", "Bulleted paragraph is available")
                controls.lines(.bullet); controls.lines(.numbered); await settle()
                smokeCheck(editor.string == "1. 제목 확인", "Numbered paragraph is available")
                await verifyPlainPaste(editor: editor, source: source)
            }
            let checks = MessageChecklist(persist: false), key = MessageChecklist.key("synthetic", text: replyBody)
            checks.toggle(key, offset: 3, original: false)
            smokeCheck(checks.checked(key, offset: 3, original: false), "A reader can check an agent's task")
            checks.toggle(key, offset: 3, original: false)
            smokeCheck(!checks.checked(key, offset: 3, original: false) && sent.count == sources.count, "Unchecking never sends an extra message")
            let note = "PASS: enabled composers, selected text size/colour/bold/underline, indentation preserves styles, checkbox insertion/toggle, fold retention, synthetic formatted send, agent reply display and local checklist state; Command-V of RTF/HTML/rich+plain copies inserts default 13pt label-colour text inside formatted text, HTML pre spacing/table cells/named characters/quoted > in attributes, replaces a selection, keeps Korean lines and spaces, later typing plain, undo/redo, empty clipboard ignored, clipboard restored\n"
            try! note.write(to: destination.appendingPathComponent("formatting.txt"), atomically: true, encoding: .utf8)
            print(note); NSApp.terminate(nil)
        }
    }

    /// Text copied with its own size, colour, weight and underline comes in plain, even in the middle of styled text.
    @MainActor private func verifyPlainPaste(editor: DraftTextView, source: ChatSource) async {
        func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        func restoreBoard() {
            board.clearContents()
            board.writeObjects(saved.map { pairs in let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1, forType: $0.0) }; return item })
        }
        func check(_ ok: Bool, _ message: String) { if !ok { restoreBoard(); smokeFailed("\(source): " + message) } }
        func draft() -> String { source == .imessage ? chat.draft : slack.model.draft }
        func commandV() {
            NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!)
        }
        func plain(_ range: NSRange) -> Bool {
            let text = editor.attributedString()
            guard range.length > 0, NSMaxRange(range) <= text.length else { return false }
            var ok = true
            text.enumerateAttributes(in: range) { attrs, _, _ in
                let font = attrs[.font] as? NSFont
                ok = ok && font?.pointSize == MessageFormat.baseSize && font.map { NSFontManager.shared.traits(of: $0).intersection([.boldFontMask, .italicFontMask]).isEmpty } == true
                    && (attrs[.foregroundColor] as? NSColor) == NSColor.labelColor && (attrs[.underlineStyle] as? Int ?? 0) == 0
                    && (attrs[.strikethroughStyle] as? Int ?? 0) == 0 && attrs[.backgroundColor] == nil && attrs[.link] == nil
            }
            return ok && MessageFormat.serialize(text.attributedSubstring(from: range)) == (text.string as NSString).substring(with: range)
        }
        let styled = "<span style=\"font-size:20px;color:#4285E8\"><b>앞 서식 뒤</b></span>"
        if source == .imessage { chat.draft = styled } else { slack.model.draft = styled }
        await settle()
        check(editor.string == "앞 서식 뒤" && !plain(NSRange(location: 0, length: 1)), "Styled draft is in the editor before pasting")
        defer { restoreBoard() }

        let copied = "큰 글씨 붙여넣기\n둘째  줄 공백"
        let loud: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.systemRed,
                                                   .underlineStyle: NSUnderlineStyle.single.rawValue, .backgroundColor: NSColor.yellow]
        let rich = NSAttributedString(string: copied, attributes: loud)
        let rtf = try! rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.clearContents(); board.setData(rtf, forType: .rtf)
        editor.setSelectedRange(NSRange(location: 2, length: 0)); await settle()
        commandV(); await settle()
        let length = (copied as NSString).length
        check(editor.string == "앞 " + copied + "서식 뒤", "RTF-only paste keeps the words, lines and spaces: \(editor.string.debugDescription)")
        check(plain(NSRange(location: 2, length: length)), "RTF paste inside styled text uses the default size and colour")
        check(!plain(NSRange(location: 0, length: 2)) && !plain(NSRange(location: 2 + length, length: 1)), "Text around the paste keeps its own formatting")
        check(draft().contains(copied) && !draft().contains("34px") && !draft().contains("#FF"), "The draft carries the pasted text unstyled: \(draft().debugDescription)")
        check(editor.selectedRange() == NSRange(location: 2 + length, length: 0), "The caret ends after the pasted text")
        check((editor.typingAttributes[.font] as? NSFont) == NSFont.systemFont(ofSize: MessageFormat.baseSize)
              && (editor.typingAttributes[.foregroundColor] as? NSColor) == NSColor.labelColor && editor.typingAttributes[.underlineStyle] == nil,
              "The next typed letter after a paste is in the default style")
        editor.undo(nil); await settle()
        check(editor.string == "앞 서식 뒤" && draft() == styled, "Undo removes the paste and restores the styled draft: \(draft().debugDescription)")
        editor.redo(nil); await settle()
        check(editor.string == "앞 " + copied + "서식 뒤" && plain(NSRange(location: 2, length: length)), "Redo brings the paste back plain")
        editor.setSelectedRange(NSRange(location: 2 + length, length: 0)); await settle()
        editor.insertText("가", replacementRange: editor.selectedRange()); await settle()
        check(editor.string == "앞 " + copied + "가서식 뒤" && plain(NSRange(location: 2 + length, length: 1)), "Typing right after a paste stays in the default style")

        let html = "<html><head><style>p{color:red}</style></head><body><span style=\"font-size:40px;color:#E05252\"><b><u>웹 &amp; 글</u></b></span><br>다음&nbsp;줄<p><i>문단</i></p></body></html>"
        board.clearContents(); board.setData(Data(html.utf8), forType: .html)
        let target = (editor.string as NSString).range(of: "서식")
        editor.setSelectedRange(target); await settle()
        commandV(); await settle()
        let webText = "웹 & 글\n다음 줄\n문단"
        check(editor.string == "앞 " + copied + "가" + webText + " 뒤", "HTML-only paste replaces the selection with its text: \(editor.string.debugDescription)")
        check(plain(NSRange(location: target.location, length: (webText as NSString).length)), "HTML paste uses the default size and colour")
        check(!plain(NSRange(location: target.location + (webText as NSString).length + 1, length: 1)), "Text after a replaced selection keeps its formatting")

        let both = NSAttributedString(string: "복사한 문장", attributes: loud)
        board.clearContents(); board.writeObjects([both])
        check(board.string(forType: .string) == "복사한 문장" && board.data(forType: .rtf) != nil, "Rich copies offer plain and RTF text")
        editor.setSelectedRange(NSRange(location: 0, length: 0)); await settle()
        commandV(); await settle()
        check(editor.string.hasPrefix("복사한 문장앞 ") && plain(NSRange(location: 0, length: 6)), "A rich copy with plain text pastes its plain text in the default style")

        let before = editor.string, beforeDraft = draft()
        board.clearContents(); commandV(); await settle()
        check(editor.string == before && draft() == beforeDraft, "An empty clipboard changes nothing")

        // Web copies keep <pre> spacing, separate table cells, read named characters and never show a tag's attributes.
        let pages = [("<pre style=\"font-size:30px;color:red\">첫째 줄\n  둘째  줄</pre>", "첫째 줄\n  둘째  줄"),
                     ("<table><tr><th><b>이름</b></th><th>수량</th></tr><tr><td style=\"color:#E05252\">사과</td><td>3</td></tr></table>", "이름\t수량\n사과\t3"),
                     ("<p style=\"font-size:24px\">A &copy; B &mdash; C &hellip; &euro;</p>", "A © B — C … €"),
                     ("<a title=\"a>b\" href='x>y' style=\"color:blue\"><u>링크</u></a> 뒤", "링크 뒤")]
        for (page, expected) in pages {
            if source == .imessage { chat.draft = styled } else { slack.model.draft = styled }
            await settle()
            board.clearContents(); board.setData(Data(page.utf8), forType: .html)
            editor.setSelectedRange(NSRange(location: 2, length: 0)); await settle()
            commandV(); await settle()
            check(editor.string == "앞 " + expected + "서식 뒤", "HTML-only paste keeps the page's text: \(editor.string.debugDescription) for \(page.debugDescription)")
            check(plain(NSRange(location: 2, length: (expected as NSString).length)), "HTML-only paste is in the default style: \(expected.debugDescription)")
        }
        restoreBoard()
        check((board.pasteboardItems ?? []).count == saved.count, "The clipboard is restored after the paste checks")
    }
}
