import Foundation
import AppKit
import SQLite3

@main
struct ConversationTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed += 1
    }
    static func message(_ id: String, user: Bool = false, _ body: String, at seconds: Double, speaker: String = "개인비서", pending: Bool = false) -> ChatMessage {
        ChatMessage(id: id, fromUser: user, speaker: user ? "" : speaker, body: body, date: Date(timeIntervalSince1970: seconds), pending: pending)
    }
    static func makeStore(_ url: URL, statements: [String]) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        for sql in statements { precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sql) }
        sqlite3_close(db)
    }

    /// A send that takes its time, or fails, runs away from the main thread one at a time and answers once, in order.
    /// Nothing reaches Messages: the runner is a stand-in that sleeps.
    static func checkSlowSends() {
        final class Record: @unchecked Sendable {
            let lock = NSLock()
            var running = 0, overlapped = false, offMain = true, beats = 0, answeredOnMain = true
            var finished: [(text: String, failed: Bool)] = []
        }
        let record = Record()
        HermesBridge.sendRunner = { text, _ in
            record.lock.lock(); record.running += 1
            if record.running > 1 { record.overlapped = true }
            if Thread.isMainThread { record.offMain = false }
            record.lock.unlock()
            Thread.sleep(forTimeInterval: 0.4)
            record.lock.lock(); record.running -= 1; record.lock.unlock()
            return text == "실패" ? HermesBridge.failure(code: -1712, detail: "합성 실패") : nil
        }
        defer { HermesBridge.sendRunner = HermesBridge.runSendScript }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in record.beats += 1 }
        RunLoop.main.add(timer, forMode: .common)
        let started = Date()
        for text in ["첫째", "실패", "셋째"] {
            HermesBridge.perform(text: text, handle: "+16285550100") { failure in
                if !Thread.isMainThread { record.answeredOnMain = false }
                record.finished.append((text, failure != nil))
            }
        }
        check(Date().timeIntervalSince(started) < 0.1, "starting slow sends returns to the main thread at once")
        let deadline = Date().addingTimeInterval(5)
        while record.finished.count < 3 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        // A little longer, so an answer given twice would show.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        timer.invalidate()
        check(record.finished.map(\.text) == ["첫째", "실패", "셋째"] && record.finished.map(\.failed) == [false, true, false],
              "slow sends answer once each, in the order sent, and a failure is reported as one")
        check(record.beats >= 15, "the main loop keeps beating through 1.2 seconds of slow sends (beats: \(record.beats))")
        check(!record.overlapped && record.offMain && record.answeredOnMain, "sends run one at a time off the main thread and answer on it")
    }

    static func main() throws {
        var memo = ChatTimelineMemo()
        var sample = [message("memo1", "first", at: 1), message("memo2", "second", at: 2)]
        check(memo.merge(sample, pending: []) == ChatTimeline.merge(sample, pending: []), "memo preserves merge")
        _ = memo.merge(sample, pending: [])
        check(memo.evaluations == 1, "unchanged messages do not merge again")
        sample[0].body = "edited"
        check(memo.merge(sample, pending: []) == ChatTimeline.merge(sample, pending: []), "edits invalidate memo")
        check(memo.merge(sample, pending: [], limit: 1).count == 1, "pagination limit invalidates memo")
        let memoEcho = message("echo", user: true, "pending", at: 3, pending: true)
        check(memo.merge(sample, pending: [memoEcho]).last == memoEcho, "new pending message invalidates memo")
        check(memo.merge([], pending: []).isEmpty, "removal invalidates memo")
        // Avatar paths and thumbnail cache use only a disposable HERMES_HOME.
        let avatarHome = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-avatar-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: avatarHome) }
        let assets = avatarHome.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let slack = assets.appendingPathComponent("slack-avatar.png"), local = assets.appendingPathComponent("avatar.png")
        func png(_ path: URL, _ color: NSColor) throws {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let rgb = color.usingColorSpace(.sRGB)!
            for y in 0..<128 { for x in 0..<128 {
                    let pixel = bitmap.bitmapData!.advanced(by: y * bitmap.bytesPerRow + x * 4)
                    pixel[0] = UInt8(rgb.redComponent * 255); pixel[1] = UInt8(rgb.greenComponent * 255)
                    pixel[2] = UInt8(rgb.blueComponent * 255); pixel[3] = 255
                } }
            try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        }
        check(ProfileAvatarCache.avatarURL(root: avatarHome) == nil, "no local photo returns nil")
        try png(local, .red)
        check(ProfileAvatarCache.avatarURL(root: avatarHome) == local, "avatar.png fallback")
        try png(slack, .blue)
        check(ProfileAvatarCache.avatarURL(root: avatarHome) == slack, "Slack avatar takes precedence")
        try FileManager.default.removeItem(at: local)
        check(ProfileAvatarCache.avatarURL(root: avatarHome) == slack, "Slack avatar alone")
        let avatars = ProfileAvatarCache()
        let firstAvatar = avatars.load(profile: "default", root: avatarHome, url: slack)
        check(firstAvatar.image != nil && firstAvatar.image!.size == NSSize(width: ChatMetrics.thumbnailPixels, height: ChatMetrics.thumbnailPixels), "decoded image is downsampled to the shared pixel limit")
        check(avatars.load(profile: "default", root: avatarHome, url: slack).image === firstAvatar.image && avatars.imageReads == 1, "unchanged image is reused without rereading")
        try png(slack, .green)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: slack.path)
        let updatedAvatar = avatars.load(profile: "default", root: avatarHome, url: slack)
        check(updatedAvatar.image != nil && updatedAvatar.image !== firstAvatar.image && avatars.imageReads == 2, "file modification invalidates the thumbnail")
        let metadata = avatarHome.appendingPathComponent("profile.yaml")
        try "ui_meta:\n  hermes-bots:\n    color: '#8b5cf6'\n".write(to: metadata, atomically: true, encoding: .utf8)
        let colored = avatars.load(profile: "default", root: avatarHome, url: slack)
        check(colored.color == ProfileAvatarCache.parseColor("#8b5cf6") && avatars.imageReads == 2, "metadata changes color without reloading the photo")
        check(ProfileAvatarCache.profileColor("color: '#ff0000'\nother:\n  color: '#ff0000'") == nil, "unrelated YAML color is ignored")
        check(ProfileAvatarCache.parseColor("hsl(38 72% 58%)") != nil && ProfileAvatarCache.parseColor("invalid") == nil, "HSL config and invalid color handling")
        try Data("damaged PNG".utf8).write(to: slack)
        let damaged = avatars.load(profile: "default", root: avatarHome, url: slack)
        let fallbackName = "위키담당"
        check(damaged.image == nil && ProfileAvatar.initial(fallbackName) == String(fallbackName.prefix(1)), "damaged file falls back to the name initial")
        _ = avatars.load(profile: "default", root: avatarHome, url: slack)
        check(avatars.imageReads == 3, "failed decode is cached")
        try FileManager.default.removeItem(at: slack)
        check(avatars.load(profile: "default", root: avatarHome, url: nil).image == nil, "deletion clears the cached image")
        check(avatars.load(profile: "other", root: assets, url: nil).color == .systemGray, "missing metadata falls back to gray")
        let explicitProfile = ChatMessage(id: "opaque-id", fromUser: false, speaker: "위키담당", body: "답", date: Date(), profile: "default")
        check(explicitProfile.profile == "default", "profile survives independently of the message identifier")

        do {
            var memo = PetActionMemo()
            var message = ChatMessage(id: "actions-cache", fromUser: false, speaker: "합성", body: "https://example.com 회의", date: Date(timeIntervalSince1970: 1000))
            var event = CalendarEntry(identifier: "synthetic", calendarID: "test", title: "회의", start: message.date, end: message.date.addingTimeInterval(3600))
            for title in ["회의", "변경된 회의"] {
                event.title = title
                check(memo.actions(for: message, events: [event]) == PetAction.content(in: message.body, events: [event], at: message.date), "Action memo matches calendar edits")
            }
            let evaluated = memo.evaluations
            _ = memo.actions(for: message, events: [event])
            check(memo.evaluations == evaluated, "Action memo reuses unchanged inputs")
            message.body = "https://example.org 새 글"; message.date = message.date.addingTimeInterval(86400)
            check(memo.actions(for: message, events: []) == PetAction.content(in: message.body, at: message.date), "Action memo invalidates edited body/date/events")
            message.pending = true
            check(memo.actions(for: message, events: []).isEmpty, "Pending messages have no actions")
            for index in 0..<520 { message.id = "cache-\(index)"; _ = memo.actions(for: message, events: []) }
            check(memo.count <= 512, "Action memo stays bounded")
        }

        // Pure calling, folding, and contrast policies.
        let characters = [ChatCharacter(id:"default",name:"위키담당"), ChatCharacter(id:"personal-secretary",name:"개인비서"), ChatCharacter(id:"archive-helper",name:"보관담당"), ChatCharacter(id:"sns-manager",name:"SNS담당"), ChatCharacter(id:"system-doctor",name:"진단담당")]
        check(CharacterCall.toggled("질문\n둘째 줄  ",name:"SNS담당",characters:characters) == "SNS담당, 질문\n둘째 줄  ", "calling preserves the body and trailing whitespace")
        check(CharacterCall.toggled("위키담당, 질문",name:"SNS담당",characters:characters) == "SNS담당, 질문", "calling replaces another character")
        check(CharacterCall.toggled("SNS담당, 질문",name:"SNS담당",characters:characters) == "질문", "calling the same character removes the prefix")
        check(CharacterCall.toggled("  SNS담당 ,   질문",name:"진단담당",characters:characters) == "진단담당, 질문", "calling normalizes only leading separator spaces")
        check(CharacterCall.toggled("",name:"SNS담당",characters:characters) == "SNS담당, ", "empty draft gets a ready prefix")
        check(CharacterCall.toggled("SNS담당, ",name:"SNS담당",characters:characters).isEmpty, "empty prefix toggles off")
        check(CharacterCall.toggled("SNS담당가 답한 내용",name:"진단담당",characters:characters) == "진단담당, SNS담당가 답한 내용", "an ordinary name inside body is preserved")
        check(CharacterCall.toggled("미등록, 본문",name:"SNS담당",characters:characters) == "SNS담당, 미등록, 본문", "unknown prefix stays part of the body")
        check(!LongReply.needsFolding(String(repeating:"가",count:600)) && LongReply.needsFolding(String(repeating:"가",count:601)), "600-character boundary")
        let twelve = (1...12).map { "**줄 \($0)**" }.joined(separator:"\n")
        check(!LongReply.needsFolding(twelve) && LongReply.preview(twelve+"\n마지막") == twelve, "12-line preview keeps full Markdown lines")
        check(LongReply.preview("첫 줄\n"+String(repeating:"가",count:600)) == "첫 줄", "long next line is not split")
        check(LongReply.preview(String(repeating:"👨‍👩‍👧‍👦",count:601)).count == 600, "single long line truncates at grapheme boundary")
        let colors = ["default":"#8b5cf6", "personal-secretary":"hsl(38 72% 58%)", "archive-helper":"hsl(220 24% 18%)", "sns-manager":"hsl(220 12% 22%)", "system-doctor":"hsl(91 68% 58%)"].mapValues { ProfileAvatarCache.parseColor($0)! }
        let hues = CharacterPalette.hues(characters:characters,colors:colors)
        check(hues.count == 5 && hues == CharacterPalette.hues(characters:characters.reversed(),colors:colors), "hue assignment is deterministic regardless of discovery order")
        check(hues["sns-manager"] != hues["archive-helper"], "dark characters sharing 220 degrees receive different hues")
        for a in characters { for b in characters where a.id != b.id {
            check(CharacterPalette.distance(hues[a.id]!,hues[b.id]!) >= 25-0.000001, "all five character hues are separated")
        } }
        for character in characters {
            var report = "PALETTE \(character.name)"
            for dark in [true,false] {
                let palette = CharacterPalette.make(hue:hues[character.id],dark:dark)
                let v = dark ? 0.45 : 0.55, backdrop = PaletteRGB(r:v,g:v,b:v)
                check(palette.link != palette.foreground && palette.link.b > palette.link.r && palette.link.g > palette.link.r, "links stay blue and distinct from body text")
                check(palette.contrast >= 4.5 && palette.linkContrast >= 4.5, "body and links meet WCAG contrast")
                check(PaletteRGB.contrast(palette.name,backdrop) >= 4.5, "name meets worst tinted wallpaper contrast")
                report += String(format:" %@ %@ %.2f name %.2f", dark ? "dark" : "light", palette.background.hex, palette.contrast, PaletteRGB.contrast(palette.name,backdrop))
            }
            print(report)
        }
        check(CharacterPalette.hues(characters:characters,colors:[:]).isEmpty && CharacterPalette.make(hue:nil,dark:true).hue == nil, "missing colors preserve gray")
        check(ChatCharacter.ordered(characters.reversed()) == characters, "caller buttons use the explicit test-local character order")

        let launched = Date(timeIntervalSince1970:100)
        var unread = UnreadReplies(launchedAt:launched)
        let receipts = [ChatReceipt(id:"old",fromUser:false,date:Date(timeIntervalSince1970:99)), ChatReceipt(id:"a",fromUser:false,date:Date(timeIntervalSince1970:101)), ChatReceipt(id:"b",fromUser:false,date:Date(timeIntervalSince1970:102))]
        unread.update(receipts,open:false,now:Date(timeIntervalSince1970:103))
        check(unread.count == 2, "only new answers since first launch count")
        var restoredUnread = UnreadReplies(lastRead:unread.lastRead,launchedAt:Date(timeIntervalSince1970:200))
        restoredUnread.update(receipts,open:false,now:Date(timeIntervalSince1970:200))
        check(restoredUnread.count == 2, "restart restores unread answers since persisted time")
        unread.update(receipts+[ChatReceipt(id:"user",fromUser:true,date:Date(timeIntervalSince1970:101.5))],open:false,now:Date(timeIntervalSince1970:103))
        check(unread.count == 1, "a newer user message from another device reads earlier answers")
        unread.update(receipts,open:true,now:Date(timeIntervalSince1970:103))
        check(unread.count == 0 && unread.lastRead == Date(timeIntervalSince1970:103), "opening reads all answers")
        unread.update(receipts,open:false,now:Date(timeIntervalSince1970:104))
        check(unread.count == 0, "closing never resurrects read answers")
        check(UnreadReplies.badge(0).isEmpty && UnreadReplies.badge(9) == "9" && UnreadReplies.badge(10) == "9+", "badge label limit")
        var activity = ChatReplyActivity()
        let waiting = TypingIndicator(id:"x",speaker:"위키담당",profile:"default")
        check(!activity.update(typing:[waiting],messages:[],now:launched), "typing begins without a reply jump")
        let incoming = ChatMessage(id:"default:jump",fromUser:false,speaker:"위키담당",body:"답",date:launched.addingTimeInterval(1),profile:"default")
        check(activity.update(typing:[],messages:[incoming],now:launched.addingTimeInterval(1)), "reply from a writing character triggers a jump")
        check(!activity.update(typing:[],messages:[incoming],now:launched.addingTimeInterval(2)), "same reply never triggers twice")

        // Timeline
        let stored = [message("a:1", user: true, "안녕", at: 100), message("b:1", "어 왔냐", at: 101, speaker: "보관담당"),
                      message("a:2", "일정 없다", at: 105)]
        let echo = message("pending:1", user: true, "내일  일정\n알려줘", at: 200, pending: true)
        var merged = ChatTimeline.merge(stored.reversed(), pending: [echo])
        check(merged.map(\.id) == ["a:1", "b:1", "a:2", "pending:1"], "profiles merge by time and the local echo stays last")
        let arrived = stored + [message("a:3", user: true, "내일 일정 알려줘", at: 201)]
        merged = ChatTimeline.merge(arrived, pending: [echo])
        check(merged.map(\.id) == ["a:1", "b:1", "a:2", "a:3"], "echo disappears once the record has the same text")
        check(ChatTimeline.unresolved([echo], stored: [message("a:0", user: true, "내일 일정 알려줘", at: 50)]).count == 1, "an older identical message does not resolve a new echo")
        check(ChatTimeline.unresolved([echo, echo], stored: arrived).count == 1, "one stored message resolves one echo")
        check(ChatTimeline.unresolved([echo], stored: [message("a:9", "내일 일정 알려줘", at: 201)]).count == 1, "a reply never resolves an echo")
        check(ChatTimeline.merge(stored + stored, pending: []).count == 3, "duplicate rows are dropped")
        check(ChatTimeline.merge(stored, pending: [], limit: 2).map(\.id) == ["b:1", "a:2"], "limit keeps the newest")

        // Preview and actions
        let bare = ChatText.linkified((try? AttributedString(markdown: "초안이야.\nobsidian://vault/starter_user1/01_wiki/_staging/2_entities/파이헬스케어\n참고: https://example.com/a?b=1. 그리고 [문서](https://example.org) 끝", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString())
        let bareLinks = bare.runs.compactMap { run in run.link.map { (String(bare[run.range].characters), $0.absoluteString) } }
        check(bareLinks.count == 3 && bareLinks[0].0 == "obsidian://vault/starter_user1/01_wiki/_staging/2_entities/파이헬스케어"
              && bareLinks[0].1.removingPercentEncoding == bareLinks[0].0 && !bareLinks[0].1.contains("파"), "bare Obsidian address becomes an encoded link")
        check(bareLinks[1].0 == "https://example.com/a?b=1" && bareLinks[1].1 == "https://example.com/a?b=1", "bare web address stops before closing punctuation")
        check(bareLinks[2].0 == "문서" && bareLinks[2].1 == "https://example.org", "marked-up links are kept as written")
        check(ChatText.linkified(AttributedString("obsidian://vault/a/b%20c file:///etc/hosts")).runs.compactMap(\.link).map(\.absoluteString) == ["obsidian://vault/a/b%20c"], "encoded spaces are not encoded twice and other schemes stay plain")
        let origin = ChatText.originHeader + #"{"platform":"photon","nested":{"note":"escaped \" }"}}"# + "\n" + ChatText.originFooter + "\n\n"
        check(ChatText.userVisible(origin + "원문 질문") == "원문 질문", "one valid nested JSON origin wrapper is stripped")
        check(ChatText.userVisible("[메모 수집: 내부 안내]\n\nㅁ 원문") == "ㅁ 원문", "known capture note is hidden")
        check(ChatText.userVisible("[메모 롤백: 내부 안내]\n취소") == "취소", "known rollback note is hidden")
        check(ChatText.userVisible("[#inbox 스레드 답글: 내부 안내]\n정정") == "정정", "known inbox reply note is hidden")
        check(ChatText.userVisible(origin + "[메모 수집: 내부]\n질문") == "질문", "stacked known wrappers are hidden")
        check(ChatText.userVisible("[나의 메모: 중요]\n글") == "[나의 메모: 중요]\n글", "unknown bracket text is preserved")
        check(ChatText.userVisible("본문\n[메모 수집: 인용]") == "본문\n[메모 수집: 인용]", "only leading notes are stripped")
        check(ChatText.userVisible(origin) == origin && ChatText.userVisible("[메모 수집: 안내]\n") == "[메모 수집: 안내]\n", "empty cleanup preserves original information")
        let invalidOrigin = ChatText.originHeader + "{invalid}\n" + ChatText.originFooter + "\n질문"
        check(ChatText.userVisible(invalidOrigin) == invalidOrigin, "invalid JSON is never stripped")
        check(ChatText.userVisible(ChatText.originHeader + "{}\n본문") == ChatText.originHeader + "{}\n본문", "incomplete origin marker is preserved")
        check(ChatTimeline.unresolved([echo], stored: [message("a:99", user: true, origin + "내일 일정 알려줘", at: 201)]).isEmpty, "pending matches the cleaned user body")
        check(ChatText.preview("\n## **특허** 쪽은 `2건`\n- 둘째 줄") == "특허 쪽은 2건", "preview is the first plain line")
        check(ChatText.preview("  \n") == "", "empty body has no preview")
        let linked = PetAction.content(in: "자료는 https://example.com/doc?id=1 에 있어.")
        check(linked.count == 1 && linked[0].kind == .openLink(URL(string: "https://example.com/doc?id=1")!), "link becomes a button")
        check(PetAction.content(in: "별 내용 없음").isEmpty && PetAction.content(in: "mailto:a@example.com").isEmpty, "plain text and mail links have no content buttons")
        check(PetAction.bubble(for: "별 내용 없음").map(\.kind) == [.openChat, .remindLater], "bubble always offers open and remind")
        let full = PetAction.bubble(for: "https://example.com 회의는 October 5, 2030 at 3:00 PM")
        check(full.count <= PetLayout.maximumActions && full.contains { $0.kind == .remindLater }, "bubble never exceeds three buttons")
        check(PetAction.bubble(for: "회의는 October 5, 2030 at 3:00 PM").map(\.kind) == [.openChat, .remindLater], "dates never create events")
        check(PetAction.bubble(for: "https://example.com").map(\.title) == ["링크 열기", "대화 열기", "나중에 알려줘"], "link comes first")
        check(PetAction.content(in: "일정은 October 5, 2030 at 3:00 PM 이야.").isEmpty, "schedule words and dates without a real event have no button")
        let day = Calendar.current.startOfDay(for: Date())
        let appointment = CalendarEntry(identifier: "synthetic-dental", calendarID: "test", title: "치과", start: day.addingTimeInterval(36000), end: day.addingTimeInterval(39600))
        let action = PetAction.content(in: "오늘 치과 예약이 있어.", events: [appointment], at: day)
        check(action == [PetAction(kind: .showCalendar([appointment]), title: "일정 보기")], "calendar action carries the real event identity and occurrence")
        check(PetAction.content(in: "강남역 주차장 24시간 운영(00:00~24:00), 평일 1시간권 4,000원. 일정 참고해.", events: [appointment], at: day).isEmpty, "parking hours do not match a personal event")

        check(ChatText.preview("***기초자료 검토 완료**") == "기초자료 검토 완료", "malformed nested emphasis is repaired")
        check(ChatText.preview("***정상 강조***와 *기울임*") == "정상 강조와 기울임", "valid nested emphasis renders plainly in preview")
        check(ChatText.normalizedMarkdown("2 * 3 = 6") == "2 * 3 = 6", "literal asterisk stays intact")
        func rendered(_ text: String) -> AttributedString { try! AttributedString(markdown: ChatText.normalizedMarkdown(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) }
        let ranges = rendered("- **10/6 화**\n  - 09:00~18:00 과정\n  - 10:00~11:00 미팅\n* 끝")
        check(String(ranges.characters) == "• 10/6 화\n  • 09:00~18:00 과정\n  • 10:00~11:00 미팅\n• 끝", "time ranges keep their tildes and list dashes become bullets")
        check(ranges.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.strikethrough) != true }, "a lone tilde never strikes text through")
        check(rendered("~~취소~~ 유지").runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }, "double tilde still strikes through")
        check(String(rendered("a - b, 3-4, -5").characters) == "a - b, 3-4, -5", "dashes inside a line stay dashes")
        check(HermesBridge.failure(code: -1743).automationDenied, "denial offers automation settings")
        check(HermesBridge.failure(code: -1744).automationDenied, "consent required offers automation settings")
        check(!HermesBridge.failure(code: -600).automationDenied, "other failures do not claim denial")

        // Nudges
        let t0 = Date(timeIntervalSince1970: 1000)
        var engine = NudgeEngine()
        let old = [message("a:1", "예전 답", at: 900)]
        check(engine.update(messages: old, now: t0, chatOpen: false, muted: false) == nil, "first poll only sets the baseline")
        check(engine.update(messages: old + [message("a:2", "지각 기록", at: 950)], now: t0.addingTimeInterval(2), chatOpen: false, muted: false) == nil, "messages before launch never nudge")
        let reply = message("a:3", "새 답", at: 1005), mine = message("a:4", user: true, "내 말", at: 1006)
        check(engine.update(messages: old + [mine], now: t0.addingTimeInterval(7), chatOpen: false, muted: false) == nil, "own messages never nudge")
        let shown = engine.update(messages: old + [reply, mine], now: t0.addingTimeInterval(8), chatOpen: false, muted: false)
        check(shown?.message.id == "a:3" && shown?.reminder == false, "a new reply nudges once")
        check(engine.update(messages: old + [reply, mine], now: t0.addingTimeInterval(19), chatOpen: false, muted: false) != nil, "nudge stays for its display time")
        check(engine.update(messages: old + [reply, mine], now: t0.addingTimeInterval(8 + NudgeEngine.displaySeconds), chatOpen: false, muted: false) == nil, "nudge expires")
        check(engine.update(messages: old + [reply, mine], now: t0.addingTimeInterval(60), chatOpen: false, muted: false) == nil, "the same reply is not repeated")
        let second = message("a:5", "둘째", at: 1100), third = message("b:1", "셋째", at: 1101, speaker: "보관담당")
        check(engine.update(messages: [reply, second, third], now: t0.addingTimeInterval(102), chatOpen: false, muted: false)?.message.id == "b:1", "several replies show only the newest")
        engine.remindLater(now: t0.addingTimeInterval(103))
        check(engine.current == nil && engine.reminders["b:1"] != nil, "remind later hides the nudge and schedules it")
        check(engine.update(messages: [reply, second, third], now: t0.addingTimeInterval(200), chatOpen: false, muted: false) == nil, "reminder waits for its time")
        let again = engine.update(messages: [reply, second, third], now: t0.addingTimeInterval(103 + NudgeEngine.remindAfter), chatOpen: false, muted: false)
        check(again?.message.id == "b:1" && again?.reminder == true && engine.reminders.isEmpty, "reminder fires once")
        let fourth = message("a:6", "넷째", at: 3000)
        check(engine.update(messages: [fourth], now: t0.addingTimeInterval(2001), chatOpen: true, muted: false) == nil, "open chat suppresses nudges")
        check(engine.update(messages: [fourth], now: t0.addingTimeInterval(2002), chatOpen: false, muted: false) == nil, "replies read in the open chat do not nudge later")
        let fifth = message("a:7", "다섯째", at: 3100)
        check(engine.update(messages: [fifth], now: t0.addingTimeInterval(2101), chatOpen: false, muted: true) == nil
              && engine.update(messages: [fifth], now: t0.addingTimeInterval(2102), chatOpen: false, muted: false) == nil, "hidden pet stays quiet")
        var restored = NudgeEngine(reminders: ["gone:1": t0])
        _ = restored.update(messages: [], now: t0, chatOpen: false, muted: false)
        check(restored.update(messages: old, now: t0.addingTimeInterval(1), chatOpen: false, muted: false) == nil && restored.reminders.isEmpty, "reminder for a pruned message is dropped")

        // Hermes record
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-hermes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = HermesBridge(home: home)
        if case .unavailable = bridge.poll().status { passed += 1 } else { check(false, "missing Hermes home is unavailable") }
        let schema = ["CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL)",
                      "CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_calls TEXT, timestamp REAL)",
                      "INSERT INTO sessions VALUES ('s1', 'photon'), ('s2', 'slack')"]
        makeStore(home.appendingPathComponent("state.db"), statements: schema + [
            "INSERT INTO messages VALUES (1, 's1', 'user', '특허 알려줘', NULL, 100)",
            "INSERT INTO messages VALUES (2, 's1', 'assistant', '', '[{}]', 101)",
            "INSERT INTO messages VALUES (3, 's1', 'tool', 'TOOL OUTPUT', NULL, 102)",
            "INSERT INTO messages VALUES (4, 's1', 'assistant', '출원 완료 2건', NULL, 103)",
            "INSERT INTO messages VALUES (5, 's2', 'assistant', 'SLACK ONLY', NULL, 104)",
            "INSERT INTO messages VALUES (6, 's1', 'session_meta', 'META', NULL, 105)"])
        try "display_name: '위키담당'\nui_meta: {}\n".write(to: home.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)
        let knight = home.appendingPathComponent("profiles/archive-helper")
        makeStore(knight.appendingPathComponent("state.db"), statements: schema + [
            "INSERT INTO messages VALUES (1, 's1', 'user', '테스트', NULL, 102.5)",
            "INSERT INTO messages VALUES (2, 's1', 'assistant', '정상.', NULL, 110)"])
        try "display_name: 보관담당\n".write(to: knight.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)
        makeStore(home.appendingPathComponent("profiles/broken/state.db"), statements: ["CREATE TABLE other (id INTEGER)"])
        let charactersOnly = bridge.poll(unreadSince: Date(timeIntervalSince1970: 0), includeMessages: false)
        check(charactersOnly.messages.isEmpty && charactersOnly.typing.isEmpty && charactersOnly.receipts.isEmpty
              && charactersOnly.sessionToken.isEmpty && bridge.rowsRead == 0, "character-only polling never reads photon messages, typing or receipts")
        check(charactersOnly.characters.contains(ChatCharacter(id: "default", name: "위키담당"))
              && charactersOnly.characters.contains(ChatCharacter(id: "archive-helper", name: "보관담당")), "character-only polling keeps display names without requiring a message schema")
        check(charactersOnly.status == .connected(stores: 3), "character-only status describes discovered character stores")
        var result = bridge.poll()
        check(result.status == .connected(stores: 2), "unknown store formats are skipped, not guessed")
        check(result.messages.map(\.id) == ["default:1", "archive-helper:1", "default:4", "archive-helper:2"], "only iMessage text turns, merged across profiles")
        let receiptPoll = bridge.poll(limit:1,unreadSince:Date(timeIntervalSince1970:100))
        check(receiptPoll.receipts.filter { !$0.fromUser }.count == 2 && receiptPoll.messages.count == 1, "unread metadata is independent of the visible message limit")
        check(result.messages.map(\.speaker) == ["", "", "위키담당", "보관담당"], "replies carry the profile display name")
        check(!result.messages.contains { $0.body.contains("TOOL") || $0.body.contains("SLACK") || $0.body.contains("META") }, "tool output and other platforms are never shown")
        let liveAssets = home.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: liveAssets, withIntermediateDirectories: true)
        let livePhoto = liveAssets.appendingPathComponent("avatar.png")
        try png(livePhoto, .blue)
        check(bridge.stores().first { $0.profile == "default" }?.avatarURL == livePhoto, "store resolves photos inside HERMES_HOME")
        let photoPoll = bridge.poll()
        check(photoPoll.avatars["default"]?.image != nil && photoPoll.messages.first?.profile == "default", "poll publishes avatars and explicit profile IDs")
        try Data("broken".utf8).write(to: livePhoto)
        check(bridge.poll().avatars["default"]?.image == nil, "avatar changes refresh even when database is unchanged")
        makeStore(knight.appendingPathComponent("state.db"), statements: ["INSERT INTO messages VALUES (3, 's1', 'assistant', '추가 답', NULL, 120)"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: knight.appendingPathComponent("state.db").path)
        result = bridge.poll()
        check(result.messages.last?.id == "archive-helper:3", "a changed store is read again")
        check(bridge.poll(limit: 2).messages.count == 2, "limit applies to the merged conversation")
        let onlyBroken = HermesBridge(home: home.appendingPathComponent("profiles/broken"))
        if case .unavailable = onlyBroken.poll().status { passed += 1 } else { check(false, "unreadable format is reported as unavailable") }

        // Read-only incremental polling: only new eligible rows are decoded.
        let interruptedHome = home.appendingPathComponent("interrupted-fixture")
        let escapedOrigin = (origin + "앞 질문").replacingOccurrences(of: "'", with: "''")
        makeStore(interruptedHome.appendingPathComponent("state.db"), statements: schema + [
            "INSERT INTO messages VALUES (1,'s1','user','\(escapedOrigin)',NULL,1)",
            "INSERT INTO messages VALUES (2,'s1','assistant','',NULL,2)"])
        let interruptedBridge = HermesBridge(home: interruptedHome)
        check(interruptedBridge.poll().messages.first?.body == "앞 질문", "read path cleans only the user's body")
        check(interruptedBridge.poll().messages.first?.replyInterrupted == false, "empty answer alone is not an interruption")
        makeStore(interruptedHome.appendingPathComponent("state.db"), statements: [
            "INSERT INTO messages VALUES (3,'s2','user','다른 세션',NULL,3)"])
        check(interruptedBridge.poll().messages.first?.replyInterrupted == false, "other session user cannot resolve the interruption predicate")
        makeStore(interruptedHome.appendingPathComponent("state.db"), statements: [
            "INSERT INTO messages VALUES (4,'s1','user','뒤 질문',NULL,4)",
            "INSERT INTO messages VALUES (5,'s1','assistant','[메모 수집: 답변 인용]',NULL,5)",
            "INSERT INTO messages VALUES (6,'s1','user','도구 사용 질문',NULL,6)",
            "INSERT INTO messages VALUES (7,'s1','assistant','', '[{}]',7)",
            "INSERT INTO messages VALUES (8,'s1','user','다음',NULL,8)"])
        let interruptedMessages = interruptedBridge.poll().messages
        check(interruptedMessages.first?.replyInterrupted == true, "incremental poll updates an earlier cached user after interruption")
        check(interruptedMessages.filter(\.replyInterrupted).map(\.id) == ["default:1"], "tool calls and nonempty replies are not interruptions")
        check(interruptedMessages.contains { $0.body == "[메모 수집: 답변 인용]" }, "assistant text is never stripped")
        check(interruptedBridge.search("앞 질문").first?.replyInterrupted == true, "search returns cleaned text and interruption marker")
        check(interruptedBridge.around(profile:"default",messageID:1).first?.replyInterrupted == true, "context fetch retains interruption marker")

        let incremental = HermesBridge(home: home)
        _ = incremental.poll()
        check(incremental.rowsRead > 0, "first poll reads initial history")
        _ = incremental.poll()
        check(incremental.rowsRead == 0, "unchanged poll decodes no message bodies")
        makeStore(knight.appendingPathComponent("state.db"), statements: ["INSERT INTO messages VALUES (4,'s1','assistant','delta',NULL,130)"])
        check(incremental.poll().messages.last?.body == "delta" && incremental.rowsRead == 1, "incremental poll reads only appended ID")

        // Turn leases and fallback; all writes below target this test's temporary home only.
        let clock = Date(timeIntervalSince1970: 500)
        makeStore(home.appendingPathComponent("state.db"), statements: [
            "CREATE TABLE session_turn_leases (conversation_id TEXT, holder TEXT, acquired_at REAL, expires_at REAL)",
            "INSERT INTO session_turn_leases VALUES ('s1','writer',450,550),('s2','slack-writer',450,550),('missing','orphan',450,550)"])
        check(bridge.poll(now: clock).typing.map(\.speaker) == ["위키담당"], "only live photon leases identify the writer")
        check(bridge.poll(now: Date(timeIntervalSince1970:550)).typing.isEmpty, "expiry is exclusive and evaluated even without database writes")
        makeStore(home.appendingPathComponent("state.db"), statements: ["INSERT INTO messages VALUES (7,'s1','assistant','완료',NULL,480)"])
        check(bridge.poll(now: clock).typing.isEmpty, "reply clears a still-live lease")
        makeStore(knight.appendingPathComponent("state.db"), statements: ["INSERT INTO messages VALUES (5,'s1','user','질문',NULL,490)"])
        check(bridge.poll(now: clock).typing.first?.id == "fallback", "missing lease table falls back to a recent user message")
        check(!bridge.poll(now: Date(timeIntervalSince1970:669.9)).typing.isEmpty, "fallback lasts less than three minutes")
        check(bridge.poll(now: Date(timeIntervalSince1970:670)).typing.isEmpty, "fallback stops at three minutes")
        check(bridge.poll(now: Date(timeIntervalSince1970:489)).typing.isEmpty, "future messages are not typing")
        makeStore(knight.appendingPathComponent("state.db"), statements: ["INSERT INTO messages VALUES (6,'s1','assistant','답변',NULL,495)"])
        check(bridge.poll(now: clock).typing.isEmpty, "reply clears fallback immediately")

        // Search uses literal bound LIKE and never searches tool output, Slack or metadata.
        makeStore(home.appendingPathComponent("state.db"), statements: [
            "ALTER TABLE messages ADD COLUMN display_kind TEXT",
            "INSERT INTO messages VALUES (8,'s1','assistant','특허관련내용 Alpha 100% a_b O''Reilly C:\\path',NULL,600,NULL)",
            "INSERT INTO messages VALUES (9,'s1','assistant','특허 메타',NULL,601,'session_meta')",
            "INSERT INTO messages VALUES (10,'s1','assistant','특허 도구 호출','[{}]',602,NULL)"])
        for term in ["특", "특허", "특허", "  특허  ", "alpha", "ALPHA", "%", "_", "O'Reilly", "\\path"] {
            check(bridge.search(term).contains { $0.id == "default:8" }, "literal substring search: \(term)")
        }
        check(bridge.search("%_").isEmpty, "wildcard characters cannot expand the query")
        check(bridge.search("' OR 1=1 --").isEmpty, "quoted query cannot change SQL")
        check(bridge.search("\n  ").isEmpty, "empty query avoids search")
        check(bridge.search("SLACK").isEmpty && bridge.search("TOOL").isEmpty && bridge.search("메타").isEmpty && bridge.search("도구 호출").isEmpty, "search has the same visibility filter as the timeline")
        check(HermesBridge.searchTerm("  특허 ") == "특허", "query is normalized to NFC")
        makeStore(knight.appendingPathComponent("state.db"), statements: ["INSERT INTO messages VALUES (7,'s1','assistant','특허 최신',NULL,700)"])
        check(bridge.search("특허").first?.id == "archive-helper:7", "search merges newest first across profiles")
        let nearby = bridge.around(profile:"default",messageID:8,count:2)
        check(nearby.map(\.id) == ["archive-helper:5","archive-helper:6","default:8","archive-helper:7"], "context merges the correct before and after messages across profiles")
        check(bridge.around(profile:"default",messageID:9).isEmpty, "metadata cannot be a context target")
        makeStore(knight.appendingPathComponent("state.db"), statements: (20..<2020).map {
            "INSERT INTO messages VALUES (\($0),'s1','assistant','합성 특허관련내용 \($0)',NULL,\(1000+$0))"
        })
        let searchStart = ProcessInfo.processInfo.systemUptime
        let found = bridge.search("특허")
        let searchMS = (ProcessInfo.processInfo.systemUptime-searchStart)*1000
        check(found.count == 200 && found.first?.rowID == 2019, "search caps the global newest results at 200")
        print("BENCH search ~2000 rows: \(searchMS) ms")
        let mid = bridge.around(profile:"archive-helper",messageID:1000,count:20)
        check(mid.count == 41 && mid.first?.rowID == 980 && mid.last?.rowID == 1020, "old target context has twenty rows on either side")
        let older = bridge.older(before:mid.first!,limit:40)
        check(older.count == 40 && older.last?.rowID == 979, "older page is exclusive and chronological")

        makeStore(home.appendingPathComponent("state.db"), statements:["INSERT INTO messages VALUES (11,'s1','assistant','동시각',NULL,800,NULL)"])
        makeStore(knight.appendingPathComponent("state.db"), statements:["INSERT INTO messages VALUES (8,'s1','assistant','동시각',NULL,800)"])
        let equal = bridge.around(profile:"default",messageID:11,count:1)
        check(equal.first?.id == "archive-helper:8" && equal[1].id == "default:11", "timestamp ties use the same profile/id order for context and paging")
        check(bridge.older(before:equal[1],limit:1).first?.id == "archive-helper:8", "equal-timestamp pagination never skips another profile")
        makeStore(knight.appendingPathComponent("state.db"),statements:["CREATE TABLE session_turn_leases (wrong TEXT)"])
        check(bridge.poll(now:Date(timeIntervalSince1970:999999)).status == .connected(stores:2), "incompatible lease schema does not disable conversation reading")

        // Sending
        check(HermesBridge.validHandle(" +1 628 555 0100 ") == "+16285550100" && HermesBridge.validHandle("agent@example.com") == "agent@example.com", "phone and mail handles")
        check(HermesBridge.validHandle("") == nil && HermesBridge.validHandle("a\" & do shell script \"x") == nil, "unsafe handles rejected")
        let script = HermesBridge.sendScript(text: "그는 \"안녕\\\" 했다", handle: "+16285550100")
        check(script.contains("send \"그는 \\\"안녕\\\\\\\" 했다\" to participant \"+16285550100\""), "message text cannot escape the script string")

        check(!script.contains("activate") && !script.contains("reopen"), "send script never activates or reopens Messages")
        check(script.hasPrefix("with timeout of \(HermesBridge.sendTimeout) seconds\n") && script.hasSuffix("end timeout") && HermesBridge.sendTimeout <= 15, "a Messages that does not answer is not waited on for long")
        check(ChatText.mayOpen(URL(string: "https://example.com/a")!) && ChatText.mayOpen(URL(string: "HTTP://example.com")!) && ChatText.mayOpen(URL(string: "mailto:a@example.com")!) && ChatText.mayOpen(URL(string: "obsidian://vault/a")!),
              "web pages, letters and notes open from the conversation")
        check(!ChatText.mayOpen(URL(string: "file:///Users/x/run.command")!) && !ChatText.mayOpen(URL(string: "smb://host/share")!) && !ChatText.mayOpen(URL(string: "shortcuts://run-shortcut?name=x")!) && !ChatText.mayOpen(URL(string: "x-apple.systempreferences:")!),
              "a marked-up link to a file, a share or another app's command is not followed")
        for running in [false, true] {
            for owned in [false, true] {
                for hidden in [false, true] {
                    let policy = HermesBridge.messagesAppPolicy(isRunning: running, launchedByPet: owned, isHidden: hidden)
                    check(policy.shouldLaunch == !running, "only an absent Messages app needs launch")
                    check(policy.shouldHideAfterSend == (running && owned && !hidden), "only this send's newly launched visible app is hidden")
                }
            }
        }

        // Slack activity
        let slackHome = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-slack-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: slackHome) }
        makeStore(slackHome.appendingPathComponent("state.db"), statements: [
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, chat_id TEXT, thread_id TEXT)",
            "CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_calls TEXT, timestamp REAL)",
            "CREATE TABLE session_turn_leases (conversation_id TEXT, holder TEXT, acquired_at REAL, expires_at REAL)",
            "INSERT INTO sessions VALUES ('a','slack','C1','100.1'),('b','slack','C1','200.2'),('c','photon','dm',NULL),('d','slack','C2',NULL),('e','slack','C1','100.1')",
            "INSERT INTO messages VALUES (1,'a','user','x',NULL,900),(2,'b','assistant','y',NULL,10),(3,'c','user','z',NULL,990),(4,'e','assistant','w',NULL,950)",
            "INSERT INTO session_turn_leases VALUES ('a','w',940,1100),('b','w',10,20),('c','w',940,1100)"])
        makeStore(slackHome.appendingPathComponent("profiles/old/state.db"), statements: [
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL)",
            "CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_calls TEXT, timestamp REAL)"])
        let activityBridge = HermesBridge(home: slackHome, makesImages: false)
        let slackActivity = activityBridge.slackActivity(now: Date(timeIntervalSince1970: 1_000), window: 500)
        check(slackActivity.writers == [SlackActivity.Writer(profile: "default", name: "Hermes", room: "C1", thread: "100.1", since: 940)], "only a live turn in a Slack thread counts as writing")
        check(slackActivity.recent == [SlackActivity.Recent(room: "C1", thread: "100.1", at: 950)], "recent Slack threads carry their newest activity, and a record without thread columns is skipped")

        let reads = activityBridge.activityReads
        check(activityBridge.slackActivity(now: Date(timeIntervalSince1970: 1001), window: 500) == slackActivity && activityBridge.activityReads == reads, "unchanged activity reuses the database result")
        check(activityBridge.slackActivity(now: Date(timeIntervalSince1970: 1100), window: 500).writers.isEmpty, "cached writer expires without a database write")
        check(activityBridge.slackActivity(now: Date(timeIntervalSince1970: 1450), window: 500).recent.isEmpty, "cached recent activity expires without a database write")
        makeStore(slackHome.appendingPathComponent("state.db"), statements: ["INSERT INTO messages VALUES (5,'a','assistant','synthetic',NULL,1451)"])
        check(activityBridge.slackActivity(now: Date(timeIntervalSince1970: 1452), window: 500).recent.first?.at == 1451, "database changes invalidate the activity cache")
        let projectHome = FileManager.default.temporaryDirectory.appendingPathComponent("project-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: projectHome) }
        let projectBridge = HermesBridge(home: projectHome, makesImages: false)
        let projectFile = projectHome.appendingPathComponent("shared/project-threads.sqlite3")
        check(projectBridge.projects().isEmpty && !FileManager.default.fileExists(atPath: projectFile.path), "reading absent project state never creates a database")
        let projectJSON = #"{"id":"p1","scope_id":"T1","chat_id":"C1","thread_id":"100.1","owner_id":"U1","title":"행사 준비","goal":"자료 확인과 초안","status":"open","current_profile":"personal-secretary","updated_at":1,"tasks":[{"id":"t1","profile":"work-assistant","title":"자료 확인","status":"recorded","summary":"자료 확인함","next_step":"초안 작성","references":["https://example.invalid/source"]}],"decisions":[{"text":"일정 확정","message_id":"100.2"}],"facts":[],"approvals":[{"id":"abc","profile":"personal-secretary","status":"pending","preview_text":"수신자·본문","expires_at":9999999999}]}"#
        makeStore(projectFile, statements: ["CREATE TABLE projects (id TEXT PRIMARY KEY,data TEXT NOT NULL)", "INSERT INTO projects VALUES ('p1','" + projectJSON + "')"])
        let projects = projectBridge.projects()
        check(projects.count == 1 && projects[0].currentProfile == "personal-secretary", "server project identity and current owner survive snake-case JSON")
        check(projects.first?.tasks.first?.nextStep == "초안 작성" && projects.first?.decisions?.first?.text == "일정 확정", "shared records preserve handoff and decisions")
        check(projects.first?.statusText == "진행 중" && projects.first?.approvals?.first?.pending == true, "recorded output does not mark a task completed; only live approvals are actionable")
        check(projectBridge.projects() == projects, "unchanged project database is stable on repeated polling")
        makeStore(projectFile, statements: ["UPDATE projects SET data=json_set(data,'$.status','completed','$.updated_at',2)"])
        check(projectBridge.projects().first?.statusText == "프로젝트 완료", "project database changes invalidate the projection cache")
        checkSlowSends()
        print("PASS: \(passed) conversation, action, nudge, Hermes record and sending checks")
    }
}
