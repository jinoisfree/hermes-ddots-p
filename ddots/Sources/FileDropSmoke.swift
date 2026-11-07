import AppKit
import PDFKit
import CoreText
import Darwin

private final class FileDropSyntheticDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, window: NSWindow, location: NSPoint) { draggingPasteboard = board; draggingDestinationWindow = window; draggingLocation = location }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private final class FileDropSyntheticPromise: FileDropPromise {
    let fileNames = ["합성 첨부.txt"]
    func receive(at destination: URL, queue: OperationQueue, completion: @escaping (URL, Error?) -> Void) {
        queue.addOperation {
            let file = destination.appendingPathComponent(self.fileNames[0])
            do { try Data("합성 promise 내용".utf8).write(to: file); completion(file, nil) }
            catch { completion(file, error) }
        }
    }
}

extension AppDelegate {
    /// Actual app/card execution with synthetic inputs and engine/Slack transport doubles only.
    @MainActor func verifyFileDrop(destination: URL) async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-file-drop-smoke-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        SmokeLeftovers.note(base)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        var log: [String] = []
        func check(_ condition: Bool, _ name: String) {
            log.append((condition ? "PASS " : "FAIL ") + name)
            try! (log.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("file-drop-checks.txt"), atomically: true, encoding: .utf8)
            if !condition { capture(destination: destination.appendingPathComponent("failure")); smokeFailed(name) }
        }
        func pause(_ seconds: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); pet.layoutSubtreeIfNeeded() }
        func until(_ name: String, _ condition: () -> Bool) async {
            for _ in 0..<100 { if condition() { return }; await pause(0.03) }; check(false, name)
        }
        func file(_ name: String, _ text: String = "합성 업무 자료") -> URL {
            let file = base.appendingPathComponent(name); try! text.write(to: file, atomically: true, encoding: .utf8); return file
        }
        func put(_ urls: [URL]) { board.clearContents(); board.writeObjects(urls as [NSURL]) }
        func text(_ value: String) { board.clearContents(); board.setString(value, forType: .string) }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], chars: String = "") {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            if !panel.performKeyEquivalent(with: event) { panel.sendEvent(event) }
        }
        collapseChat(); pet.previewRow = nil; pet.previewLook = false
        let card = fileDrop
        card.pasteboard = { board }
        let syntheticCast = FileDropCast(members: ["work-x", "home-y", "doc-z"], roles: ["work-x": ["work"], "home-y": ["personal"], "doc-z": ["doctor"]], fallback: "work-x")
        card.cast = { syntheticCast }
        card.enabled = true
        var engineCalls = 0
        card.engine = { _, _ in engineCalls += 1; try await Task.sleep(nanoseconds: 3_000_000_000); throw CocoaError(.featureUnsupported) }
        let note = file("문서.pdf")
        put([note]); let folded = bubbleSize
        let head = pet.atlas.interactionRect(in: pet.spriteRect)
        let drag = FileDropSyntheticDrag(board: board, window: panel, location: pet.convert(CGPoint(x: head.maxX + 200, y: head.midY), to: nil))
        let dragScreen = panel.convertPoint(toScreen: drag.draggingLocation)
        check(pet.draggingEntered(drag) == .copy, "AC-01 AppKit destination accepts synthetic draggingInfo")
        await pause()
        check(card.visible && card.dragging && card.count == 1 && bubbleSize.width > folded.width && bubbleSize.height > folded.height, "AC-01 live card expands with count")
        capture(destination: destination.appendingPathComponent("drag"))
        check(pet.fileDropPointer == dragScreen && pet.animationFrame == PetAnimationFrame(row: 9, column: 4), "AC-01 fixed right-hand drag cursor selects the existing rightward look frame")
        pet.draggingExited(drag); check(!card.visible, "REQ-FD-02 leaving folds empty card")
        put([base]); check(pet.draggingEntered(drag) == [] && !card.visible, "AC-03 folder-only drag returns no operation")
        put([note]); let start = ProcessInfo.processInfo.systemUptime
        card.receive(board)
        check(ProcessInfo.processInfo.systemUptime - start < 0.1 && card.proposals.count == 3 && engineCalls == 0, "AC-04 immediate three proposals before any engine call")
        await pause(); capture(destination: destination.appendingPathComponent("card"))
        check(card.proposals.map(\.id) == ["summarize", "extract_todos", "explain"], "AC-04 fallback proposal order; auto and opinion are fixed UI controls")
        let initialSelect = card.onSelect
        var defaultAction: String?
        card.onSelect = { defaultAction = $0.id; return true }
        key(36, chars: "\r"); await pause()
        check(defaultAction == card.proposals.first?.id, "V-7 Return selects the first proposal only")
        card.onSelect = initialSelect
        card.close()

        text("합성 일반 자료"); card.engine = { _, _ in throw FileDropServiceError.unavailable }; card.receive(board)
        await until("Claude failure origin", { card.origin == "기본 제안이에요 · Claude 연결 실패" })
        check(card.proposals.count == 3 && card.origin == "기본 제안이에요 · Claude 연결 실패", "AC-11 failed Claude boundary keeps fallback and states why on the status line")
        card.close(); card.engine = { _, _ in throw FileDropServiceError.notConnected }; text("합성 연결 없음"); card.receive(board)
        await until("not connected origin", { card.origin == "기본 제안이에요 · 맥미니에 연결되지 않았어요" })
        check(card.proposals.count == 3 && card.status.isEmpty && !card.origin.contains("맥 AI"), "AC-09 no link to the Mac mini keeps the default proposals and says why")
        card.close()
        // V-23 / AC-61: the status line names where the shown proposals came from.
        var answers: [Bool] = []
        card.onAnswer = { _, failed in answers.append(failed) }
        card.engine = { _, _ in FileDropAnswer(suggestions: [.init(id: "explain", label: "무슨 내용인지 설명", profile: "home-y")], summary: "합성 요약") }
        text("합성 출처 글"); card.receive(board)
        await until("claude origin", { card.origin == "Claude가 읽고 골랐어요" })
        check(card.proposals.first?.id == "explain" && card.proposals.first?.profile == "home-y" && answers == [false], "AC-61 Claude answer shows its own origin and proposals")
        card.close()
        card.engine = { _, _ in FileDropAnswer(suggestions: [.init(id: "summarize", label: "세 줄 요약", profile: "outsider-q")]) }
        text("합성 출처 글"); card.receive(board)
        await until("unmatched origin", { card.origin == FileDropCard.basic("담당을 맞추지 못했어요") })
        check(answers == [false, true] && card.proposals.count == 3 && card.proposals.allSatisfy { $0.profile != "outsider-q" }, "AC-61 answer discarded by the cast check counts as a failure with the default proposals")
        card.close(); card.onAnswer = nil
        let html = FileDropSignals.htmlText("<html><head><title>t</title><style>.a{color:red}</style></head><body><script>var secret=1;</script><h1>월별 분석</h1><table><tr><td>1월</td><td>120</td></tr></table><!-- c --><p>합계&nbsp;&amp;&nbsp;평균</p></body></html>")
        check(html.contains("월별 분석") && html.contains("1월 | 120") && html.contains("합계 & 평균") && !html.contains("secret") && !html.contains("color") && !html.contains("<"), "AC-57 html keeps the body text and drops tags, script and style")
        let htmlFile = file("EDI_월별분석.html", "<html><body><script>var x=1</script><table><tr><td>견적</td><td>1,180만원</td></tr></table></body></html>")
        let euc = base.appendingPathComponent("옛글.txt")
        try! Data([0xB0, 0xA1, 0xB3, 0xAA]).write(to: euc)
        let readHTML = FileDropSignals.read(.init(files: [htmlFile, euc]), initial: .initial(.init(files: [htmlFile, euc])))
        check(!readHTML.partial && readHTML.content.contains("견적 | 1,180만원") && readHTML.content.contains("가나") && !readHTML.content.contains("var x"), "AC-57 html and EUC-KR text are read completely")
        card.engine = { _, _ in engineCalls += 1; try await Task.sleep(nanoseconds: 3_000_000_000); throw CocoaError(.featureUnsupported) }
        let resolver = card.intake.promises
        text("합성 promise"); card.intake.promises = { _ in [FileDropSyntheticPromise()] }
        card.receive(board)
        await until("AC-06 delivered promise", { card.payload.files.first?.lastPathComponent == "합성 첨부.txt" })
        let promised = card.payload.files[0]
        check(FileManager.default.fileExists(atPath: promised.path), "AC-06 promise is materialized in card temporary area")
        card.close(); card.intake.promises = resolver
        check(!FileManager.default.fileExists(atPath: promised.path), "AC-06 closing removes promised temporary copy")
        var files = (0..<11).map { file("합성-\($0).txt") }
        let large = file("큰파일.dat", "")
        let handle = try! FileHandle(forWritingTo: large); try! handle.truncate(atOffset: 201 * 1024 * 1024); try! handle.close()
        files.insert(large, at: 0); put(files); card.receive(board)
        check(card.payload.files.count == 10 && !card.payload.files.contains(large) && card.notice.contains("200MB") && card.notice.contains("10개"), "AC-05 size and count exclusions both reported")
        card.close(); text("합성 글"); card.receive(board)
        check(card.proposals.contains { $0.id == "summarize" }, "AC-07 text proposes summary")
        card.close(); text("https://example.invalid/synthetic"); card.receive(board)
        check(card.proposals.contains { $0.id == "summarize" }, "AC-07 link proposes summary")
        card.cast = { FileDropCast(members: ["lead-q", "doc-z"], roles: ["doc-z": ["doctor"]], fallback: "") }; card.analyze()
        check(card.primaryProfile == "lead-q" && card.proposals.allSatisfy { $0.profile == "lead-q" || $0.profile == "app" }, "REQ-FD-20 with no stored roles the first agent leads, never a non-work agent")
        card.cast = { syntheticCast }; card.analyze()
        let invalid = [FileDropSuggestion(id: "erase", label: "삭제", profile: "work-x"), .init(id: "explain", label: "설명", profile: "missing"), .init(id: "compare", label: "", profile: "work-x")]
        let merged = FileDropRules.merge(invalid, signals: card.signals, fallback: card.proposals, profiles: syntheticCast.candidates)
        check(merged == card.proposals, "AC-08 invalid id/profile/empty label are rejected and filled")
        let longEnglish = "sqlite database is locked while waiting for transaction"
        let longKorean = "회사 자료를 함께 읽고 요청 사항을 정리해서 알려주기!"
        let longWord = "abcdefghijklmnopqrstuvwxyzabcdef"
        let longItems = [longEnglish, longKorean, longWord].enumerated().map { index, label in
            FileDropSuggestion(id: ["summarize", "compare", "explain"][index], label: label, profile: "work-x")
        }
        let shortened = FileDropRules.merge(longItems, signals: card.signals, fallback: [], profiles: syntheticCast.candidates)
        check(shortened.count == 3 && shortened.allSatisfy { $0.label.count <= 24 && $0.label.hasSuffix("…") } && shortened[0].label == "sqlite database is…" && shortened[2].label == "…", "AC-48 merge shortens Korean and English at word boundaries")
        var workSignals = card.signals; workSignals.works = []
        let attached = [FileDropSuggestion(id: "attach_work", label: "장비 구매에 붙이기", profile: "work-x"), .init(id: "attach_work", label: "납품 점검에 붙이기", profile: "work-x")]
        let withoutWork = FileDropRules.merge(attached, signals: workSignals, fallback: card.proposals, profiles: syntheticCast.candidates)
        workSignals.works = ["납품 점검"]
        let withWork = FileDropRules.merge(attached, signals: workSignals, fallback: card.proposals, profiles: syntheticCast.candidates)
        check(withoutWork == card.proposals && withWork.count == 3 && withWork.first?.label == "납품 점검에 붙이기", "AC-49 rejects absent or invented works and fills fallback")
        workSignals.agentRoles = ["work-x": ["work"], "home-y": ["personal"], "doc-z": ["doctor"]]
        workSignals.today = "2026-11-07(토)"
        let fixedNow = ISO8601DateFormatter().date(from: "2026-11-06T16:00:00Z")!
        check(FileDropSignals.localToday(now: fixedNow, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!) == "2026-11-07(토)" && FileDropSignals.localToday(now: fixedNow, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!) == "2026-11-06(금)", "AC-53 local date uses the device timezone and Korean weekday")
        let retired = [FileDropSuggestion(id: "summarize", label: "요약", profile: "doc-z"), .init(id: "diagnose", label: "진단", profile: "work-x")]
        var oldSignals = workSignals; oldSignals.profile = "doc-z"; oldSignals.content = "error crash sync.log 오류"
        let oldFallback = FileDropRules.rules(oldSignals, cast: syntheticCast)
        check(FileDropRules.merge(retired, signals: oldSignals, fallback: oldFallback, profiles: syntheticCast.candidates) == oldFallback && oldFallback.count == 3 && oldFallback.allSatisfy { $0.profile == "work-x" && $0.id != "diagnose" } && syntheticCast.profile(role: FileDropSignals.role(oldSignals.hint)) == "work-x", "AC-52 retired agent and diagnose rejected; log hint and fallback use work agent")
        let allowedNumbers = ["견적번호 202611-3000123", "주문번호 2026110712345678", "990231-1234567", "000229-1234567", "900101-9234567", "4111 1111 1111 1112", "41111111111111111111"]
        let secretNumbers = ["900101-1234567", "000229-3234567", "4111 1111 1111 1111", "378282246310005", "xoxb-", "sk-SYNTHETIC", "AKIASYNTHETIC", "ghp_SYNTHETIC", "-----BEGIN", "비밀번호: x", "PASSWORD: x"]
        check(allowedNumbers.allSatisfy { !FileDropSignals.secret($0) } && secretNumbers.allSatisfy(FileDropSignals.secret), "AC-54 valid birth dates and Luhn cards block; order IDs pass; credentials still block")
        let firstInstruction = "자료를 자세히 읽고 요청한 결과를 정리한 다음 회사 폴더에 보관하기"
        let secondInstruction = "자료를 자세히 읽고 요청한 결과를 정리한 다음 사용자에게 설명하기"
        var customSignals = workSignals; customSignals.custom = [firstInstruction, secondInstruction]
        let customItem = FileDropSuggestion(id: "custom_instruction", label: FileDropRules.shortLabel(secondInstruction), profile: "work-x", instruction: secondInstruction)
        let customMerged = FileDropRules.merge([customItem], signals: customSignals, fallback: [], profiles: syntheticCast.candidates)
        check(FileDropRules.shortLabel(firstInstruction) == customItem.label && customMerged.first?.instruction == secondInstruction, "AC-48 equal shortened custom labels retain the exact approved instruction")
        let validAnswer = FileDropAnswer(suggestions: [.init(id: "summarize", label: "대상 요약", profile: "work-x")], summary: "합성 } 안쪽 따옴표 \" 보존")
        let validJSON = String(decoding: try! JSONEncoder().encode(validAnswer), as: UTF8.self)
        card.close()
        card.engine = { _, _ in try FileDropRules.parseAnswer("안내\n```json\n" + validJSON + "\n```\n참고: TAIL_CANARY") }
        text("합성 JSON 응답"); card.receive(board)
        await until("JSON object response", { card.status.isEmpty && card.summary == validAnswer.summary })
        let renderedState = card.summary + card.notice + card.status + card.proposals.map(\.label).joined()
        check(card.proposals.first?.label == "대상 요약" && !renderedState.contains("TAIL_CANARY"), "AC-50 first JSON object is used and extra prose is absent from card state")
        card.close(); card.engine = { _, _ in try FileDropRules.parseAnswer("참고: TAIL_CANARY") }
        text("합성 JSON 없는 응답"); card.receive(board)
        await until("missing JSON fallback", { card.status.isEmpty })
        check(card.proposals == FileDropRules.rules(card.signals, cast: syntheticCast) && card.notice.isEmpty, "AC-50 missing JSON fails and retains fallback without prose")
        let scopeItems = [FileDropSuggestion(id: "add_schedule", label: "식약처 서류 일정", profile: "work-x"), .init(id: "add_schedule", label: "어린이집 상담 일정", profile: "home-y")]
        let scoped = FileDropRules.merge(scopeItems, signals: card.signals, fallback: card.proposals, profiles: syntheticCast.candidates)
        card.proposals = scoped
        check(scoped.count == 3 && scoped[0].profile == "work-x" && scoped[1].profile == "home-y" && scoped[0].id == scoped[1].id, "AC-51 same action survives for separate company and personal scopes")
        await pause(); capture(destination: destination.appendingPathComponent("mixed-scopes"))
        card.close(); text("맨 앞 내용\n두 번째 쪽 " + "xoxb-" + "SYNTHETIC-NOT-A-SECRET")
        let beforeSecret = engineCalls; card.receive(board)
        await until("secret check", { card.sensitive })
        check(engineCalls == beforeSecret && card.notice == "비밀처럼 보여 밖으로 보내지 않았어요", "AC-13 secret in later content blocks engine boundary")
        card.close()
        card.engine = { _, _ in engineCalls += 1; return FileDropAnswer(suggestions: [], confidence: 0.3, works: ["합성 업무"]) }
        text("합성 업무 자료"); card.receive(board)
        await until("confirmation", { card.confirmation != nil })
        check(card.confirmation == "합성 업무", "AC-14 low confidence asks about single work")
        card.confirmation = nil
        let beforeOpinion = engineCalls
        var opinion: FileDropSuggestion?
        let select = card.onSelect; card.onSelect = { opinion = $0; return true }
        card.choose(.init(id: "opinion", label: "의견", profile: "work-x")); await pause()
        check(card.editing && panel.firstResponder is NSTextView, "AC-15 opinion editor has keyboard focus")
        card.draft = "견적 비교"; card.submit()
        check(opinion?.id == "opinion" && opinion?.label == "견적 비교" && engineCalls == beforeOpinion, "AC-15 opinion submits instruction without engine rerun")
        card.choose(.init(id: "opinion", label: "의견", profile: "work-x")); card.escape()
        check(!card.editing && card.visible, "AC-15 Escape folds only opinion editor")
        card.onSelect = select; card.close()
        card.openText(); await pause(); text("붙여넣은 합성 글"); key(9, flags: .command, chars: "v"); key(36, chars: "\r")
        check(card.payload.text == "붙여넣은 합성 글" && card.proposals.count == 3, "AC-34 text-only card uses its submitted text")
        card.close(); text("합성 비밀번호"); board.setData(Data(), forType: ClipboardPasteboard.concealed)
        let beforeConcealed = engineCalls
        card.openText(); await pause(); key(9, flags: .command, chars: "v")
        check(engineCalls == beforeConcealed && card.notice.contains("비밀번호") && (panel.firstResponder as? NSTextView)?.string == "", "AC-35 concealed CmdV refused before engine")
        card.close()

        // PDFKit reads both pages; the second page is the sole source of the deadline.
        let data = NSMutableData(), consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for content in ["합성 안내", "납품 마감 11월 20일"] {
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 40, y: 700)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            CTLineDraw(line, context); context.endPDFPage()
        }
        context.closePDF(); let pdf = base.appendingPathComponent("두쪽.pdf"); try! (data as Data).write(to: pdf)
        let secretData = NSMutableData(), secretConsumer = CGDataConsumer(data: secretData)!
        let secretContext = CGContext(consumer: secretConsumer, mediaBox: &box, nil)!
        for content in ["합성 일반 안내", "xoxb-" + "SYNTHETIC-ONLY-NOT-REAL"] {
            secretContext.beginPDFPage(nil); secretContext.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: [.font: NSFont.systemFont(ofSize: 18)])), secretContext)
            secretContext.endPDFPage()
        }
        secretContext.closePDF(); let secretPDF = base.appendingPathComponent("합성 두쪽.pdf"); try! (secretData as Data).write(to: secretPDF)
        let callsBeforePDF = engineCalls
        card.engine = { _, _ in engineCalls += 1; return FileDropAnswer(suggestions: []) }
        put([secretPDF]); card.receive(board)
        await until("second PDF page secret", { card.sensitive && card.notice.contains("밖으로 보내지") })
        check(engineCalls == callsBeforePDF, "AC-13 actual two-page synthetic PDF blocks engine before any request")
        await pause(0.6); capture(destination: destination.appendingPathComponent("design-secret"))
        check(pet.fileDropContentFits, "V-7 secret warning and actions stay inside glass")
        card.close()
        let payload = FileDropIntake.Payload(files: [pdf])
        let signals = FileDropSignals.read(payload, initial: .initial(payload))
        check(signals.content.contains("납품 마감 11월 20일"), "AC-32 both PDF pages reach the Claude engine input")
        let receipt = file("일반 문서.txt", "이것은 개인 영수증 자료입니다")
        let receiptPayload = FileDropIntake.Payload(files: [receipt])
        let receiptRead = FileDropSignals.read(receiptPayload, initial: .initial(receiptPayload))
        check(FileDropSignals.role(receiptRead.hint) == "personal" && syntheticCast.profile(role: FileDropSignals.role(receiptRead.hint)) == "home-y", "REQ-FD-20 content refines a generic filename to the personal role, and the cast resolves it to its personal agent")
        let origin = file("출처.txt")
        let metadata = try! PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/private/path?token=synthetic"], format: .binary, options: 0)
        let xattr = metadata.withUnsafeBytes { setxattr(origin.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, metadata.count, 0, 0) }
        check(xattr == 0 && FileDropSignals.originHosts(origin) == ["example.invalid"], "REQ-FD-06 synthetic WhereFroms metadata exposes host only")

        let watch = FileDropWatch(); watch.device = "synthetic-mac"
        var root = ChatMessage(id: "slack:HUB-A:100", fromUser: true, speaker: "나", body: "합성 맡김", date: Date())
        root.files = []
        var reply = ChatMessage(id: "slack:HUB-A:101", fromUser: false, speaker: "업무비서", body: "합성 답", date: Date())
        var thread = SlackThread(id: "HUB-A:100", room: "HUB-A", ts: "100", root: root, replies: [], replyCount: 1, loaded: true, latest: 101, latestFromUser: false)
        watch.assignments = [.init(room: "HUB-A", ts: "100", files: [], profile: "work-x", label: "세 줄 요약")]
        reply.hermesReplyState = .working; thread.replies = [reply]; watch.update([thread])
        check(watch.notices.isEmpty, "AC-42 working has no bubble")
        reply.hermesReplyState = .closed; thread.replies = [reply]; watch.update([thread]); watch.update([thread])
        check(watch.notices.count == 1 && watch.notices[0].state == .closed, "AC-42 closed is notified once")
        watch.notices = []; reply.hermesReplyState = .asking; thread.replies = [reply]; watch.update([thread])
        check(watch.notices.count == 1 && watch.notices[0].state == .asking, "AC-44 asking is notified once")
        watch.update([thread], now: Date().timeIntervalSince1970 + 49 * 3600)
        check(watch.assignments.isEmpty, "REQ-FD-24 watch expires after 48 hours")

        // Use the real send controller with its existing all-local Slack transport double.
        card.engine = { _, _ in throw CocoaError(.featureUnsupported) }
        let script = SlackSendScript(workspace: "https://file-drop.invalid/")
        let action = FileDropSuggestion(id: "summarize", label: "세 줄 요약", profile: "work-x")
        text("Slack 미연결 합성 글"); card.receive(board)
        performFileDrop(action)
        check(card.problem == "Slack 연결이 필요해요" && card.visible && card.payload.count == 1, "AC-18 disconnected retains card and payload")
        card.close()
        let promiseResolver = card.intake.promises
        text("결합 promise"); card.intake.promises = { _ in [FileDropSyntheticPromise()] }; card.receive(board)
        await until("disconnected promise", { !card.payload.files.isEmpty })
        let retainedPromise = card.payload.files[0]
        performFileDrop(action)
        check(card.problem == "Slack 연결이 필요해요" && card.visible && FileManager.default.fileExists(atPath: retainedPromise.path), "AC-18 disconnected handoff retains its actual promised file")
        card.close(); card.intake.promises = promiseResolver
        slack.persists = false; slack.store = SlackFileStore(root: base.appendingPathComponent("sent-files")); slack.smokeSends = true; slack.start(script.api)
        await until("fake Slack ready", { slack.connected && !slack.model.rooms.isEmpty })
        func faces(_ pins: [String] = ["CCOW"], hub: String? = "CTRUTH") {
            slack.model.ddotsMembers = [.init(profile: "work-x", name: "업무비서", room: "Doffice")]
            slack.model.members["Doffice"] = [.init(profile: "work-x", name: "업무비서", user: "Uoffice")]
            slack.model.members["CCOW"] = [.init(profile: "work-x", name: "업무비서", user: "Uoffice")]
            slack.model.members["CTRUTH"] = [.init(profile: "work-x", name: "업무비서", user: "Uoffice")]
            slack.model.pins = pins; slack.model.ddotsHub = hub
        }
        faces(); card.engine = { _, _ in try await Task.sleep(nanoseconds: 3_000_000_000); throw FileDropServiceError.unavailable }
        put([pdf]); card.receive(board)
        check(card.status == "업무비서가 읽는 중", "AC-40 Claude mode presents the assigned agent name [status=\(card.status), profile=\(card.primaryProfile), members=\(slack.model.ddotsMembers.map(\.profile).joined(separator: ","))]")
        let beforeSend = script.sent.count
        performFileDrop(action)
        await until("file handoff", { script.sent.count == beforeSend + 1 && !card.sending })
        let sent = script.sent.last!
        check(sent["channel_id"] == "CCOW" && sent["thread_ts"] == nil && sent["initial_comment"]?.hasPrefix("<@Uoffice> 📎 ddots 파일 맡김") == true && sent["initial_comment"]?.contains("지시: 세 줄 요약") == true && sent["files"]?.contains("두쪽.pdf") == true, "AC-16/41 fixed format, file, explicit mention and top pinned new post")
        card.close(); faces()
        card.engine = { _, _ in FileDropAnswer(suggestions: [], summary: "합성 업무", confidence: 0.3, works: ["합성 장비 구매"]) }
        put([pdf]); card.receive(board)
        await until("single work confirmation", { card.confirmation == "합성 장비 구매" })
        let beforeConfirm = script.sent.count
        card.onConfirm?(true)
        await until("confirmed work post", { script.sent.count == beforeConfirm + 1 && !card.sending })
        check(script.sent.last?["initial_comment"]?.contains("지시: 업무에 붙이기") == true && script.sent.last?["initial_comment"]?.contains("연결 업무 후보: 합성 장비 구매") == true && script.sent.last?["files"]?.contains("두쪽.pdf") == true, "AC-14 yes sends attach_work with the selected work and file")
        card.close(); faces()
        card.engine = { _, _ in engineCalls += 1; throw CocoaError(.featureUnsupported) }
        let beforeOpinionEngine = engineCalls
        put([pdf]); card.receive(board)
        await until("opinion analysis finished", { engineCalls == beforeOpinionEngine + 1 })
        card.choose(.init(id: "opinion", label: "의견", profile: "work-x")); await pause()
        (panel.firstResponder as? NSTextView)?.insertText("견적 비교", replacementRange: NSRange(location: NSNotFound, length: 0))
        let beforeOpinionPost = script.sent.count, opinionCalls = engineCalls
        key(36, chars: "\r")
        await until("opinion Return post", { script.sent.count == beforeOpinionPost + 1 && !card.sending })
        let opinionPost = script.sent.last?["initial_comment"] ?? ""
        check(opinionPost.hasPrefix("<@Uoffice> 📎 ddots 파일 맡김") && opinionPost.contains("지시: 견적 비교") && opinionPost.contains("출처:") && opinionPost.contains("연결 업무 후보:") && script.sent.last?["files"]?.contains("두쪽.pdf") == true && engineCalls == opinionCalls, "AC-15 real opinion Return sends the fixed handoff format and file without another analysis")
        card.close(); faces([], hub: "CTRUTH"); text("기본 채널 합성 글"); card.receive(board)
        let beforeHub = script.sent.count; performFileDrop(action)
        await until("hub handoff", { script.sent.count == beforeHub + 1 && !card.sending })
        check(script.sent.last?["channel"] == "CTRUTH" && script.sent.last?["thread_ts"] == nil, "AC-41 empty pins falls back to default channel")
        card.close(); faces([], hub: nil); text("채널 없음"); card.receive(board)
        let beforeMissing = script.sent.count; performFileDrop(action)
        check(script.sent.count == beforeMissing && card.problem == "맨 위에 고정한 채널이 필요해요", "AC-41 both channels missing refuses send")
        card.close(); faces(); slack.model.members["CCOW"] = [.init(profile: "doc-z", name: "진단담당", user: "UDOCTOR")]
        text("absent 합성 글"); card.receive(board); performFileDrop(action)
        check(script.sent.count == beforeMissing && card.problem.contains("이 채널에 없어요"), "REQ-FD-22 absent does not reroute")
        card.close(); faces(); slack.model.source = .slack; slack.model.show(room: "CCOW"); showChat(); await pause(0.4)
        put([pdf]); check(pet.draggingEntered(drag) == [] && !card.visible, "AC-02 expanded pet declines card")
        let attachment = AttachmentDropView(frame: pet.bounds); attachment.model = slack.model; pet.addSubview(attachment)
        check(attachment.drop(from: board, at: CGPoint(x: 20, y: 20)) && slack.model.attachments.contains(pdf), "AC-02 expanded conversation keeps attachment destination")
        attachment.removeFromSuperview(); slack.model.attachments = []
        if let existing = slack.fileDropThreads.first(where: { $0.room == "CCOW" }) {
            fileDropWatch.notices = [.init(assignment: "synthetic-open", thread: existing, profile: "work-x", label: "세 줄 요약", state: .closed)]
            collapseChat(); updatePet(); check(pet.headline.hasPrefix("🟢 ") && pet.headline.contains("끝냈어요"), "AC-42 real completion bubble with green status point")
            await pause(0.6); capture(destination: destination.appendingPathComponent("design-complete"))
            petClicked(count: 1); await pause(0.3)
            check(chatExpanded && slack.model.focusThread == existing.id && slack.model.open.contains(existing.id) && fileDropWatch.notices.isEmpty && (slack.localThreads[existing.room + ":" + existing.ts] ?? 0) >= existing.latest, "AC-43 clicking bubble expands, reveals and marks its thread read")
            collapseChat(); fileDropWatch.notices = [.init(assignment: "synthetic-ask", thread: existing, profile: "work-x", label: "세 줄 요약", state: .asking)]
            updatePet(); check(pet.headline.hasPrefix("🔴 ") && pet.headline.contains("물어봐요"), "AC-44 real question bubble with red status point")
            await pause(0.6); capture(destination: destination.appendingPathComponent("design-question"))
            petClicked(count: 1); check(slack.model.focusThread == existing.id, "AC-44 question bubble opens thread")
        } else { check(false, "AC-43 synthetic workspace thread exists") }
        collapseChat()
        // Combine the actual reader/card with a real local relay and an unencrypted route double.
        let relayServer = HermesRelayServer(home: base, token: String(repeating: "ab", count: 32), interval: 0.1, syncFolder: base.appendingPathComponent("relay-sync"), readUsage: { nil })
        var rawFiles = -1
        let relayLock = NSLock()
        relayServer.dropSuggest = { data in
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            relayLock.lock(); rawFiles = (request["files"] as? [String] ?? []).count; relayLock.unlock()
            return try JSONEncoder().encode(FileDropAnswer(suggestions: [], summary: "일부 내용"))
        }
        let relayPort = try! relayServer.start(host: "127.0.0.1", port: 0)
        let relayClient = RemoteHermes(host: "127.0.0.1", port: relayPort, token: String(repeating: "ab", count: 32), includeMessages: false)
        relayClient.dropOriginalsAllowed = { _ in false }; relayClient.start()
        await until("partial relay connected", { relayClient.supportsDrop })
        card.engine = { signals, files in try await FileDropClaude.request(signals, files: files, home: base, remote: relayClient) }
        let unknown = file("합성.hwp", "합성 형식")
        put([unknown]); card.receive(board)
        await until("partial relay returned", { card.status.isEmpty && card.signals.partial })
        let originalsSent = relayLock.withLock { rawFiles }
        check(originalsSent == 0 && card.notice == "내용을 다 읽지 못했어요" && card.proposals.count == 3, "AC-36 unencrypted original count zero and actual card keeps partial-reading notice")
        card.close(); relayClient.stop(); relayServer.stop()
        // AC-63: three synthetic mail files are read by the app itself; AC-64: the "didn't read it all" notice follows the Mac mini's answer.
        func mail(_ name: String, _ raw: Data) -> URL { let url = base.appendingPathComponent(name); try! raw.write(to: url); return url }
        func words(_ value: String) -> String { "=?UTF-8?B?" + Data(value.utf8).base64EncodedString() + "?=" }
        let koreanEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))
        let mailPlain = mail("메일1.eml", Data(("From: " + words("김합성") + " <kim\u{40}example.invalid>\r\nTo: lee\u{40}example.invalid\r\nDate: Fri, 06 Nov 2026 09:30:00 +0900\r\nSubject: " + words("납품 일정 확인") + "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n11월 20일까지 샘플 수량을 확정해 주세요.\r\n").utf8))
        var qp = Data("From: a\u{40}example.invalid\r\nSubject: ".utf8) + Data(words("견적").utf8) + Data("\r\nContent-Type: text/html; charset=\"euc-kr\"\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n".utf8)
        for byte in "<html><head><style>.a{color:red}</style></head><body><p>견적 <b>1,180만원</b></p><script>var x=1</script></body></html>".data(using: String.Encoding(rawValue: koreanEncoding))! { qp.append(contentsOf: byte >= 0x80 || byte == 0x3D ? Array(String(format: "=%02X", byte).utf8) : [byte]) }
        let mailHTML = mail("메일2.eml", qp)
        let canary = Data("ATTACHMENT-CONTENT-CANARY".utf8).base64EncodedString()
        let mailMulti = mail("메일3.eml", Data(("From: a\u{40}example.invalid\r\nSubject: s\r\nContent-Type: multipart/mixed; boundary=B\r\n\r\n--B\r\nContent-Type: multipart/alternative; boundary=A\r\n\r\n--A\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + Data("본문 평문".utf8).base64EncodedString() + "\r\n--A\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>HTML 본문</p>\r\n--A--\r\n--B\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename*=UTF-8''%EA%B2%AC%EC%A0%81%EC%84%9C.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\n" + canary + "\r\n--B\r\nContent-Type: image/png\r\nContent-Disposition: attachment; filename=\"" + words("사진.png") + "\"\r\nContent-Transfer-Encoding: base64\r\n\r\n" + canary + "\r\n--B--\r\n").utf8))
        let readMail = FileDropSignals.read(.init(files: [mailPlain, mailHTML, mailMulti]), initial: .initial(.init(files: [mailPlain, mailHTML, mailMulti])))
        check(!readMail.partial && readMail.unread.isEmpty && ["보낸 사람: 김합성 <kim\u{40}example.invalid>", "제목: 납품 일정 확인", "날짜: Fri, 06 Nov 2026 09:30:00 +0900", "11월 20일까지 샘플 수량을 확정해 주세요.", "견적 1,180만원", "본문 평문", "첨부: 견적서.pdf", "첨부: 사진.png"].allSatisfy(readMail.content.contains) && !["<p>", "<b>", "<html", "color:red", "var x", "HTML 본문", "CANARY"].contains(where: readMail.content.contains), "AC-63 three mail files are read by the app: headers, body text, attachment names only")
        let bigMail = mail("긴메일.eml", Data("From: a\u{40}example.invalid\r\nSubject: s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n".utf8) + Data(String(repeating: "가", count: 35_000).utf8))
        let readBig = FileDropSignals.read(.init(files: [bigMail]), initial: .initial(.init(files: [bigMail])))
        check(readBig.partial && readBig.truncated && readBig.content.count == 30_000, "AC-64 text cut at the 30,000 character limit counts as not read completely")
        let sheet = file("매출.xlsx", "합성 형식")
        func noticeAfter(_ engine: @escaping FileDropCard.Engine, expect: String) async -> String {
            card.engine = engine; put([sheet]); card.receive(board)
            await until(expect, { card.status.isEmpty && !card.origin.isEmpty })
            let shown = card.notice; card.close(); return shown
        }
        let readXlsx = FileDropSignals.read(.init(files: [sheet]), initial: .initial(.init(files: [sheet])))
        check(readXlsx.partial && readXlsx.unread == ["매출.xlsx"], "AC-64 a format the app cannot read is listed as unread")
        let covered = await noticeAfter({ _, _ in FileDropAnswer(suggestions: [.init(id: "summarize", label: "세 줄 요약", profile: "work-x")], partial: false) }, expect: "reader read it")
        check(covered.isEmpty, "AC-64 the Mac mini reader read the unread file: no notice")
        let cut = await noticeAfter({ _, _ in FileDropAnswer(suggestions: [.init(id: "summarize", label: "세 줄 요약", profile: "work-x")], partial: true) }, expect: "reader read part")
        check(cut == FileDropCard.unreadNotice, "AC-64 the Mac mini reader left part unread: notice shows")
        let down = await noticeAfter({ _, _ in throw FileDropServiceError.notConnected }, expect: "not connected")
        check(down == FileDropCard.unreadNotice, "AC-64 no reader reached the file (not connected): notice shows")
        let older = await noticeAfter({ _, _ in FileDropAnswer(suggestions: [.init(id: "summarize", label: "세 줄 요약", profile: "work-x")]) }, expect: "older relay")
        check(older == FileDropCard.unreadNotice, "AC-64 an answer without the partial flag keeps the app's own reading result")
        let historyRoot = base.appendingPathComponent("history")
        bindFileDropHistory(force: true, user: "SYNTHETIC", folder: historyRoot, device: "SYNTHETIC-MAC")
        let historyNow = Date().timeIntervalSince1970
        for (id, age) in [("recent-memory", 3600.0), ("expired-memory", 49 * 3600.0)] {
            fileDropHistory?.begin(id: id, feature: "pdf", engine: "claude", names: [id], shown: [], profile: "work-x", now: historyNow - age)
            fileDropHistory?.answer(summary: id, shown: [], elapsed: 0, failed: false, works: [], now: historyNow - age)
            fileDropHistory?.close(now: historyNow - age)
        }
        var claudeSelections = 0, claudeRecent = false
        card.engine = { signals, _ in claudeSelections += 1; claudeRecent = signals.recent.contains { $0["summary"] == "recent-memory" } && !signals.recent.contains { $0["summary"] == "expired-memory" }; return FileDropAnswer(suggestions: []) }
        let legacySuite = "drop-legacy-" + UUID().uuidString, legacy = UserDefaults(suiteName: legacySuite)!
        legacy.set("mac", forKey: "fileDropEngine"); _ = FileDropSettings(defaults: legacy); legacy.removePersistentDomain(forName: legacySuite)
        put([pdf]); card.receive(board)
        await until("Claude engine", { claudeSelections == 1 && card.status.isEmpty })
        check(claudeSelections == 1, "AC-12 a stored legacy engine value is ignored; only the Claude engine is called on the drop")
        check(claudeRecent, "AC-37 the Claude engine boundary receives recent summaries and excludes the 49-hour record")
        card.close()
        var persistedThread = slack.fileDropThreads.first { $0.room == "CCOW" }!
        var persistedReply = ChatMessage(id: "slack:CCOW:synthetic-reply", fromUser: false, speaker: "업무비서", body: "합성 결과", date: Date())
        persistedReply.hermesReplyState = .closed; persistedThread.replies = [persistedReply]
        fileDropWatch.assignments = [.init(room: persistedThread.room, ts: persistedThread.ts, files: [], profile: "work-x", label: "세 줄 요약")]
        fileDropWatch.notices = []; fileDropWatch.onChange?(); fileDropWatch.update([persistedThread])
        check(fileDropWatch.notices.count == 1, "AC-42 persisted watch initially notifies closed")
        fileDropWatch.notices = []
        bindFileDropHistory(force: true, user: "SYNTHETIC", folder: historyRoot, device: "SYNTHETIC-MAC")
        fileDropWatch.update([persistedThread])
        check(fileDropWatch.notices.isEmpty, "AC-42 restart keeps same Mac closed state read")
        bindFileDropHistory(force: true, user: "SYNTHETIC", folder: historyRoot, device: "OTHER-MAC")
        fileDropWatch.update([persistedThread]); fileDropWatch.update([persistedThread])
        check(fileDropWatch.notices.count == 1, "AC-42 another Mac gets exactly one closed notice")
        fileDropWatch.notices = []; persistedReply.hermesReplyState = .asking; persistedThread.replies = [persistedReply]
        fileDropWatch.update([persistedThread]); check(fileDropWatch.notices.count == 1, "AC-44 asking is a separate persisted state")
        fileDropWatch.notices = []
        bindFileDropHistory(force: true, user: "SYNTHETIC", folder: historyRoot, device: "OTHER-MAC")
        fileDropWatch.update([persistedThread]); check(fileDropWatch.notices.isEmpty, "AC-44 asking is not repeated after restart")
        // A synthetic clipboard library tests the authoritative legacy capture path.
        let clipboardKey = ClipboardKeychain(service: "ddots.file-drop.smoke." + UUID().uuidString)
        defer { try? clipboardKey.delete() }
        let library = ClipboardLibrary(root: base.appendingPathComponent("clipboard"), temporary: base.appendingPathComponent("clipboard-temporary"), keychain: clipboardKey, board: board, settings: ClipboardSettings(), allowed: { true })
        connectClipboard(library); await until("clipboard ready", { library.ready }); library.monitor.stop()
        let sendsBeforeCopy = script.sent.count
        let image = NSImage(size: NSSize(width: 900, height: 160)); image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 160).fill()
        ("SYNTHETIC SAMPLE" as NSString).draw(at: CGPoint(x: 30, y: 45), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        board.clearContents(); board.setData(png, forType: .png)
        var rejectedEngineCalls = 0
        card.engine = { _, _ in
            rejectedEngineCalls += 1
            return FileDropAnswer(suggestions: [.init(id: "keep_clipboard", label: "클립보드에 보관", profile: "app")])
        }
        card.receive(board)
        await until("v1.7 image OCR and engine", { card.signals.content.contains("SYNTHETIC") && rejectedEngineCalls == 1 && card.status.isEmpty })
        check(!card.proposals.contains { $0.id == "keep_clipboard" } && library.entries.isEmpty, "AC-46 removed keep id is discarded; card drop never adds a shelf entry")
        library.monitor.start()
        performFileDrop(.init(id: "copy_text", label: "글자 복사", profile: "app")); library.monitor.poll(); await pause(); library.monitor.stop()
        check(board.string(forType: .string)?.contains("SYNTHETIC") == true && board.types?.contains(ClipboardPasteboard.generated) == true && library.entries.isEmpty && script.sent.count == sendsBeforeCopy, "AC-17 OCR copy writes marked system-board boundary only, no shelf or agent send")
        card.enabled = false; text("기능 끔 합성 글")
        check(pet.draggingEntered(drag) == .copy && pet.performDragOperation(drag), "AC-22 disabled function delegates folded drop to legacy clipboard")
        await until("legacy entry", { library.entries.count == 1 })
        check(!card.visible && library.entries.count == 1, "AC-22 legacy capture keeps card closed")
        card.enabled = true; pet.draggingExited(drag)
        card.close()
        if let fixture = ProcessInfo.processInfo.environment["DDOTS_DROP_FIXTURE_EXPORT"],
           let bytes = FileManager.default.contents(atPath: fixture),
           let approved = try? JSONDecoder().decode(SettingsStore.File.self, from: bytes) {
            fileDropHistory?.receive(approved.entries)
            let enrich = card.enrich
            card.enrich = { signals in signals.source = "Mail"; signals.folder = ""; signals.hosts = []; enrich(&signals) }
            card.engine = { signals, _ in
                return FileDropAnswer(suggestions: FileDropRules.rules(signals, cast: syntheticCast), summary: "합성 견적 구매 건 · 납품 마감 11월 20일")
            }
            put([pdf]); card.receive(board)
            await until("approved custom read", { card.proposals.contains { $0.id == "custom_instruction" && $0.label == "견적 비교" } && card.status.isEmpty })
            faces()
            let beforeCustom = script.sent.count
            card.choose(card.proposals.first { $0.id == "custom_instruction" }!)
            await until("custom handoff", { script.sent.count == beforeCustom + 1 && !card.sending })
            check(script.sent.last?["initial_comment"]?.contains("지시: 견적 비교") == true && script.sent.last?["files"]?.contains("두쪽.pdf") == true, "AC-30 actual review-approved fixture becomes custom button and keeps original instruction/files on handoff")
            card.close()
            put([pdf]); card.receive(board)
            await until("long custom ready", { card.status.isEmpty && card.payload.files.contains(pdf) })
            card.signals.custom = [firstInstruction, secondInstruction]
            card.proposals = FileDropRules.merge([customItem], signals: card.signals, fallback: [], profiles: syntheticCast.candidates)
            faces() // The synthetic Slack poll may refresh its cast between handoffs.
            let beforeLongCustom = script.sent.count
            card.choose(card.proposals[0])
            await until("long custom handoff", { script.sent.count == beforeLongCustom + 1 && !card.sending })
            check(script.sent.last?["initial_comment"]?.contains("지시: " + secondInstruction) == true && script.sent.last?["initial_comment"]?.contains("지시: " + firstInstruction) == false, "AC-48 colliding short custom labels send the selected approved original")
            card.close()
            let originalName = card.profileName
            card.profileName = { $0 == "app" ? "앱" : "업무비서" }
            let second = file("견적 비교.txt", "합성 납품 자료")
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance); panel.appearance = NSAppearance(named: appearance)
                put([pdf, second]); card.receive(board)
                await until("design ready", { card.status.isEmpty && !card.summary.isEmpty })
                await pause(0.8)
                panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless(); await pause(0.2)
                capture(destination: destination.appendingPathComponent("design-" + name))
                let screen = Process(); screen.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                screen.arguments = ["-x", "-l", String(panel.windowNumber), destination.appendingPathComponent("design-" + name + "/window.png").path]
                screen.standardOutput = FileHandle.nullDevice; screen.standardError = FileHandle.nullDevice
                do { try screen.run(); screen.waitUntilExit() } catch { }
                check(pet.fileDropContentFits, "V-7 " + name + " settled content stays within existing glass and preserves original footer")
                card.choose(.init(id: "opinion", label: "의견", profile: card.primaryProfile)); await pause(0.2)
                (panel.firstResponder as? NSTextView)?.insertText("견적 금액만 표로 비교해 줘", replacementRange: NSRange(location: NSNotFound, length: 0))
                check((panel.firstResponder as? NSTextView)?.string == "견적 금액만 표로 비교해 줘", "V-7 " + name + " editor displays actual typed Korean text")
                await pause(0.6); capture(destination: destination.appendingPathComponent("design-editor-" + name))
                check(pet.fileDropContentFits, "V-7 " + name + " opinion editor keeps the original footer visible")
                card.close()
            }
            NSApp.appearance = nil; panel.appearance = nil; card.enrich = enrich; card.profileName = originalName
        }
        print("PASS file-drop early-stage smoke; actual card/PDFKit, engine doubles; see file-drop-checks.txt")
        NSApp.terminate(nil)
    }
}

