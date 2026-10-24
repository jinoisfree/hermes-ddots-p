import AppKit
import SwiftUI

extension AppDelegate {
    @MainActor func verifyNativeTextCard(destination: URL) async {
        func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType:type).map { (type,$0) } } }
        defer {
            board.clearContents()
            board.writeObjects(saved.map { pairs in let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1,forType:$0.0) }; return item })
        }
        let isolated = SlackModel(), chat = ChatModel()
        let view = ChatView(model:chat,slack:isolated,web:WebPaneModel())
        let message = ChatMessage(id:"slack:CHUB:1800000000",fromUser:false,speaker:"개인비서",
            body:"- [ ] 합성 확인\n합성 글 [문서](https://example.invalid/native)\n" + String(repeating:"긴 문장과 검색어 확인\n",count:45),date:Date(timeIntervalSince1970:1800000000),sessionID:"1800000000",profile:"personal-secretary")
        let thread = SlackThread(id:message.id,room:"CHUB",ts:"1800000000",root:message,replies:[],replyCount:0,loaded:true,latest:1800000000,latestFromUser:false)
        isolated.threads = [thread]
        // A change in another thread must not rebuild this row's input snapshot.
        var other = thread; other.id += "-other"; other.root.id += "-other"; other.ts += "1"
        isolated.threads = [thread, other]
        let wasNewPost = isolated.newPost
        isolated.newPost = true // Isolate picked state; changing an automatic reply target must invalidate its old row.
        func prepare() { isolated.prepareNativeInputs(chat: chat, dark: true, reduceMotion: true, vault: [nil,nil,nil]) }
        func cached(_ memo: SlackModel.ThreadRenderMemo) -> SlackThreadInputs {
            isolated.nativeInputs.inputs(memo) { isolated.rowInputs(memo, chat: chat, dark: true, reduceMotion: true, target: false) }
        }
        prepare(); isolated.renderedThreads.forEach { _ = cached($0) }
        isolated.picked = other.id; prepare(); ChatPerfProbe.counts = [:]
        _ = cached(isolated.renderedThreads[0])
        smokeCheck(ChatPerfProbe.counts["slack.inputs", default: 0] == 0, "Picking another thread preserves cached row inputs")
        let changed = cached(isolated.renderedThreads[1])
        smokeCheck(changed.picked && ChatPerfProbe.counts["slack.inputs", default: 0] == 1, "Picked thread alone recomputes its inputs")
        isolated.picked = nil; isolated.threads = [thread]; isolated.newPost = wasNewPost
        var symbols = ""
        for name in ["link", "doc.on.doc", "arrow.triangle.branch", "arrowshape.turn.up.left", "trash"] {
            let host = NSHostingView(rootView: Image(systemName: name).font(.system(size: ChatMetrics.auxiliaryFont, weight: .medium)).fixedSize())
            let native = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: ChatMetrics.auxiliaryFont, weight: .medium))
            symbols += "\(name) SwiftUI=\(host.fittingSize) native=\(String(describing: native?.size))\n"
        }
        try? symbols.write(to: destination.appendingPathComponent("symbol-sizes.txt"), atomically: true, encoding: .utf8)
        var opened: URL?
        chat.onOpenLink = { opened = $0 }
        let coordinator = NativeThreadList.Coordinator(model:isolated)
        let window = NSWindow(contentRect:NSRect(x:120,y:120,width:360,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        defer { coordinator.disconnect(); window.close() }
        window.contentView = coordinator.makeScroll(); window.makeKeyAndOrderFront(nil)
        func row() -> NativeThreadRow {
            let inputs = isolated.rowInputs(isolated.renderedThreads[0],chat:chat,dark:true,reduceMotion:true,target:false)
            return NativeThreadRow(id:thread.id,inputs:inputs,token:String(MessageChecklist.shared.revision),card:{view.nativeThreadContent(thread,inputs:inputs,target:false)},content:{AnyView(EmptyView())})
        }
        func update() { coordinator.update(rows:[row()],stamp:isolated.entryViewportStamp) }
        update(); await settle()
        guard let card = coordinator.table.view(atColumn:0,row:0,makeIfNecessary:true) as? NativeThreadCard, let text = card.firstText else { smokeFailed("A plain thread uses an AppKit thread cell") }
        func firstPost() -> NativeThreadCard.Post? { card.value?.placed.lazy.compactMap { if case .post(let post) = $0.piece { return post } else { return nil } }.first }
        let foldedHeight = coordinator.table.rect(ofRow:0).height
        smokeCheck(firstPost()?.foldTitle == "더 보기", "Long native text starts folded")
        let link = URL(string:"https://example.invalid/native")!
        _ = card.textView(text,clickedOnLink:link,at:0)
        smokeCheck(opened == link, "Native link delegate routes only to onOpenLink")
        firstPost()?.fold(); update(); await settle()
        let expandedHeight = coordinator.table.rect(ofRow:0).height
        smokeCheck(expandedHeight > foldedHeight+100, "Native expansion updates the actual table row height")
        firstPost()?.fold(); update(); await settle()
        smokeCheck(abs(coordinator.table.rect(ofRow:0).height-foldedHeight)<2, "Native folding restores the row height")
        window.makeFirstResponder(text)
        let expectedDrag = text.string
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        let start = text.convert(NSPoint(x:0,y:1),to:nil)
        let end = text.convert(NSPoint(x:text.bounds.maxX-1,y:text.bounds.maxY-1),to:nil)
        NSApp.postEvent(mouse(.leftMouseDown,start),atStart:false)
        for step in 1...8 {
            let t = CGFloat(step)/8
            NSApp.postEvent(mouse(.leftMouseDragged,NSPoint(x:start.x+(end.x-start.x)*t,y:start.y+(end.y-start.y)*t)),atStart:false)
        }
        NSApp.postEvent(mouse(.leftMouseUp,end),atStart:false)
        await settle()
        let selected = text.selectedRange()
        try? "selection=\(selected) expected=\(expectedDrag.utf16.count) responder=\(String(describing:window.firstResponder))\n".write(to:destination.appendingPathComponent("native-drag.txt"),atomically:true,encoding:.utf8)
        smokeCheck(selected.length == expectedDrag.utf16.count, "Mouse drag selects the displayed native body")
        let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"c",charactersIgnoringModifiers:"c",isARepeat:false,keyCode:8)!
        NSApp.sendEvent(key); await settle()
        smokeCheck(board.string(forType:.string) == expectedDrag, "Command-C copies the dragged native body")
        smokeCheck(isolated.picked == nil, "Text dragging does not pick the card")
        var checkbox: URL?
        text.textStorage?.enumerateAttribute(.link,in:NSRange(location:0,length:text.string.utf16.count)) { value,_,_ in
            if let url = value as? URL, url.scheme == "ddots-check" { checkbox = url }
        }
        smokeCheck(checkbox != nil, "Native checkbox has a toggle link")
        _ = card.textView(text,clickedOnLink:checkbox!,at:0)
        update(); await settle()
        smokeCheck(text.string.hasPrefix("☑"), "Native checkbox updates only local check state")
        smokeCheck(isolated.threads[0].root.body == message.body && opened == link, "Checkbox neither edits the message nor opens an external link")
        isolated.findHighlight = (thread.id,"검색어"); update(); await settle()
        var highlights = 0
        text.textStorage?.enumerateAttribute(.backgroundColor,in:NSRange(location:0,length:text.string.utf16.count)) { value,_,_ in if let color = value as? NSColor, color == NSColor(Color.yellow) { highlights += 1 } }
        smokeCheck(highlights > 0, "Native search uses visible yellow text attributes")
        let expected = text.string
        text.setSelectedRange(NSRange(location:0,length:expected.utf16.count))
        text.copy(nil)
        smokeCheck(NSPasteboard.general.string(forType:.string) == expected, "Native selected text copies its displayed body")
        card.value?.content.clickCard()
        smokeCheck(isolated.picked == thread.id, "Native card click picks its thread")
        try? "PASS: delegate link, fold heights=\(foldedHeight)/\(expandedHeight), highlights=\(highlights), selected text copy, pick\nMouse drag and Command-C event delivery, local checkbox toggle passed.\n".write(to:destination.appendingPathComponent("native-text.txt"),atomically:true,encoding:.utf8)
    }
}
