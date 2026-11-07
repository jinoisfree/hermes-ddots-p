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
        card.enabled = true; card.profiles = { FileDropRules.profiles }
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
        card.onSelect = { defaultAction = $0.id }
        key(36, chars: "\r"); await pause()
        check(defaultAction == card.proposals.first?.id, "V-7 Return selects the first proposal only")
        card.onSelect = initialSelect
        card.close()

        text("합성 일반 자료"); card.engineKind = "claude"; card.engine = { _, _ in throw FileDropServiceError.unavailable }; card.receive(board)
        await until("Claude failure notice", { card.notice == "Claude 제안 못 받음" })
        check(card.proposals.count == 3 && card.notice == "Claude 제안 못 받음", "AC-11 failed Claude boundary keeps fallback and explains failure")
        card.close(); card.engineKind = "mac"
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
        let configuredProfiles = card.profiles
        card.profiles = { [] }; card.analyze()
        check(FileDropRules.profiles.contains(card.primaryProfile), "REQ-FD-20 an unconfigured cast never falls back to a forbidden agent")
        card.profiles = configuredProfiles; card.analyze()
        let invalid = [FileDropSuggestion(id: "erase", label: "삭제", profile: "work-assistant"), .init(id: "explain", label: "설명", profile: "missing"), .init(id: "compare", label: "", profile: "work-assistant")]
        let merged = FileDropRules.merge(invalid, signals: card.signals, fallback: card.proposals, profiles: FileDropRules.profiles)
        check(merged == card.proposals, "AC-08 invalid id/profile/empty label are rejected and filled")
        let longEnglish = "sqlite database is locked while waiting for transaction"
        let longKorean = "회사 자료를 함께 읽고 요청 사항을 정리해서 알려주기!"
        let longWord = "abcdefghijklmnopqrstuvwxyzabcdef"
        let longItems = [longEnglish, longKorean, longWord].enumerated().map { index, label in
            FileDropSuggestion(id: ["summarize", "compare", "explain"][index], label: label, profile: "work-assistant")
        }
        let shortened = FileDropRules.merge(longItems, signals: card.signals, fallback: [], profiles: FileDropRules.profiles)
        check(shortened.count == 3 && shortened.allSatisfy { $0.label.count <= 24 && $0.label.hasSuffix("…") } && shortened[0].label == "sqlite database is…" && shortened[2].label == "…", "AC-48 merge shortens Korean and English at word boundaries")
        var workSignals = card.signals; workSignals.works = []
        let attached = [FileDropSuggestion(id: "attach_work", label: "장비 구매에 붙이기", profile: "work-assistant"), .init(id: "attach_work", label: "납품 점검에 붙이기", profile: "work-assistant")]
        let withoutWork = FileDropRules.merge(attached, signals: workSignals, fallback: card.proposals, profiles: FileDropRules.profiles)
        workSignals.works = ["납품 점검"]
        let withWork = FileDropRules.merge(attached, signals: workSignals, fallback: card.proposals, profiles: FileDropRules.profiles)
        check(withoutWork == card.proposals && withWork.count == 3 && withWork.first?.label == "납품 점검에 붙이기", "AC-49 rejects absent or invented works and fills fallback")
        workSignals.agentRoles = ["work-assistant": ["work"], "personal-secretary": ["personal"], "system-doctor": ["doctor"]]
        let macRoleData = try! JSONSerialization.jsonObject(with: FileDropRules.macInput(workSignals)) as! [String: Any]
        let expectedRoles = ["work-assistant": ["work"], "personal-secretary": ["personal"]]
        check((macRoleData["agentRoles"] as? [String: [String]]) == expectedRoles && ["work=회사 업무", "personal=개인", "참고 힌트", "16자"].allSatisfy(FileDropRules.assignmentInstructions.contains) && !String(decoding: try! FileDropRules.macInput(workSignals), as: UTF8.self).contains("doctor"), "AC-47 Mac input contains two role descriptions and hint policy, excluding retired role")
        workSignals.today = "2026-11-07(토)"
        let datedInput = try! JSONSerialization.jsonObject(with: FileDropRules.macInput(workSignals)) as! [String: Any]
        check(datedInput["today"] as? String == workSignals.today && ["today 기준 날짜", "이미 지난 기한", "끝난 일의 시각", "지난 기한 성적서 확인"].allSatisfy(FileDropRules.assignmentInstructions.contains), "AC-53 Mac input retains fixed local today and date instructions")
        let fixedNow = ISO8601DateFormatter().date(from: "2026-11-06T16:00:00Z")!
        check(FileDropSignals.localToday(now: fixedNow, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!) == "2026-11-07(토)" && FileDropSignals.localToday(now: fixedNow, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!) == "2026-11-06(금)", "AC-53 local date uses the device timezone and Korean weekday")
        let retired = [FileDropSuggestion(id: "summarize", label: "요약", profile: "system-doctor"), .init(id: "diagnose", label: "진단", profile: "work-assistant")]
        var oldSignals = workSignals; oldSignals.profile = "system-doctor"; oldSignals.content = "error crash sync.log 오류"
        let oldFallback = FileDropRules.rules(oldSignals)
        check(FileDropRules.merge(retired, signals: oldSignals, fallback: oldFallback, profiles: ["work-assistant", "system-doctor"]) == oldFallback && oldFallback.count == 3 && oldFallback.allSatisfy { $0.profile == "work-assistant" && $0.id != "diagnose" } && FileDropSignals.owner(oldSignals.content) == "work-assistant" && !["system-doctor", "doctor", "diagnose"].contains(where: FileDropRules.assignmentInstructions.contains), "AC-52 retired agent and diagnose rejected; log hint and fallback use work agent")
        let allowedNumbers = ["견적번호 202611-3000123", "주문번호 2026110712345678", "990231-1234567", "000229-1234567", "900101-9234567", "4111 1111 1111 1112", "41111111111111111111"]
        let secretNumbers = ["900101-1234567", "000229-3234567", "4111 1111 1111 1111", "378282246310005", "xoxb-", "sk-SYNTHETIC", "AKIASYNTHETIC", "ghp_SYNTHETIC", "-----BEGIN", "비밀번호: x", "PASSWORD: x"]
        check(allowedNumbers.allSatisfy { !FileDropSignals.secret($0) } && secretNumbers.allSatisfy(FileDropSignals.secret), "AC-54 valid birth dates and Luhn cards block; order IDs pass; credentials still block")
        let firstInstruction = "자료를 자세히 읽고 요청한 결과를 정리한 다음 회사 폴더에 보관하기"
        let secondInstruction = "자료를 자세히 읽고 요청한 결과를 정리한 다음 사용자에게 설명하기"
        var customSignals = workSignals; customSignals.custom = [firstInstruction, secondInstruction]
        let customItem = FileDropSuggestion(id: "custom_instruction", label: FileDropRules.shortLabel(secondInstruction), profile: "work-assistant", instruction: secondInstruction)
        let customMerged = FileDropRules.merge([customItem], signals: customSignals, fallback: [], profiles: FileDropRules.profiles)
        check(FileDropRules.shortLabel(firstInstruction) == customItem.label && customMerged.first?.instruction == secondInstruction, "AC-48 equal shortened custom labels retain the exact approved instruction")
        await pause(2.2)
        check(card.proposals.count == 3 && card.notice.isEmpty && card.status.isEmpty, "AC-09 mac timeout keeps fallback without error")
        let validAnswer = FileDropAnswer(suggestions: [.init(id: "summarize", label: "대상 요약", profile: "work-assistant")], summary: "합성 } 안쪽 따옴표 \" 보존")
        let validJSON = String(decoding: try! JSONEncoder().encode(validAnswer), as: UTF8.self)
        card.close(); card.engineKind = "mac"
        card.engine = { _, _ in try FileDropRules.parseAnswer("안내\n```json\n" + validJSON + "\n```\n참고: TAIL_CANARY") }
        text("합성 JSON 응답"); card.receive(board)
        await until("JSON object response", { card.status.isEmpty && card.summary == validAnswer.summary })
        let renderedState = card.summary + card.notice + card.status + card.proposals.map(\.label).joined()
        check(card.proposals.first?.label == "대상 요약" && !renderedState.contains("TAIL_CANARY"), "AC-50 first JSON object is used and extra prose is absent from card state")
        card.close(); card.engine = { _, _ in try FileDropRules.parseAnswer("참고: TAIL_CANARY") }
        text("합성 JSON 없는 응답"); card.receive(board)
        await until("missing JSON fallback", { card.status.isEmpty })
        check(card.proposals == FileDropRules.rules(card.signals) && card.notice.isEmpty, "AC-50 missing JSON fails and retains fallback without prose")
        let scopeItems = [FileDropSuggestion(id: "add_schedule", label: "식약처 서류 일정", profile: "work-assistant"), .init(id: "add_schedule", label: "어린이집 상담 일정", profile: "personal-secretary")]
        let scoped = FileDropRules.merge(scopeItems, signals: card.signals, fallback: card.proposals, profiles: FileDropRules.profiles)
        card.proposals = scoped
        check(scoped.count == 3 && scoped[0].profile == "work-assistant" && scoped[1].profile == "personal-secretary" && scoped[0].id == scoped[1].id && ["범위별 담당", "식약처 서류 일정", "어린이집 상담 일정", "0.6 아래"].allSatisfy(FileDropRules.assignmentInstructions.contains), "AC-51 same action survives for separate company and personal scopes")
        await pause(); capture(destination: destination.appendingPathComponent("mixed-scopes"))
        card.close(); text("맨 앞 내용\n두 번째 쪽 " + "xoxb-" + "SYNTHETIC-NOT-A-SECRET")
        card.engineKind = "claude"; let beforeSecret = engineCalls; card.receive(board)
        await until("secret check", { card.sensitive })
        check(engineCalls == beforeSecret && card.notice == "비밀처럼 보여 밖으로 보내지 않았어요", "AC-13 secret in later content blocks engine boundary")
        card.close(); card.engineKind = "mac"
        card.engine = { _, _ in engineCalls += 1; return FileDropAnswer(suggestions: [], confidence: 0.3, works: ["합성 업무"]) }
        text("합성 업무 자료"); card.receive(board)
        await until("confirmation", { card.confirmation != nil })
        check(card.confirmation == "합성 업무", "AC-14 low confidence asks about single work")
        card.confirmation = nil
        let beforeOpinion = engineCalls
        var opinion: FileDropSuggestion?
        let select = card.onSelect; card.onSelect = { opinion = $0 }
        card.choose(.init(id: "opinion", label: "의견", profile: "work-assistant")); await pause()
        check(card.editing && panel.firstResponder is NSTextView, "AC-15 opinion editor has keyboard focus")
        card.draft = "견적 비교"; card.submit()
        check(opinion?.id == "opinion" && opinion?.label == "견적 비교" && engineCalls == beforeOpinion, "AC-15 opinion submits instruction without engine rerun")
        card.choose(.init(id: "opinion", label: "의견", profile: "work-assistant")); card.escape()
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
        card.engineKind = "claude"; let callsBeforePDF = engineCalls
        card.engine = { _, _ in engineCalls += 1; return FileDropAnswer(suggestions: []) }
        put([secretPDF]); card.receive(board)
        await until("second PDF page secret", { card.sensitive && card.notice.contains("밖으로 보내지") })
        check(engineCalls == callsBeforePDF, "AC-13 actual two-page synthetic PDF blocks engine before any request")
        await pause(0.6); capture(destination: destination.appendingPathComponent("design-secret"))
        check(pet.fileDropContentFits, "V-7 secret warning and actions stay inside glass")
        card.close(); card.engineKind = "mac"
        let payload = FileDropIntake.Payload(files: [pdf])
        let signals = FileDropSignals.read(payload, initial: .initial(payload))
        let macInput = try! JSONDecoder().decode(FileDropSignals.self, from: FileDropRules.macInput(signals))
        check(macInput.content.contains("납품 마감 11월 20일") && macInput.content.count <= 2500, "AC-32 both PDF pages reach the actual bounded mac engine input encoder")
        let receipt = file("일반 문서.txt", "이것은 개인 영수증 자료입니다")
        let receiptPayload = FileDropIntake.Payload(files: [receipt])
        check(FileDropSignals.read(receiptPayload, initial: .initial(receiptPayload)).profile == "personal-secretary", "REQ-FD-20 content refines a generic filename to personal agent")
        let origin = file("출처.txt")
        let metadata = try! PropertyListSerialization.data(fromPropertyList: ["https://example.invalid/private/path?token=synthetic"], format: .binary, options: 0)
        let xattr = metadata.withUnsafeBytes { setxattr(origin.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, metadata.count, 0, 0) }
        check(xattr == 0 && FileDropSignals.originHosts(origin) == ["example.invalid"], "REQ-FD-06 synthetic WhereFroms metadata exposes host only")

        let watch = FileDropWatch(); watch.device = "synthetic-mac"
        var root = ChatMessage(id: "slack:HUB-A:100", fromUser: true, speaker: "나", body: "합성 맡김", date: Date())
        root.files = []
        var reply = ChatMessage(id: "slack:HUB-A:101", fromUser: false, speaker: "업무비서", body: "합성 답", date: Date())
        var thread = SlackThread(id: "HUB-A:100", room: "HUB-A", ts: "100", root: root, replies: [], replyCount: 1, loaded: true, latest: 101, latestFromUser: false)
        watch.assignments = [.init(room: "HUB-A", ts: "100", files: [], profile: "work-assistant", label: "세 줄 요약")]
        reply.hermesReplyState = .working; thread.replies = [reply]; watch.update([thread])
        check(watch.notices.isEmpty, "AC-42 working has no bubble")
        reply.hermesReplyState = .closed; thread.replies = [reply]; watch.update([thread]); watch.update([thread])
        check(watch.notices.count == 1 && watch.notices[0].state == .closed, "AC-42 closed is notified once")
        watch.notices = []; reply.hermesReplyState = .asking; thread.replies = [reply]; watch.update([thread])
        check(watch.notices.count == 1 && watch.notices[0].state == .asking, "AC-44 asking is notified once")
        watch.update([thread], now: Date().timeIntervalSince1970 + 49 * 3600)
        check(watch.assignments.isEmpty, "REQ-FD-24 watch expires after 48 hours")

        // Use the real send controller with its existing all-local Slack transport double.
        card.engineKind = "mac"; card.engine = { _, _ in throw CocoaError(.featureUnsupported) }
        let script = SlackSendScript(workspace: "https://file-drop.invalid/")
        let action = FileDropSuggestion(id: "summarize", label: "세 줄 요약", profile: "work-assistant")
        text("Slack 미연결 합성 글"); card.receive(board)
        performFileDrop(action)
        check(card.notice == "Slack 연결이 필요해요" && card.visible && card.payload.count == 1, "AC-18 disconnected retains card and payload")
        card.close()
        let promiseResolver = card.intake.promises
        text("결합 promise"); card.intake.promises = { _ in [FileDropSyntheticPromise()] }; card.receive(board)
        await until("disconnected promise", { !card.payload.files.isEmpty })
        let retainedPromise = card.payload.files[0]
        performFileDrop(action)
        check(card.notice == "Slack 연결이 필요해요" && card.visible && FileManager.default.fileExists(atPath: retainedPromise.path), "AC-18 disconnected handoff retains its actual promised file")
        card.close(); card.intake.promises = promiseResolver
        slack.persists = false; slack.store = SlackFileStore(root: base.appendingPathComponent("sent-files")); slack.smokeSends = true; slack.start(script.api)
        await until("fake Slack ready", { slack.connected && !slack.model.rooms.isEmpty })
        func faces(_ pins: [String] = ["CCOW"], hub: String? = "CTRUTH") {
            slack.model.ddotsMembers = [.init(profile: "work-assistant", name: "업무비서", room: "Doffice")]
            slack.model.members["Doffice"] = [.init(profile: "work-assistant", name: "업무비서", user: "Uoffice")]
            slack.model.members["CCOW"] = [.init(profile: "work-assistant", name: "업무비서", user: "Uoffice")]
            slack.model.members["CTRUTH"] = [.init(profile: "work-assistant", name: "업무비서", user: "Uoffice")]
            slack.model.pins = pins; slack.model.ddotsHub = hub
        }
        faces(); card.engineKind = "claude"; card.engine = { _, _ in try await Task.sleep(nanoseconds: 3_000_000_000); throw FileDropServiceError.unavailable }
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
        card.choose(.init(id: "opinion", label: "의견", profile: "work-assistant")); await pause()
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
        check(script.sent.count == beforeMissing && card.notice == "맨 위에 고정한 채널이 필요해요", "AC-41 both channels missing refuses send")
        card.close(); faces(); slack.model.members["CCOW"] = [.init(profile: "system-doctor", name: "진단담당", user: "UDOCTOR")]
        text("absent 합성 글"); card.receive(board); performFileDrop(action)
        check(script.sent.count == beforeMissing && card.notice.contains("이 채널에 없어요"), "REQ-FD-22 absent does not reroute")
        card.close(); faces(); slack.model.source = .slack; slack.model.show(room: "CCOW"); showChat(); await pause(0.4)
        put([pdf]); check(pet.draggingEntered(drag) == [] && !card.visible, "AC-02 expanded pet declines card")
        let attachment = AttachmentDropView(frame: pet.bounds); attachment.model = slack.model; pet.addSubview(attachment)
        check(attachment.drop(from: board, at: CGPoint(x: 20, y: 20)) && slack.model.attachments.contains(pdf), "AC-02 expanded conversation keeps attachment destination")
        attachment.removeFromSuperview(); slack.model.attachments = []
        if let existing = slack.fileDropThreads.first(where: { $0.room == "CCOW" }) {
            fileDropWatch.notices = [.init(assignment: "synthetic-open", thread: existing, profile: "work-assistant", label: "세 줄 요약", state: .closed)]
            collapseChat(); updatePet(); check(pet.headline.hasPrefix("🟢 ") && pet.headline.contains("끝냈어요"), "AC-42 real completion bubble with green status point")
            await pause(0.6); capture(destination: destination.appendingPathComponent("design-complete"))
            petClicked(count: 1); await pause(0.3)
            check(chatExpanded && slack.model.focusThread == existing.id && slack.model.open.contains(existing.id) && fileDropWatch.notices.isEmpty && (slack.localThreads[existing.room + ":" + existing.ts] ?? 0) >= existing.latest, "AC-43 clicking bubble expands, reveals and marks its thread read")
            collapseChat(); fileDropWatch.notices = [.init(assignment: "synthetic-ask", thread: existing, profile: "work-assistant", label: "세 줄 요약", state: .asking)]
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
        card.engineKind = "claude"; let unknown = file("합성.hwp", "합성 형식")
        put([unknown]); card.receive(board)
        await until("partial relay returned", { card.status.isEmpty && card.signals.partial })
        let originalsSent = relayLock.withLock { rawFiles }
        check(originalsSent == 0 && card.notice == "내용을 다 읽지 못했어요" && card.proposals.count == 3, "AC-36 unencrypted original count zero and actual card keeps partial-reading notice")
        card.close(); relayClient.stop(); relayServer.stop()
        let historyRoot = base.appendingPathComponent("history")
        bindFileDropHistory(force: true, user: "SYNTHETIC", folder: historyRoot, device: "SYNTHETIC-MAC")
        let historyNow = Date().timeIntervalSince1970
        for (id, age) in [("recent-memory", 3600.0), ("expired-memory", 49 * 3600.0)] {
            fileDropHistory?.begin(id: id, feature: "pdf", engine: "mac", names: [id], shown: [], profile: "work-assistant", now: historyNow - age)
            fileDropHistory?.answer(summary: id, shown: [], elapsed: 0, failed: false, works: [], now: historyNow - age)
            fileDropHistory?.close(now: historyNow - age)
        }
        var macSelections = 0, claudeSelections = 0
        var macRecent = false, claudeRecent = false
        fileDropEngines = [
            "mac": { signals, _ in macSelections += 1; macRecent = signals.recent.contains { $0["summary"] == "recent-memory" } && !signals.recent.contains { $0["summary"] == "expired-memory" }; return FileDropAnswer(suggestions: []) },
            "claude": { signals, _ in claudeSelections += 1; claudeRecent = signals.recent.contains { $0["summary"] == "recent-memory" } && !signals.recent.contains { $0["summary"] == "expired-memory" }; return FileDropAnswer(suggestions: []) }
        ]
        fileDropSettings.selectEngine("mac"); put([pdf]); card.receive(board)
        await until("selected mac engine", { macSelections == 1 && card.status.isEmpty })
        card.close(); fileDropSettings.selectEngine("claude"); put([pdf]); card.receive(board)
        await until("selected Claude engine", { claudeSelections == 1 && card.status.isEmpty })
        check(macSelections == 1 && claudeSelections == 1 && fileDropSettings.engine == "claude", "AC-12 settings selection calls only that engine on the next drop")
        check(macRecent && claudeRecent, "AC-37 both selected engine boundaries receive recent summaries and exclude the 49-hour record")
        card.close()
        var persistedThread = slack.fileDropThreads.first { $0.room == "CCOW" }!
        var persistedReply = ChatMessage(id: "slack:CCOW:synthetic-reply", fromUser: false, speaker: "업무비서", body: "합성 결과", date: Date())
        persistedReply.hermesReplyState = .closed; persistedThread.replies = [persistedReply]
        fileDropWatch.assignments = [.init(room: persistedThread.room, ts: persistedThread.ts, files: [], profile: "work-assistant", label: "세 줄 요약")]
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
            card.engineKind = "mac"
            card.engine = { signals, _ in
                return FileDropAnswer(suggestions: FileDropRules.rules(signals), summary: "합성 견적 구매 건 · 납품 마감 11월 20일")
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
            card.proposals = FileDropRules.merge([customItem], signals: card.signals, fallback: [], profiles: FileDropRules.profiles)
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
