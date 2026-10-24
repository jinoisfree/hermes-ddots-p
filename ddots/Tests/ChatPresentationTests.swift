import AppKit
@main struct ChatPresentationTests {
    static func main() {
        let model = ChatModel()
        model.measureReply("height-test", height: 100)
        model.toggleReply("height-test"); model.measureReply("height-test", height: 450)
        precondition(model.replyExtraHeight == 350, "Expansion uses measured height difference")
        model.toggleReply("height-test")
        precondition(model.replyExtraHeight == 0, "Collapse restores baseline")
        model.measureReply("height-test", height: 100); model.toggleReply("height-test")
        model.measureReply("height-test", height: 450); model.acceptManualReplySize()
        precondition(model.replyExtraHeight == 0, "Manual resize cancels automatic addition")
        model.toggleReply("height-test")
        precondition(model.replyExtraHeight == 0, "Collapse respects manual size")
        model.viewportWidth = 600
        precondition(abs(model.bubbleWidth-492) < 0.001)
        model.viewportWidth = 250
        precondition(model.bubbleWidth == 240)
        model.viewportWidth = PetLayout.expandedSize.width
        let rows = (1...120).map { ChatMessage(id:"default:\($0)",fromUser:false,speaker:"Hermes",body:"본문 \($0)",date:Date(timeIntervalSince1970:Double($0)),sessionID:"a") }
        model.receive(rows,session:"a")
        precondition(model.messages.count == 40 && model.messages.first?.rowID == 81)
        precondition(!model.didInitialScroll,"Hidden/preloaded messages never consume initial scroll")
        model.expanded = true; model.didInitialScroll = true; model.nearBottom = false
        let revision = model.scrollRevision
        let added = rows + [ChatMessage(id:"default:121",fromUser:false,speaker:"Hermes",body:"새 답",date:Date(timeIntervalSince1970:121))]
        model.receive(added,session:"a")
        precondition(model.scrollRevision == revision,"Reading older text never auto-scrolls on new replies")
        model.nearBottom = true
        model.receive(added + [ChatMessage(id:"default:122",fromUser:false,speaker:"Hermes",body:"다음 답",date:Date(timeIntervalSince1970:122))],session:"a")
        precondition(model.scrollRevision > revision && model.scrollTarget == "chat-bottom")
        model.draft = "검색 중에도 유지"
        model.previousPage(Array(rows[40..<80]))
        precondition(model.messages.count == 80)
        model.resetPage()
        precondition(model.messages.count == 40 && model.draft == "검색 중에도 유지")
        model.showContext(Array(rows[10...50]),target:"default:31")
        precondition(model.historical && model.highlightedID == "default:31" && model.messages.count == 41)
        model.receive(added,session:"a")
        precondition(model.messages.first?.rowID == 11,"Polling cannot replace historical search context")
        model.receive(added,session:"b")
        precondition(!model.historical && model.messages.count == 40,"A new session refreshes the recent page")
        let original = rows[0]
        let first = model.presentation(original)
        var edited = original; edited.body = "**수정됨**"
        let second = model.presentation(edited)
        precondition(String(first.0.characters) != String(second.0.characters) && String(second.0.characters) == "수정됨")
        let now = Date()
        let event = CalendarEntry(identifier: "fixture", calendarID: "test", title: "설계 검토", start: now, end: now.addingTimeInterval(3600))
        let reply = ChatMessage(id: "calendar:1", fromUser: false, speaker: "위키담당", body: "설계 검토 준비해 줘", date: now)
        precondition(model.presentation(reply).1.isEmpty)
        model.calendarEvents = [event]
        precondition(model.presentation(reply).1.first?.kind == .showCalendar([event]), "arrival of events invalidates action results, regardless of character")
        model.calendarEvents = []
        precondition(model.presentation(reply).1.isEmpty, "revoked permission or deleted event removes cached buttons")
        var own = reply; own.fromUser = true; model.calendarEvents = [event]
        precondition(model.presentation(own).1.isEmpty, "own messages never get actions, even with the same cached body")
        model.openSearch(); model.escape()
        precondition(!model.searchOpen && model.draft == "검색 중에도 유지")
        model.messages = [
            ChatMessage(id:"a:1",fromUser:false,speaker:"같은 이름",body:"첫 답",date:Date()),
            ChatMessage(id:"a:2",fromUser:false,speaker:"같은 이름",body:"이어진 답",date:Date()),
            ChatMessage(id:"b:1",fromUser:false,speaker:"같은 이름",body:"다른 프로필",date:Date()),
            ChatMessage(id:"b:2",fromUser:true,speaker:"",body:"내 말",date:Date())
        ]
        precondition(model.rows.map(\.showsSpeaker) == [true,false,true,false], "Avatar/name belongs only to the first reply of a profile, never the user")
        let longBody = (1...15).map { "**굵은 줄 \($0)**와 [링크](https://example.com)" }.joined(separator:"\n")
        let longReply = ChatMessage(id:"long:1",fromUser:false,speaker:"위키담당",body:longBody,date:Date(),profile:"default")
        let shortText = model.displayedText(longReply)
        precondition(shortText.characters.split(separator:"\n").count <= 12)
        precondition(shortText.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "folded preview retains bold spans")
        precondition(shortText.runs.contains { $0.link != nil }, "folded preview retains complete links")
        model.toggleReply(longReply.id)
        precondition(model.displayedText(longReply).characters.count > shortText.characters.count)
        model.expanded = false; model.expanded = true; model.resetPage()
        precondition(model.expandedReplies.contains(longReply.id), "window folding preserves reply expansion")
        model.toggleReply(longReply.id)
        model.query = "굵은 줄 15"
        model.showContext([longReply],target:longReply.id)
        precondition(model.expandedReplies.contains(longReply.id) && String(model.displayedText(longReply).characters).contains("굵은 줄 15"), "search expands hidden matching content")
        precondition(model.displayedText(longReply).runs.contains { $0.backgroundColor != nil }, "search highlights the matched phrase")
        precondition(model.searchSegments(longReply,text:model.displayedText(longReply))?.contains { $0.match && String($0.text.characters).contains("굵은 줄 15") } == true, "matching paragraph gets a dedicated scroll anchor")
        // Cache keys must follow edits, sender changes, folding and transient search highlighting.
        model.highlightedID = nil
        precondition(!model.displayedText(longReply).runs.contains { $0.backgroundColor != nil }, "Clearing highlight invalidates cached display")
        model.expandedReplies.remove(longReply.id)
        let cachedPreview = model.displayedText(longReply)
        precondition(cachedPreview == model.displayedText(longReply), "Repeated display is stable")
        var ownLong = longReply; ownLong.fromUser = true
        precondition(model.displayedText(ownLong).characters.count > cachedPreview.characters.count, "Sender changes bypass folding for own text")
        var shortEdit = longReply; shortEdit.body = "수정한 짧은 글"
        precondition(!model.needsFolding(shortEdit) && String(model.displayedText(shortEdit).characters) == shortEdit.body, "Same-ID edit invalidates fold and display caches")
        precondition(model.needsFolding(longReply) && model.displayedText(longReply) == cachedPreview, "Restoring the body restores the folded preview")
        precondition(ChatModel().expandedReplies.isEmpty, "reply expansions are only in memory")
        let entry = ChatModel()
        entry.receive(rows); entry.expanded = true; entry.didInitialScroll = true
        entry.draft = "다시 열어도 남는 글"; entry.expandedReplies.insert(longReply.id)
        entry.showContext(Array(rows[10...50]), target: "default:31")
        entry.nearBottom = false
        let beforeEntry = entry.scrollRevision
        entry.enterLatest()
        precondition(entry.entryViewportActive && entry.entryViewportPending,
                     "A latest entry waits for real layout before exposing the viewport")
        precondition(!entry.historical && entry.messages.count == 40 && entry.messages.last?.id == rows.last?.id,
                     "Reopening leaves historical context for the recent page")
        precondition(entry.scrollRevision > beforeEntry && entry.scrollTarget == "chat-bottom" && entry.nearBottom,
                     "Every entry requests the newest line even after reading older text")
        precondition(entry.draft == "다시 열어도 남는 글" && entry.expandedReplies.contains(longReply.id),
                     "Entry preserves the draft and expanded replies")
        let reentered = entry.scrollRevision
        entry.enterLatest()
        precondition(entry.scrollRevision > reentered, "Rapid reopening replaces the previous scroll request")
        let delayed = entry.scrollRevision
        entry.receive(added)
        precondition(entry.scrollRevision > delayed && entry.scrollTarget == "chat-bottom", "A late newest line still follows entry")
        entry.userScrollGeneration += 1; entry.nearBottom = false
        precondition(!entry.entryViewportActive && !entry.entryViewportPending,
                     "Manual scrolling releases entry layout ownership")
        let manual = entry.scrollRevision
        entry.receive(added + [ChatMessage(id:"default:122",fromUser:false,speaker:"위키담당",body:"늦은 답",date:Date())])
        precondition(entry.scrollRevision == manual, "Reading elsewhere cancels following after entry")
        entry.enterLatest()
        entry.showContext(Array(rows[10...50]), target: "default:31")
        precondition(!entry.entryViewportActive && entry.prepareEntryViewport(), "Search context releases entry layout ownership")
        let explicit = entry.scrollRevision
        entry.receive(added)
        precondition(entry.historical && entry.scrollTarget == "default:31" && entry.scrollRevision == explicit,
                     "A search target after entry wins over late messages")
        let emptyEntry = ChatModel()
        emptyEntry.expanded = true; emptyEntry.didInitialScroll = true; emptyEntry.nearBottom = false
        emptyEntry.enterLatest()
        let emptyRevision = emptyEntry.scrollRevision
        emptyEntry.receive(rows)
        precondition(emptyEntry.scrollRevision > emptyRevision && emptyEntry.scrollTarget == "chat-bottom",
                     "Reopening an empty page follows its first delayed messages")
        let viewport = ChatModel()
        viewport.receive(rows); viewport.expanded = true
        let native = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        viewport.scrollView = native
        viewport.enterLatest()
        precondition(native.alphaValue == 0 && !viewport.prepareEntryViewport(), "Unlaid-out entry is hidden, with no elapsed-time deadline")
        viewport.userScrollGeneration += 1
        precondition(native.alphaValue == 1 && !viewport.entryViewportActive, "User input immediately restores a waiting viewport")
        viewport.enterLatest(); viewport.requestScroll("default:31")
        precondition(native.alphaValue == 1 && !viewport.entryViewportActive, "An explicit target restores entry visibility")
        viewport.enterLatest(); viewport.historical = true
        precondition(native.alphaValue == 1 && !viewport.entryViewportActive, "Historical context restores entry visibility")
        viewport.historical = false; viewport.enterLatest(); viewport.expanded = false
        precondition(native.alphaValue == 1 && !viewport.entryViewportActive, "Folding releases a hidden entry")
        viewport.expanded = true; viewport.enterLatest()
        precondition(viewport.takeEntryProxyRequest() && !viewport.takeEntryProxyRequest(), "Entry realizes the lazy bottom only once per request")
        viewport.requestScroll("chat-bottom")
        precondition(viewport.takeEntryProxyRequest(), "A genuinely newer bottom request can realize new rows")
        viewport.beginEntryViewport(hideUntilReady: false)
        viewport.entryViewportChanged(from: CGRect(x: 0, y: 100, width: 300, height: 200),
                                      to: CGRect(x: 0, y: 60, width: 300, height: 200))
        precondition(viewport.entryViewportActive && native.alphaValue == 1,
                     "A lazy layout origin correction is not mistaken for user input")
        viewport.userScrollGeneration += 1
        precondition(!viewport.entryViewportActive, "Actual wheel, scrollbar or keyboard input releases entry ownership")
        print("PASS: layout-based entry visibility, manual/search/fold cancellation and one lazy realization per request")
        print("PASS: reopening latest, rapid reopening, late data, manual scroll cancellation, explicit target precedence and draft retention")
        print("PASS: 40-row presentation, bottom-only following, page reset, context retention, session refresh, formatting invalidation, draft retention")
    }
}
