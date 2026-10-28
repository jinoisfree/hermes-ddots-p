import AppKit
import SwiftUI

extension AppDelegate {
    /// Synthetic model checks plus the real DDots editor's paste shortcut. Never calls a transport.
    func verifyComposer(destination: URL, then finish: @escaping () -> Void) {
        let sample = SlackModel()
        sample.source = .slack; sample.selected = Ddots.room
        let root = ChatMessage(id: "smoke-post", fromUser: true, speaker: "", body: "합성 새 글", date: Date(), profile: "")
        var thread = SlackThread(id: "smoke-thread", room: "Dassistant", ts: "100.1", root: root, replies: [], replyCount: 0, loaded: true, latest: 100, latestFromUser: true)
        let answer = ChatMessage(id: "smoke-answer", fromUser: false, speaker: "개인비서", body: "합성 답변", date: Date(), profile: "personal-secretary")
        sample.writeNewPost()
        sample.followPost(room: thread.room, ts: thread.ts, revision: sample.beginPost())
        sample.threads = [thread]
        smokeCheck(sample.target == nil, "A new post waits for an actual answer")
        var thinking = answer; thinking.body = "◐ 생각 중..."
        thread.replies = [thinking]; sample.threads = [thread]
        smokeCheck(sample.target == nil, "Thinking is not an answer")
        thread.replies = [answer]; sample.threads = [thread]
        smokeCheck(sample.target?.id == thread.id && !sample.newPost, "Answer selects reply in the sent thread")
        sample.writeNewPost()
        let stale = sample.beginPost()
        sample.writeNewPost()
        sample.followPost(room: thread.room, ts: thread.ts, revision: stale)
        smokeCheck(sample.target == nil, "An explicit new-post choice overrides delayed send completion")
        sample.draft = "다른 새 글 작성 중"
        sample.followPost(room: thread.room, ts: thread.ts, revision: sample.beginPost())
        smokeCheck(sample.target == nil && sample.draft == "다른 새 글 작성 중", "Never redirect an existing draft")
        sample.draft = ""
        sample.followPost(room: "OTHER", ts: thread.ts, revision: sample.beginPost())
        sample.threads = [thread]
        smokeCheck(sample.target == nil, "Another room's answer cannot choose the destination")
        sample.followPost(room: thread.room, ts: thread.ts, revision: sample.beginPost())
        sample.writeNewPost()
        thread.root.files = [ChatFile(id: "F-SYNTHETIC", name: "합성.png", mimetype: "image/png", size: 1, url: "https://example.com/synthetic.png", thumb: "")]
        sample.followPost(room: thread.room, ts: nil, files: ["F-SYNTHETIC"], revision: sample.beginPost())
        sample.threads = [thread]
        smokeCheck(sample.target?.id == thread.id, "File-only new posts select their own thread by upload receipt")

        Task { @MainActor [self] in
            let board = NSPasteboard.general
            let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
            func restoreBoard() {
                board.clearContents()
                board.writeObjects(saved.map { pairs in let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1, forType: $0.0) }; return item })
            }
            func check(_ ok: Bool, _ message: String) {
                if !ok { restoreBoard(); try? message.write(to: destination.appendingPathComponent("composer-failure.txt"), atomically: true, encoding: .utf8); smokeFailed(message) }
            }
            func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }
            let model = slack.model
            let anchor = pet.placement!.globalSprite
            check(pet.placement!.windowFrame.contains(anchor), "Open chat retains the desktop pet inside its window")
            check(!anchor.intersects(pet.placement!.globalBubble), "Pet stays outside the chat instead of overlapping its title bar")
            capture(destination: destination.appendingPathComponent("pet-position-open"))
            collapseChat()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let restored = pet.placement!.globalSprite
            check(restored.size == anchor.size && hypot(restored.minX - anchor.minX, restored.minY - anchor.minY) < 1,
                  "Closing retains the original desktop pet position within a backing pixel: before=\(anchor), after=\(restored)")
            capture(destination: destination.appendingPathComponent("pet-position-closed"))
            showChat()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let reopened = pet.placement!.globalSprite
            let positions = "open=\(anchor), closed=\(restored), reopened=\(reopened), bubble=\(pet.placement!.globalBubble)\n"
            try! positions.write(to: destination.appendingPathComponent("pet-position.txt"), atomically: true, encoding: .utf8)
            check(hypot(reopened.minX - restored.minX, reopened.minY - restored.minY) < 1 && !reopened.intersects(pet.placement!.globalBubble),
                  "Reopening leaves the pet at its desktop position within a backing pixel: " + positions)
            let originalScale = pet.petScale
            for scale: CGFloat in [0.5, 1.5] {
                pet.petScale = scale; placePet(at: anchor.origin)
                await settle()
                check(pet.spriteRect.size == PetLayout(scale: scale).spriteSize, "Existing desktop size control remains available")
            }
            pet.petScale = originalScale; placePet(at: anchor.origin); await settle()
            if model.isDdots {
                // The pet also reads the threads kept past the shown window for approvals, so those go too.
                let threads = model.threads, typing = model.typing, approvalThreads = model.approvalThreads
                model.threads = []; model.typing = [:]; model.approvalThreads = nil
                model.petWave += 1
                try? await Task.sleep(nanoseconds: 150_000_000)
                check(pet.animationFrame.row == PetAnimation.waving.rawValue, "Desktop pet preserves the sending wave: row \(pet.animationFrame.row)")
                model.petHop += 1
                try? await Task.sleep(nanoseconds: 150_000_000)
                check(pet.animationFrame.row == PetAnimation.jumping.rawValue, "Desktop pet preserves the reply jump")
                try? await Task.sleep(nanoseconds: 900_000_000)
                model.typing = ["smoke": [TypingIndicator(id: "smoke", speaker: "개인비서", profile: "personal-secretary")]]
                try? await Task.sleep(nanoseconds: 150_000_000)
                check(pet.animationFrame.row == PetAnimation.replyWaiting.rawValue, "Desktop pet preserves the writing animation")
                model.threads = threads; model.typing = typing; model.approvalThreads = approvalThreads
            }
            let draft = model.draft, attachments = model.attachments, send = model.onSend
            defer { restoreBoard(); model.draft = draft; model.attachments = attachments; model.onSend = send }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-composer-smoke-" + UUID().uuidString)
            SmokeLeftovers.note(folder)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("합성 첨부.txt")
            try! Data("합성 파일".utf8).write(to: file)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<16 { for y in 0..<16 { bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1), atX: x, y: y) } }
            let png = bitmap.representation(using: .png, properties: [:])!
            // Words belong to the place they are typed for, so the new post is chosen before typing.
            model.writeNewPost()
            model.draft = "첨부 전 확인"; model.attachments = []
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
            model.focusRevision += 1
            await settle()
            guard let measured = chat.smokeFrames["slack-draft"],
                  let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first else { check(false, "DDots draft frame is measurable"); return }
            let point = host.convert(CGPoint(x: measured.midX, y: host.isFlipped ? measured.midY : host.bounds.height - measured.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
            }
            await settle()
            capture(destination: destination.appendingPathComponent("paste-focus"))
            check(panel.isKeyWindow && model.composerFocused && (panel.firstResponder as? NSTextView)?.isEditable == true,
                  "DDots composer has keyboard focus: key=\(panel.isKeyWindow), focused=\(model.composerFocused), responder=\(String(describing: panel.firstResponder))")
            // Shift-Return starts a new line in the draft and sends nothing. A syllable still being composed is kept first.
            @MainActor func shiftReturn() {
                NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
            }
            @MainActor func editor() -> NSTextView? { panel.firstResponder as? NSTextView }
            var posted = 0
            model.onSend = { _, _, _, _ in posted += 1 }
            ChatView.moveCaretToEnd(in: panel); shiftReturn()
            await settle()
            check(model.draft == "첨부 전 확인\n" && posted == 0, "Shift-Return starts a new line in the draft and sends nothing: \(model.draft.debugDescription)")
            editor()?.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            check(editor()?.hasMarkedText() == true, "A syllable is being composed")
            shiftReturn()
            await settle()
            check(model.draft == "첨부 전 확인\nㅎ\n" && editor()?.hasMarkedText() == false && posted == 0,
                  "A syllable still being composed is kept, and the line is broken after it: \(model.draft.debugDescription)")
            model.onSend = send; model.draft = "첨부 전 확인"
            await settle()
            @MainActor func paste(_ character: String = "v") {
                NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 9)!)
            }
            board.clearContents(); board.writeObjects([file as NSURL]); paste()
            await settle()
            check(model.attachments == [file] && model.draft == "첨부 전 확인", "Command-V attaches a Finder file without replacing text (files=\(model.attachments.count), draft=\(model.draft.debugDescription), focused=\(model.composerFocused))")
            board.clearContents(); board.setData(png, forType: .png); paste("ㅍ")
            await settle()
            check(model.attachments.count == 2 && model.attachments.last?.pathExtension == "png", "Korean-input Command-V attaches a clipboard image")
            check(model.attachments.last.flatMap { try? Data(contentsOf: $0) }.flatMap(NSBitmapImageRep.init(data:))?.pixelsWide == 16, "Pasted image is readable upload data")
            capture(destination: destination.appendingPathComponent("pasted-attachments"))
            model.detach(file)
            check(model.attachments.count == 1 && FileManager.default.fileExists(atPath: file.path), "Removing an attachment preserves its original")
            board.clearContents(); board.setString(" 일반 텍스트", forType: .string); paste()
            await settle()
            check(model.draft.contains("일반 텍스트") && model.attachments.count == 1, "Ordinary text paste still goes to the draft")
            board.clearContents(); board.setData(bitmap.tiffRepresentation!, forType: .tiff); paste()
            await settle()
            check(model.attachments.count == 2, "TIFF screenshots convert to PNG attachments")
            board.clearContents(); board.writeObjects([folder as NSURL]); paste()
            await settle()
            check(model.attachments.count == 2 && model.notice != nil, "Folders are rejected with an explanation")
            model.notice = nil
            var sentFiles: [URL] = []
            model.onSend = { _, _, _, files in sentFiles = files }
            model.send()
            check(sentFiles.count == 2 && model.attachments.isEmpty && sentFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Pasted images reach the existing send callback and stay alive for upload")
            let dropBoard = NSPasteboard(name: NSPasteboard.Name("ddots-drop-smoke-" + UUID().uuidString))
            defer { dropBoard.releaseGlobally() }
            @MainActor func dropViews(_ view: NSView) -> [AttachmentDropView] {
                if let drop = view as? AttachmentDropView { return [drop] }
                return view.subviews.flatMap(dropViews)
            }
            guard let drop = dropViews(host).first else { check(false, "Slack conversation has an attachment drop destination"); return }
            let secondFile = folder.appendingPathComponent("합성 두 번째.txt")
            try! Data("두 번째 합성 파일".utf8).write(to: secondFile)
            posted = 0; sentFiles = []
            model.onSend = { _, _, _, files in posted += 1; sentFiles = files }
            model.draft = "드롭 전 확인"; model.attachments = []
            await settle()
            let conversationPoint = drop.convert(CGPoint(x: drop.bounds.midX, y: 40), to: nil)
            dropBoard.clearContents(); dropBoard.writeObjects([file as NSURL, secondFile as NSURL])
            check(drop.updateDrag(from: dropBoard, at: conversationPoint) == .copy && drop.targeted, "File dragging highlights the conversation")
            await settle()
            capture(destination: destination.appendingPathComponent("drop-target"))
            drop.draggingExited(nil)
            check(!drop.targeted, "Leaving the conversation removes the attachment highlight")
            check(drop.drop(from: dropBoard, at: conversationPoint), "Dropping a file uses the existing attachment handler")
            await settle()
            check(model.attachments == [file, secondFile] && model.draft == "드롭 전 확인" && posted == 0, "A file drop attaches without replacing the draft or sending")
            guard let draftRect = chat.smokeFrames["slack-draft"] else { check(false, "The drop editor frame is measurable"); return }
            let draftPoint = host.convert(CGPoint(x: draftRect.midX, y: host.isFlipped ? draftRect.midY : host.bounds.height - draftRect.midY), to: nil)
            check(panel.contentView?.hitTest(draftPoint) !== drop, "The drop destination leaves normal editor clicks alone")
            dropBoard.clearContents(); dropBoard.setData(png, forType: .png)
            dashboard?.makeKeyAndOrderFront(nil)
            await settle()
            check(!panel.isKeyWindow, "The drop starts with an inactive conversation window")
            check(drop.drop(from: dropBoard, at: draftPoint), "An image drop over the TextField reaches the attachment handler without a key window")
            await settle()
            check(model.attachments.count == 3 && model.draft == "드롭 전 확인" && posted == 0 && panel.isKeyWindow && model.composerFocused,
                  "A TextField drop attaches the image, preserves the draft and restores focus")
            check(model.attachments.last.flatMap { try? Data(contentsOf: $0) }.flatMap(NSBitmapImageRep.init(data:))?.pixelsWide == 16,
                  "Dropped image is readable upload data")
            check(!drop.targeted, "Dropping removes the attachment highlight")
            dropBoard.clearContents(); dropBoard.setData(bitmap.tiffRepresentation!, forType: .tiff)
            check(drop.drop(from: dropBoard, at: draftPoint) && model.attachments.count == 4 && posted == 0,
                  "Dropped TIFF images use the same PNG conversion without sending")
            dropBoard.clearContents(); dropBoard.writeObjects([folder as NSURL])
            check(drop.drop(from: dropBoard, at: conversationPoint) && model.attachments.count == 4 && model.notice != nil,
                  "Dropped folders are rejected by the shared validator with an explanation")
            model.notice = nil
            let selected = model.selected
            dropBoard.clearContents(); dropBoard.writeObjects([file as NSURL])
            if IMessageFeature.enabled {
                model.source = .imessage
                check(drop.updateDrag(from: dropBoard, at: conversationPoint).isEmpty && !drop.targeted && !drop.drop(from: dropBoard, at: conversationPoint),
                      "The iMessage side refuses attachments and has no highlight")
            }
            model.source = .slack; model.selected = nil
            check(!drop.drop(from: dropBoard, at: conversationPoint) && !drop.targeted, "No destination room refuses a drop")
            model.selected = selected
            check(!drop.drop(from: dropBoard, at: drop.convert(CGPoint(x: -10, y: 40), to: nil)) && !drop.targeted,
                  "The tab strip is outside the attachment drop area")
            check(!drop.drop(from: dropBoard, at: drop.convert(CGPoint(x: drop.bounds.maxX + 10, y: 40), to: nil)),
                  "The web pane is outside the attachment drop area")
            dropBoard.clearContents(); dropBoard.setString("일반 텍스트", forType: .string)
            check(!drop.drop(from: dropBoard, at: draftPoint) && !drop.targeted, "Ordinary text dragging stays with the editor")
            dropBoard.clearContents(); dropBoard.setString("합성 약속 파일", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
            check(!drop.drop(from: dropBoard, at: conversationPoint), "File promises are outside attachment dropping")
            model.send()
            check(posted == 1 && sentFiles.count == 4 && sentFiles.contains(file) && sentFiles.contains(secondFile) && model.attachments.isEmpty,
                  "Dropped files reach only the existing synthetic send callback")
            let note = "PASS: desktop pet position across open/close, size control and animations; automatic reply for text and file posts, thinking ignored, explicit choice/draft/other room protected; DDots real Command-V file/PNG/TIFF, Korean shortcut, text fallback, detach, folder rejection, synthetic send callback; multiple file/PNG/TIFF dropping on conversation/editor, inactive-window focus, drop highlight/exit, folder/source/room/bounds rejection, text/file-promise fallback\n"
            try! note.write(to: destination.appendingPathComponent("composer.txt"), atomically: true, encoding: .utf8)
            print(note)
            restoreBoard(); model.draft = draft; model.attachments = attachments; model.onSend = send
            verifySlackInput(destination: destination, then: finish)
        }
    }
}