extension AppDelegate {
    /// Keeps the app alive with an all-local Slack double so that real mouse and key input from outside can drive the card.
    /// Commands arrive as files in `<out>/cmd` (`capture-NAME`, `options`, `stop`); every message the double receives is
    /// appended to `<out>/sent.jsonl`. No network, no real Slack, no real agent.
    @MainActor func verifyFileDropLive(destination: URL) async {
        let out = destination, cmd = destination.appendingPathComponent("cmd")
        try? FileManager.default.createDirectory(at: cmd, withIntermediateDirectories: true)
        let script = SlackSendScript(workspace: "https://file-drop.invalid/")
        slack.persists = false; slack.store = SlackFileStore(root: out.appendingPathComponent("sent-files")); slack.smokeSends = true
        if !CommandLine.arguments.contains("--ui-smoke-no-slack") { slack.start(script.api) }
        bindFileDropHistory(force: true, user: "LIVESYNTHETIC", folder: out.appendingPathComponent("drop-history"), device: "live-test")
        let realEngine = fileDrop.engine
        var noRoom = false, absent = false
        let roster: [(profile: String, name: String)] = [("work-x", "민트"), ("home-y", "하늘")]
        let portrait = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.2, alpha: 1).setFill(); rect.fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 16, dy: 16)).fill(); return true
        }
        func wire() {
            slack.model.ddotsMembers = roster.map { .init(profile: $0.profile, name: $0.name, room: "D" + $0.profile) }
            for member in roster { slack.model.members["D" + member.profile] = [.init(profile: member.profile, name: member.name, user: "U" + member.profile)] }
            for room in ["CCOW", "CTRUTH"] { slack.model.members[room] = roster.filter { !absent || $0.profile != "work-x" }.map { .init(profile: $0.profile, name: $0.name, user: "U" + $0.profile) } }
            slack.model.pins = noRoom ? [] : ["CCOW"]; slack.model.ddotsHub = noRoom ? nil : "CTRUTH"
            var work = ProfileAvatar(); work.image = portrait; work.color = .systemOrange
            chat.avatars = ["work-x": work]
        }
        func snapshot() -> [String: Any] {
            ["visible": fileDrop.visible, "editing": fileDrop.editing, "origin": fileDrop.origin, "status": fileDrop.status, "problem": fileDrop.problem, "notice": fileDrop.notice, "files": fileDrop.payload.files.map(\.lastPathComponent), "proposals": fileDrop.proposals.map { [$0.id, $0.label, $0.profile] }, "primary": fileDrop.primaryProfile, "roles": fileDropSettings.roles, "summary": fileDrop.summary, "text": String(fileDrop.payload.text.prefix(60)), "count": fileDrop.count, "sending": fileDrop.sending, "head": { let r = panel.convertToScreen(pet.convert(pet.atlas.interactionRect(in: pet.spriteRect), to: nil)); return [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] }(), "panel": [Int(panel.frame.minX), Int(panel.frame.minY), Int(panel.frame.width), Int(panel.frame.height)]]
        }
        var written = 0
        func flush() {
            let sent = script.sent
            guard sent.count > written else { return }
            let lines = sent[written...].compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
            if let handle = try? FileHandle(forWritingTo: out.appendingPathComponent("sent.jsonl")) { handle.seekToEndOfFile(); handle.write(Data(lines.utf8)); try? handle.close() }
            else { try? lines.write(to: out.appendingPathComponent("sent.jsonl"), atomically: true, encoding: .utf8) }
            written = sent.count
        }
        try? "".write(to: out.appendingPathComponent("sent.jsonl"), atomically: true, encoding: .utf8)
        dashboard?.orderOut(nil) // the test window must not cover the Finder window the files are dragged from
        try? "ready".write(to: out.appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
        while true {
            wire(); flush()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: cmd.path)) ?? []
            for name in names.sorted() {
                try? FileManager.default.removeItem(at: cmd.appendingPathComponent(name))
                if name == "stop" { flush(); NSApp.terminate(nil); return }
                if name == "options" { showOptions() }
                if name.hasPrefix("capture-") {
                    let tag = String(name.dropFirst(8))
                    capture(destination: out.appendingPathComponent("shots/" + tag))
                }
                switch name {
                case "failnext": script.next(false)
                case "noroom": noRoom = true
                case "room": noRoom = false
                case "absent": absent = true
                case "present": absent = false
                case "engine-real": fileDrop.engine = realEngine
                case "engine-outsider":
                    fileDrop.engine = { [weak self] signals, _ in
                        await self?.learnLiveRoles(signals)
                        return FileDropAnswer(suggestions: [.init(id: "summarize", label: "세 줄 요약", profile: "outsider-q")], summary: "합성")
                    }
                case "engine-offline": fileDrop.engine = { _, _ in throw FileDropServiceError.notConnected }
                case "engine-ok":
                    fileDrop.engine = { [weak self] signals, _ in
                        await self?.learnLiveRoles(signals)
                        return FileDropAnswer(suggestions: [.init(id: "explain", label: "무슨 내용인지 설명", profile: "home-y"), .init(id: "summarize", label: "세 줄 요약", profile: "work-x")], summary: "합성 요약")
                    }
                default: break
                }
                if name.hasPrefix("move-") {
                    let parts = name.dropFirst(5).split(separator: "-").compactMap { Double($0) }
                    if parts.count == 2 { placePet(at: NSPoint(x: parts[0], y: parts[1])) }
                }
                if name.hasPrefix("appearance-") {
                    let appearance = name.hasSuffix("dark") ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
                    NSApp.appearance = appearance; panel.appearance = appearance
                }
                if let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.sortedKeys]) { try? data.write(to: out.appendingPathComponent("done-" + name + ".json")) }
            }
            if let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.sortedKeys]) { try? data.write(to: out.appendingPathComponent("state.json")) }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

extension AppDelegate {
    /// The stand-in engines learn the organization's roles from the same context answer the real engines use.
    func learnLiveRoles(_ signals: FileDropSignals) async {
        if let context = try? await FileDropClaude.context(signals, home: DdotsConfig.shared.hermes, remote: remoteHermes), let roles = context.agentRoles { fileDropSettings.learn(roles: roles) }
    }
}
