import AppKit
import SwiftUI

extension AppDelegate {
    /// The pet shows no menu bar, so dialogs such as the token field had no Edit menu to carry ⌘V and friends.
    /// A main menu works for its shortcuts even though it is never drawn.
    func installEditMenu() {
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        let item = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        item.submenu = edit
        main.addItem(NSMenuItem()) // The first item is the application menu.
        main.addItem(item)
        NSApp.mainMenu = main
    }

    @objc func configureSlack() {
        guard !slack.closing else { return }
        let dialog = SlackConnectDialog(connected: slack.connected)
        NSApp.activate(ignoringOtherApps: true)
        let response = dialog.runModal()
        guard !slack.closing else { return }
        switch response {
        case .alertFirstButtonReturn:
            let typed = dialog.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed.isEmpty && slack.connected { return }
            guard let token = SlackAPI.validToken(typed) else {
                slackResult("토큰 형식을 확인해 주세요. xoxp-로 시작하는 사용자 토큰이어야 해요. 봇 토큰(xoxb-)으로는 내 이름으로 답글을 달 수 없어요."); return
            }
            slack.connect(token: token) { [weak self] failure in
                guard let self else { return }
                if let failure { self.slackResult(failure); return }
                self.slack.model.source = .slack
                self.showChat()
            }
        case .alertThirdButtonReturn: slack.disconnect()
        default: return
        }
    }
    private func slackResult(_ text: String) {
        guard !slack.closing else { return }
        let alert = NSAlert(); alert.messageText = "슬랙에 연결하지 못했어요"; alert.informativeText = text
        alert.addButton(withTitle: "다시 입력"); alert.addButton(withTitle: "닫기")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { configureSlack() }
    }
}

extension AppDelegate {
    /// A field in an ordinary window stands in for the token dialog. The clipboard is put back afterwards.
    func verifyDialogPaste() -> Bool {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSSecureTextField(frame: NSRect(x: 10, y: 18, width: 220, height: 24))
        window.contentView?.addSubview(field); window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
        defer { window.close(); panel.makeKeyAndOrderFront(nil) }
        // Without the keyboard focus there is nothing to paste into; another app is holding it.
        guard window.isKeyWindow else { return true }
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        defer {
            board.clearContents()
            board.writeObjects(saved.map { pairs in let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1, forType: $0.0) }; return item })
        }
        board.clearContents(); board.setString("xoxp-smoke-paste", forType: .string)
        let paste = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        return NSApp.mainMenu?.performKeyEquivalent(with: paste) == true && field.stringValue == "xoxp-smoke-paste"
    }
}

/// Explicit UI test mode only; answers come from memory and nothing is sent.
enum SlackSmokeFixture {
    /// With `ddots`, each character also has a direct conversation, as the real workspace does.
    /// `--ui-smoke-ddots-hub` adds the channel all of them share.
    static func api(now: Date = Date(), ddots: Bool = false) -> SlackAPI {
        let hub = ddots && CommandLine.arguments.contains("--ui-smoke-ddots-hub")
        func stamp(_ secondsAgo: Double) -> String { String(format: "%.6f", now.timeIntervalSince1970 - secondsAgo) }
        func line(_ ago: Double, _ text: String, bot: String? = nil, thread: Double? = nil, replies: Int = 0, latest: Double? = nil, status: (String, String)? = nil) -> [String: Any] {
            var message: [String: Any] = ["ts": stamp(ago), "text": text, "user": bot == nil ? "UME" : "UBOT"]
            if let status { message["attachments"] = [["color": status.0, "text": status.1]] }
            if let bot { message["bot_profile"] = ["name": bot] }
            if let thread { message["thread_ts"] = stamp(thread) }
            if replies > 0 { message["reply_count"] = replies; message["thread_ts"] = stamp(ago); message["latest_reply"] = stamp(latest ?? ago) }
            return message
        }
        var cow: [[String: Any]] = [
            line(7200, ":white_check_mark: `guest_one`한테서 인스타그램 DM 왔어.\n&gt; 오늘 행사 예약이 필요한가요?", bot: "SNS담당", replies: 2, latest: 30, status: ("#2EB67D", ":white_check_mark: 답변 완료")),
            line(3600, ":large_yellow_circle: `guest_two`가 주차 위치를 물어봤어. *답장 초안*을 만들까?", bot: "SNS담당", replies: 5, latest: 600, status: ("#ECB22E", "초안 올려놨어. 승인 기다리는 중")),
line(300, "내일 오전 일정 정리해서 알려줘", replies: 1, latest: 280),
            ["ts": stamp(200), "user": "UBOT", "bot_profile": ["name": "SNS담당"], "text": "주차 안내에 쓸 자료야.", "files": [
                ["id": "FIMG", "name": "주차장 안내.png", "mimetype": "image/png", "size": 48_213, "url_private_download": "https://files.slack.com/files/parking.png", "thumb_360": "https://files.slack.com/thumbs/parking.png"],
                ["id": "FPDF", "name": "행사 안내문.pdf", "mimetype": "application/pdf", "size": 1_240_000, "url_private_download": "https://files.slack.com/files/guide.pdf"]]],
            line(180, "어제 새로 기억하거나 바꾼 답변 원칙 2건이야.\n이 스레드에 `학습승인`, `학습거절`로 답해 줘. 번호별 수정·삭제도 알려줘.\n1. 운영 안내는 확인한 자료를 기준으로 답한다.\n2. 예약 문의에는 예약 방법을 안내한다.", bot: "SNS담당"),
            line(120, "문의가 하나 더 들어왔어. <https://example.com/dm|원문 보기>", bot: "SNS담당", status: ("#E01E5A", "아직 답 안 함")),
        ]
        var replies: [String: [[String: Any]]] = [
            stamp(7200): [line(7100, "예약은 필요 없다고 답했어.", bot: "SNS담당", thread: 7200, status: ("#2EB67D", "종결")), line(30, "◐ 생각 중...", bot: "personal-secretary", thread: 7200)],
            stamp(300): [line(280, "내일 **10월 6일** 오전에는 일정이 없어.", bot: "개인비서", thread: 300)],
            stamp(9000): [
                line(8900, "내일 **10월 6일** 오전 일정이야.\n- 10:00 치과\n- 11:30 팀 점검", bot: "개인비서", thread: 9000),
                line(8800, "치과는 오후로 옮겨줘", thread: 9000),
                line(8700, "옮겼어. 오후 3시로 잡았어.", bot: "개인비서", thread: 9000),
            ],
            stamp(5400): [line(5300, "응, 만들어줘", thread: 5400), line(5200, "초안이야.\n&gt; 건물 뒤편 공영 주차장을 이용해 주세요.", bot: "SNS담당", thread: 5400)],
            stamp(400): [line(380, "오늘은 12만 토큰 썼어.", bot: "진단담당", thread: 400)],
            // `--ui-smoke-ddots-quiet` shows the room with nobody writing.
            stamp(700): [CommandLine.arguments.contains("--ui-smoke-ddots-quiet")
                ? line(690, "세 건 진행 중이고 막힌 건 없어.", bot: "위키담당", thread: 700) : line(690, "◐ 생각 중...", bot: "위키담당", thread: 700)],
            stamp(3600): [
                line(3500, "응, 초안 만들어줘", thread: 3600),
                line(3400, "초안이야.\n&gt; 건물 뒤편 공영 주차장을 이용해 주세요.", bot: "SNS담당", thread: 3600),
                line(3300, "영어로도 한 줄 붙여줘", thread: 3600),
                line(3200, "붙였어. 승인하면 이대로 보낼게.", bot: "SNS담당", thread: 3600),
                line(600, "보냈어. 답장 오면 다시 알려줄게.", bot: "SNS담당", thread: 3600),
            ],
        ]
        if CommandLine.arguments.contains("--ui-smoke-talk") {
            var root = line(90, "네이버 톡톡 처리 알림", bot: "SNS담당", replies: 1, latest: 5)
            root["blocks"] = [["type": "section", "text": ["type": "plain_text", "text": "톡톡 NT-demo · 승인 대기\n받은 글: 주차할 수 있나요?\n답장 초안: 안내된 주차장을 이용해 주세요."]]]
            var followup = line(5, "네이버 톡톡 처리 알림", bot: "SNS담당", thread: 90)
            followup["subtype"] = "thread_broadcast"
            followup["blocks"] = [["type": "section", "text": ["type": "plain_text", "text": "톡톡 NT-demo · 승인 대기\n받은 글: 예약도 필요한가요?\n답장 초안: 일반 관람은 예약이 필요 없습니다.\n이 스레드에 승인 또는 ㅇㅇ이라고 답해 줘."]]]
            cow += [root, followup]
            replies[stamp(90)] = [followup]
        }
        // `--ui-smoke-layout`: a report laid out as Hermes posts it, a title over coloured block attachments.
        if CommandLine.arguments.contains("--ui-smoke-layout") {
            func words(_ text: String, bold: Bool = false) -> [String: Any] { ["type": "text", "text": text, "style": ["bold": bold]] }
            func section(_ parts: [[String: Any]]) -> [String: Any] { ["type": "rich_text_section", "elements": parts] }
            func list(_ items: [String], indent: Int = 0) -> [String: Any] {
                ["type": "rich_text_list", "style": "bullet", "indent": indent, "elements": items.map { section([words($0)]) }]
            }
            func cell(_ text: String) -> [String: Any] { ["type": "rich_text", "elements": [section([words(text)])]] }
            var root = line(60, "주차 문의 처리 보고", bot: "SNS담당")
            root["blocks"] = [["type": "header", "text": ["type": "plain_text", "text": "주차 문의 처리 보고"]]]
            root["attachments"] = [
                ["color": "#9AA0A6", "blocks": [["type": "rich_text", "elements": [
                    section([words("개요", bold: true)]),
                    list(["guest_one이 주차 위치와 예약 필요 여부를 물어봤어. 창이 좁아도 줄이 바뀐 뒤 글머리표 뒤 글자에 맞춰져야 해."]),
                    section([words("    ↳ 원문 받은 시각 18:12, 인스타그램 DM으로 들어온 문의를 그대로 옮겼어.")]),
                    ["type": "rich_text_quote", "elements": [words("안녕하세요, 주차는 어디에 하면 되나요? 예약도 필요한가요?")]]]]]],
                ["color": "#2EB67D", "blocks": [["type": "rich_text", "elements": [section([words("체크 필요", bold: true)]), list(["아래 표를 확인해 줘."])]],
                    ["type": "table", "column_settings": [["align": "left"], ["align": "left"], ["align": "center"]], "rows": [
                        [cell("항목"), cell("담당"), cell("기한")], [cell("답장 초안 승인"), cell("SNS담당"), cell("오늘 18:00")],
                        [cell("주차장 안내 지도 첨부 여부와 영문 안내 한 줄 추가"), cell("SNS담당"), cell("—")]]]]],
                ["color": "#E01E5A", "blocks": [["type": "rich_text", "elements": [section([words("중요도 높음", bold: true)]),
                    list(["승인 없이 보내지 않았어."]), ["type": "rich_text_preformatted", "elements": [words("instagram_dm: waiting for approval")]]]]]],
            ]
            cow.append(root)
        }
        // Any file address answers with a small made-up picture.
        let picture: Data = {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 150, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<150 { for x in 0..<240 {
                let pixel = bitmap.bitmapData!.advanced(by: y * bitmap.bytesPerRow + x * 4)
                let road = (y > 60 && y < 90) || (x > 100 && x < 130)
                pixel[0] = road ? 70 : 96; pixel[1] = road ? 74 : 168; pixel[2] = road ? 82 : 120; pixel[3] = 255
            } }
            return bitmap.representation(using: .png, properties: [:]) ?? Data()
        }()
        return SlackAPI(transport: transport, raw: { _, body in body == nil ? .success(picture) : .failure(.network("")) })
        func transport(_ method: String, _ parameters: [String: String]) -> Result<Data, SlackAPI.Failure> {
            var body: [String: Any] = ["ok": true]
            switch method {
            case "search.messages": body["messages"] = ["matches": []]
            case "auth.test": body["user_id"] = "UME"; body["url"] = "https://ddots-smoke.slack.com/"
            case "users.conversations":
                let rooms: [[String: Any]] = [["id": "CCOW", "name": "SNS담당방"], ["id": "CTRUTH", "name": "검토 채널"], ["id": "CTEAM", "name": "teamstarter_user"], ["id": "Dassistant", "is_im": true, "user": "Uassistant"]]
                let direct: [[String: Any]] = [["id": "DDS", "is_im": true, "user": "UDS"], ["id": "DCOW", "is_im": true, "user": "UCOW"],
                                               ["id": "DJANG", "is_im": true, "user": "UJANG"], ["id": "DRACCOON", "is_im": true, "user": "URACCOON"]]
                body["channels"] = (ddots ? rooms + direct : rooms) + (hub ? [["id": "CHUB", "name": "workspace"]] : [])
            case "conversations.history":
                switch parameters["channel"] {
                case "CCOW": body["messages"] = cow
                case "CTRUTH": body["messages"] = [line(5000, "오늘 일정 정리했어.", bot: "위키담당"), line(4000, "위키 초안 올렸어.", bot: "진단담당"), line(3000, "로그 점검 끝.", bot: "진단담당"),
                                                   line(2000, "문의 2건 처리했어.", bot: "SNS담당"), line(900, "오늘 점검 결과 공유할게.", bot: "개인비서")]
                case "Dassistant" where ddots: body["messages"] = [
                    line(9000, "내일 오전 일정 정리해서 알려줘", replies: 3, latest: 8700),
                    line(1500, ":books: 위키 점검 끝났어. GitHub 백업 대기 2건이야.\n승인하면 백업할게.", bot: "개인비서"),
                    line(60, "고마워, 저녁에 한 번 더 알려줘")]
                case "DCOW" where ddots: body["messages"] = [line(5400, ":large_yellow_circle: `guest_two`가 주차 위치를 물어봤어. *답장 초안*을 만들까?", bot: "SNS담당", replies: 2, latest: 5200)]
                case "DDS" where ddots: body["messages"] = [line(700, "오늘 팀 진행 상황 요약해줘", replies: 1, latest: 690)]
                case "DJANG" where ddots: body["messages"] = [["ts": stamp(240), "user": "UBOT", "bot_profile": ["name": "진단담당"], "text": "어제 발송분 점검 끝. 이상 없어.", "files": [
                    ["id": "FREPORT", "name": "점검 보고서.pdf", "mimetype": "application/pdf", "size": 318_000, "url_private_download": "https://files.slack.com/files/report.pdf"]]]]
                case "CHUB" where hub: body["messages"] = [line(400, "오늘 토큰 얼마나 썼어?", replies: 1, latest: 380), line(50, "아무나 대답해줘")]
                case "DRACCOON" where ddots: body["messages"] = [line(100, "연구담당은 ddots에 없어.", bot: "연구담당")]
                case "Dassistant": body["messages"] = [line(8000, "따로 확인할 게 있어.", bot: "개인비서")]
                default: body["messages"] = []
                }
            case "conversations.replies": body["messages"] = replies[parameters["ts"] ?? ""] ?? []
            case "users.info":
                let names = ["UDS": "위키담당", "Uassistant": "개인비서", "UHUMAN": "테스트 참여자", "UCOW": "SNS담당", "UJANG": "진단담당", "URACCOON": "연구담당"]
                body["user"] = ["real_name": names[parameters["user"] ?? ""] ?? "starter_user"]
            case "conversations.members":
                let rooms = ["CHUB": ["UME", "UJANG", "UCOW", "Uassistant", "UDS"], "CCOW": ["UME", "UCOW"], "CTRUTH": ["UME", "UJANG", "UCOW", "UHUMAN", "Uassistant", "UDS"], "CTEAM": ["UME"]]
                body["members"] = rooms[parameters["channel"] ?? ""] ?? []
            default: body = ["ok": false, "error": "unknown_method"]
            }
            return .success((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        }
    }
}

extension AppDelegate {
    func startSlackSmoke() {
        slack.persists = false
        slack.model.clipboard = NSPasteboard.withUniqueName()
        slack.model.source = .slack
        smokeCheck(slackWide && !slack.connected && pet.chatSize.width == preferredChatSize.width + SlackSidebar.width, "Choosing Slack widens the window even before it is connected")
        if IMessageFeature.enabled {
            slack.model.source = .imessage
            smokeCheck(pet.chatSize.width == preferredChatSize.width, "Going back returns to the iMessage width")
        }
        if CommandLine.arguments.contains("--ui-smoke-slack-unconnected") { slack.model.source = .slack; return }
        slack.characters = chat.characters
        slack.lastRead = ["CCOW": Date().timeIntervalSince1970 - 1800, "CTRUTH": Date().timeIntervalSince1970 - 1800, "CTEAM": 0, "Dassistant": Date().timeIntervalSince1970]
        slack.model.selected = "CCOW"
        if CommandLine.arguments.contains("--ui-smoke-slack-hang") {
            let script = SlackHangScript(); SlackHangScript.current = script
            slack.start(script.api)
        } else if CommandLine.arguments.contains("--ui-smoke-slack-limit") {
            let script = SlackLimitScript(); SlackLimitScript.current = script
            slack.start(script.api)
        } else if CommandLine.arguments.contains("--ui-smoke-slack-send") {
            let script = SlackSendScript(workspace: "https://ddots-smoke.slack.com/")
            SlackSendScript.current = script
            slack.start(script.api)
        } else {
            if Self.closingKind != nil {
                // The cache and any file opened go to a scratch folder; the workspace counts what it is asked.
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-closing-smoke-" + UUID().uuidString)
                try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                slack.scratchCache = scratch.appendingPathComponent("slack-cache.json")
                slack.store = SlackFileStore(root: scratch.appendingPathComponent("files"))
                let script = ClosingScript(); ClosingScript.current = script
                slack.start(script.api)
            } else if CommandLine.arguments.contains("--ui-smoke-room") {
                let script = SlackEntryScript(); SlackEntryScript.current = script
                slack.start(script.api)
            } else { slack.start(SlackSmokeFixture.api()) }
        }
        slack.model.source = .slack
        // The smoke timer does not poll, so the made-up rooms are read here.
        for delay in [0.3, 0.7, 1.1, 1.5, 1.9] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.slack.tick() } }
    }
    func verifySlack(destination: URL) {
        func check(_ condition: Bool, _ message: String) { if !condition { smokeFailed(message) } }
        let model = slack.model
        if let script = SlackHangScript.current { Task { @MainActor in await verifySlackHang(destination: destination, script: script) }; return }
        if let script = SlackSendScript.current { Task { @MainActor in await verifySlackSend(destination: destination, script: script) }; return }
        if let script = SlackLimitScript.current { Task { @MainActor in await verifySlackLimit(destination: destination, script: script) }; return }
        if let kind = Self.closingKind { Task { @MainActor in await verifyClosing(destination: destination, kind: kind) }; return }
        // `--ui-smoke-room-faces` runs the room pictures check on its own, without the checks that come before it.
        if CommandLine.arguments.contains("--ui-smoke-room-faces") { verifyRoomFaces(destination: destination); return }
        if CommandLine.arguments.contains("--ui-smoke-talk") {
            let matches = model.threads.filter { $0.root.body.contains("NT-demo") }
            check(matches.count == 1 && model.threads.last?.id == matches.first?.id, "Same TalkTalk ID stays in one thread at latest inquiry position")
            guard let thread = matches.first else { smokeFailed("TalkTalk thread missing"); return }
            check(thread.replies.contains { $0.body.contains("답장 초안: 일반 관람") }, "TalkTalk body blocks reach the visible conversation")
            model.reply(thread)
            check(model.target?.id == thread.id, "Approval composer targets the original customer thread")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.capture(destination: destination.appendingPathComponent("talk-thread"))
                try? "PASS: TalkTalk blocks, same-ID grouping, channel order and reply target\n".write(to: destination.appendingPathComponent("talk.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--ui-smoke-layout") {
            guard let thread = model.threads.first(where: { $0.root.body.contains("주차 문의 처리 보고") }) else { smokeFailed("layout report missing"); return }
            check(thread.root.quoteColors == ["#9AA0A6", "#2EB67D", "#E01E5A"] && thread.root.body.contains("> | 항목 | 담당 | 기한 |") && thread.root.body.contains("> > 안녕하세요"),
                  "A Block Kit report keeps its attachments' colours, its table and its quote: \(thread.root.quoteColors) \(thread.root.body)")
            // A report naming an event on the calendar is still laid out with its bars, the calendar button under it.
            let now = Date()
            chat.calendarEvents = [CalendarEntry(identifier: "synthetic-layout", calendarID: "fixture", title: "주차 문의 처리 보고", start: now,
                                                 end: now.addingTimeInterval(3600), calendar: "합성 일정", location: "", notes: "")]
            check(chat.actions(for: thread.root).contains { $0.isCalendar }, "The layout report names the synthetic calendar event")
            model.requestScroll(thread.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.capture(destination: destination.appendingPathComponent("layout-report"))
                self.chat.toggleReply(thread.root.id)
                model.requestScroll(thread.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                self.capture(destination: destination.appendingPathComponent("layout-report-open"))
                try? "PASS: report attachments, colours, table and quote reach the conversation\n".write(to: destination.appendingPathComponent("layout.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        verifyShrimpVaultSmoke()
        if CommandLine.arguments.contains("--ui-smoke-vault-design") { verifyVaultIcons(destination: destination); return }
        if CommandLine.arguments.contains("--ui-smoke-drive") { verifySynologyLinks(destination: destination); return }
        if CommandLine.arguments.contains("--ui-smoke-vault") { showShrimpVaultSmoke(destination: destination); return }
        check(verifyDialogPaste(), "⌘V reaches a dialog's text field through the Edit menu")
        let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        if CommandLine.arguments.contains("--ui-smoke-slack-unconnected") {
            check(!slack.connected && model.rooms.isEmpty && slackWide, "Before connecting, the Slack side shows the empty strip and the way to connect")
            capture(destination: destination.appendingPathComponent("slack-unconnected"))
            try? "slack unconnected smoke passed\n".write(to: destination.appendingPathComponent("slack.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil); return
        }
        check(Set(model.rooms.map(\.name)) == ["teamstarter_user", "검토 채널", "SNS담당방", "개인비서"] && model.selected == "CCOW", "Rooms are listed and the chosen one stays selected: \(model.rooms)")
        check(model.threads.count == 6, "Six threads are shown: \(model.threads.count)")
        check(model.notices.map(\.title) == ["답 안 한 DM", "SNS담당 질문", "알림"] && model.notices.map(\.threads.count) == [1, 2, 1], "The room's notice counts the posts still waiting: \(model.notices)")
        if let question = model.notices.first(where: { $0.id.hasPrefix(SlackNotice.questionID) }) { model.jump(question); check(model.open == [model.threads[1].id] && model.picked == model.threads[1].id && model.target?.id == model.threads[1].id, "Pressing a character's question opens the thread that asks, picks it and readies a reply"); model.foldAll() }
        check(model.roomNotices["CCOW"] == SlackModel.RoomNotice(alerts: 1, questions: 2), "The strip marks the room's questions and notifications: \(model.roomNotices)")
        if let alert = model.notices.first(where: { $0.id == SlackNotice.alertID }), let id = alert.threads.first, let thread = model.threads.first(where: { $0.id == id }) {
            model.jump(alert)
            check(!model.notices.contains { $0.id == SlackNotice.alertID } && model.bells[id] == false && model.roomNotices["CCOW"] == SlackModel.RoomNotice(alerts: 0, questions: 2),
                  "Going to a notification's thread clears it from the bar and the strip, keeping a quiet bell: \(model.notices.map(\.title))")
            model.onBell?(thread)
            check(model.notices.map(\.title) == ["답 안 한 DM", "SNS담당 질문", "알림"], "Its bell puts the notification back")
            model.foldAll()
        }
        if let waiting = model.notices.first { model.jump(waiting); check(model.flash == model.threads.last?.id && model.scrollTarget == model.threads.last?.id, "Pressing a count goes to that post") ; model.foldAll() }
        let shared = model.threads[3].root
        check(shared.files.map(\.name) == ["주차장 안내.png", "행사 안내문.pdf"], "A post's files come with it: \(shared.files)")
        slack.store = SlackFileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("ddots-slack-smoke-\(UUID().uuidString)"))
        SmokeLeftovers.note(slack.store.root)
        slack.loadThumb(shared.files[0]); slack.open(shared.files[1], in: shared)
        check(model.busyFiles == ["FPDF"], "A pressed file shows that it is being saved")
        let long = model.threads[1]
        check(long.loaded && long.replies.count == 5 && long.root.profile == "sns-manager", "The long thread has its replies and its character")
        check(long.root.marks == [ChatMark(color: "#ECB22E", text: "초안 올려놨어. 승인 기다리는 중")] && model.threads.last?.root.marks.first?.color == "#E01E5A", "A post keeps its status colour and label")
        check(SlackStack.visible(long, expanded: model.open.contains(long.id)).hidden == 4, "A long thread starts stacked")
        let address = "https://ddots-smoke.slack.com/archives/CCOW/p" + long.ts.filter { $0 != "." } + "?thread_ts=" + long.ts + "&cid=CCOW"
        check(model.link(to: long) == address, "A thread has its address in Slack: \(String(describing: model.link(to: long)))")
        check(slack.follow(URL(string: address)!) && model.picked == long.id && model.open.contains(long.id) && model.scrollTarget == long.id,
              "A link to a thread of this workspace goes to that thread in the window")
        check(!slack.follow(URL(string: "https://example.com/archives/CCOW/p1791000000123456")!) && !slack.follow(URL(string: "https://ddots-smoke.slack.com/archives/CNONE/p1791000000123456")!),
              "Another site's address, or a room that is not listed, is left to open as any link does")
        model.foldAll()
        var branched: [String] = []
        let sending = model.onSend
        model.onSend = { text, room, thread, _ in branched.append(text + " " + room + " " + (thread?.ts ?? "")) }
        model.branch(long); model.branch(long)
        check(branched == [SlackNotice.branchText + " CCOW " + long.ts] && model.branching == long.id, "분기 asks Hermes once, in the thread, to carry it on: \(branched)")
        model.onSend = sending
        var askedToDelete: [String] = []
        let deleting = model.onDelete
        model.onDelete = { askedToDelete.append($0.id) }
        model.delete(long)
        check(askedToDelete.isEmpty && model.confirmingDelete == long.id, "The first press of 삭제 only asks")
        model.delete(long)
        check(askedToDelete == [long.id] && model.confirmingDelete == nil, "The second press deletes the thread: \(askedToDelete)")
        model.onDelete = deleting
        model.copyLink(long)
        check(model.clipboard.string(forType: .string) == address && model.copied == "link-" + long.id, "링크 puts that address on the clipboard")
        model.copy(long)
        let copiedThread = model.clipboard.string(forType: .string) ?? ""
        check(copiedThread.hasPrefix("#SNS담당방 스레드 · 글 6개\n" + address + "\n\n[") && copiedThread.contains("[초안 올려놨어. 승인 기다리는 중]") && model.copied == "copy-" + long.id
              && ["주차 위치를 물어봤어", "응, 초안 만들어줘", "영어로도 한 줄 붙여줘", "보냈어. 답장 오면 다시 알려줄게."].allSatisfy(copiedThread.contains),
              "복사 puts every line of the thread on the clipboard, the folded replies too: \(copiedThread)")
        // Asked for before its replies were read, the copy waits for them instead of going out short.
        var unread = long; unread.loaded = false; unread.replies = []
        model.clipboard.clearContents(); model.copy(unread)
        check(model.copyWaiting == long.id && model.clipboard.string(forType: .string) == nil, "A thread whose replies are not in yet is not copied short")
        model.threads = model.threads
        check(model.copyWaiting == nil && model.clipboard.string(forType: .string) == copiedThread, "It is copied whole once they are")
        model.copied = nil
        let configuredOrder = DdotsConfig.shared.order
        let expectedCharacters = ["위키담당", "개인비서", "SNS담당", "진단담당"].map {
            ChatCharacter(id: SlackSpeakers.profile($0, characters: chat.characters), name: $0)
        }.sorted {
            let left = configuredOrder.firstIndex(of: $0.id) ?? configuredOrder.count
            let right = configuredOrder.firstIndex(of: $1.id) ?? configuredOrder.count
            return left == right ? $0.name < $1.name : left < right
        }
        let truthMembers = model.members["CTRUTH"] ?? []
        check(truthMembers.filter { !$0.profile.isEmpty }.map(\.profile) == expectedCharacters.map(\.id)
              && model.members["CCOW"]?.map(\.name) == ["SNS담당"] && model.members["CTEAM"]?.isEmpty == true,
              "Tabs show characters in configured order, or name order without settings: \(model.members)")
        check(truthMembers.count == expectedCharacters.count + 1 && truthMembers.last?.user == "UHUMAN"
              && truthMembers.last?.name == "테스트 참여자" && truthMembers.last?.profile == "",
              "A non-Hermes Slack participant stays visible after the characters: \(truthMembers)")
        check(slackWide && pet.chatSize.width == preferredChatSize.width + SlackSidebar.width && chat.viewportWidth == preferredChatSize.width, "The Slack side is wider by exactly the tab strip")
        check((model.members["CCOW"]?.count ?? 0) < SlackMention.minimumMembers && (model.members["CTRUTH"]?.count ?? 0) >= SlackMention.minimumMembers, "Only a room with two or more others offers mention buttons")
        if let cow = model.members["CCOW"]?.first {
            model.mention(cow); check(model.draft == "@SNS담당 ", "A face adds a mention: \(model.draft)")
            model.mention(cow); check(model.draft.isEmpty, "The same face takes it out again")
        }
        check(model.bells == [model.threads[1].id: true, model.threads[3].id: true, model.threads[4].id: true], "A thread with a question or a notification carries a bell: \(model.bells)")
        let question = model.threads[1], beforeConfirm = slack.confirmed
        // Synthetic Hermes choice: reuse the real model send path without contacting Slack.
        var hermesQuestion = question
        hermesQuestion.replies = []
        hermesQuestion.root.hermesReplyState = .asking
        hermesQuestion.root.hermesButtons = ["진행해", "보류"]
        let hermesSending = model.onSend
        var hermesSent: [(String, String, String?)] = []
        model.onSend = { text, room, thread, _ in hermesSent.append((text, room, thread?.id)) }
        model.answerHermes(hermesQuestion, label: "보류")
        model.answerHermes(hermesQuestion, label: "승인")
        check(hermesSent.count == 1 && hermesSent[0].0 == "보류" && hermesSent[0].1 == question.room && hermesSent[0].2 == question.id,
              "Hermes choice sends its exact label to the original thread and rejects stale choices")
        model.onSend = hermesSending
        let confirmSending = model.onSend
        var confirmSends = 0
        model.onSend = { _, _, _, _ in confirmSends += 1 }
        model.confirm(question)
        check(model.bells[question.id] == nil && SlackNotice.pendingApproval(question, confirmed: model.confirmed) == nil && !model.notices.contains { $0.threads.contains(question.id) } && confirmSends == 0,
              "Confirm settles a question and removes its bell and count without sending")
        model.confirm(question)
        check(model.bells[question.id] == nil && SlackNotice.pendingApproval(question, confirmed: model.confirmed) == nil && confirmSends == 0,
              "Confirm again does not restore the question or send anything")
        slack.confirmed = beforeConfirm; slack.publish()
        model.onSend = confirmSending
        // A completed thread never grows a quiet bell, even if it was manually read earlier.
        let completed = model.threads[0]
        check(completed.messages.flatMap(\.marks).map { SlackNotice.displayStatus($0.text) } == [SlackNotice.settledText, SlackNotice.settledText]
              && completed.root.marks[0].text == "✅ 답변 완료" && completed.replies[0].marks[0].text == "종결",
              "Completion and closure share one display without changing their source marks")
        model.onBell?(completed)
        check(SlackNotice.isSettled(completed) && model.bells[completed.id] == nil, "A completed status suppresses the dismissed bell too")
        model.onBell?(completed)
        model.onBell?(model.threads[3])
        check(model.bells[model.threads[3].id] == false && !model.notices.contains { $0.id == SlackNotice.alertID }, "Pressing the bell marks the thread read and takes it off the count")
        model.onBell?(model.threads[3])
        check(model.bells[model.threads[3].id] == true && model.notices.contains { $0.id == SlackNotice.alertID }, "Pressing it again brings it back")
        slack.readAll()
        check(model.alertCount == 0 && model.bells[model.threads[3].id] == false && model.bells[model.threads[1].id] == true, "Reading all marks every notification read and leaves questions alone")
        model.onBell?(model.threads[3])
        let liveliest = model.threads.max { $0.latest < $1.latest }
        check(model.target != nil && model.target?.id == liveliest?.id && liveliest?.root.fromUser == false, "When the liveliest thread was opened by a character, the next message answers it by default")
        model.writeNewPost(); check(model.target == nil && model.replyCandidate != nil, "The switch turns the next message into a new post")
        model.writeReply(); check(model.target?.id == liveliest?.id && model.picked == liveliest?.id, "답글 picks the newest thread and answers it")
        model.writeNewPost(); check(model.picked == nil && model.target == nil, "새 글 lets go of it again")
        model.foldAll(); model.newPost = false
        model.toggle(model.threads[1])
        check(model.scrollTarget == SlackModel.end(model.threads[1].id), "An opened thread is read from its newest reply")
        model.toggle(model.threads[0])
        check(model.open == [model.threads[0].id], "Opening another thread folds the one that was open")
        // Opened before its replies were read, a thread is taken to its newest reply once they are in.
        model.toggle(unread); model.requestScroll("slack-bottom"); model.threads = model.threads
        check(model.open == [long.id] && model.scrollTarget == SlackModel.end(long.id), "A thread opened before its replies were read goes to its newest reply when they are in")
        model.requestScroll("slack-bottom"); model.threads = model.threads
        check(model.scrollTarget == "slack-bottom", "and is taken there only that once")
        model.foldAll(); model.toggle(unread); model.userScrolls += 1; model.requestScroll("slack-bottom"); model.threads = model.threads
        check(model.scrollTarget == "slack-bottom", "A reader who scrolled by hand while the replies were read is left where they are")
        model.userScrolls -= 1
        model.foldOthers(than: model.threads[3]); check(model.open.isEmpty, "So does a click on a thread with nothing to unfold")
        model.pick(model.threads[3], foldable: false)
        check(model.picked == model.threads[3].id && model.target?.id == model.threads[3].id, "Clicking a thread picks it, and a reply goes to the picked thread")
        model.writeNewPost(); check(model.target == nil && model.picked == nil, "새 글 means the room and lets go of the picked thread")
        model.pick(model.threads[3], foldable: false); check(!model.newPost && model.target?.id == model.threads[3].id, "Picking a thread again switches back to 답글 for it")
        model.foldAll(); check(model.picked == nil, "Clicking away lets go of the pick")
        check(model.unread["CTRUTH"] == 1 && model.unread["CCOW"] == nil, "The open room is read and the other room shows one new thread: \(model.unread)")
        if let newest = model.threads.last {
            slack.activity = SlackActivity(writers: [.init(profile: "sns-manager", name: "SNS담당", room: "CCOW", thread: newest.ts, since: Date().timeIntervalSince1970)])
            check(model.typing[newest.id]?.map(\.speaker) == ["SNS담당"], "A character writing a reply shows in that thread: \(model.typing)")
            slack.activity.writers[0].since = 0
            check(model.typing.isEmpty, "The dots go once the reply is in the thread")
            slack.activity.writers[0].since = Date().timeIntervalSince1970
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            let kept = slack.store.destination(room: "SNS담당방", name: "행사 안내문.pdf", date: shared.date, id: "FPDF")
            check(model.thumbs["FIMG"] != nil && model.busyFiles.isEmpty && slack.lastSaved == kept && FileManager.default.fileExists(atPath: kept.path), "The picture is shown and the pressed file is saved in the room's folder: \(String(describing: slack.lastSaved))")
            try? FileManager.default.removeItem(at: slack.store.root)
            model.attach([URL(fileURLWithPath: "/tmp/보낼 사진.png"), URL(fileURLWithPath: "/tmp/견적서.pdf")])
            check(model.attachments.count == 2, "Picked files wait above the draft")
            model.requestScroll("slack-bottom")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [self] in
            capture(destination: destination.appendingPathComponent("slack-files"))
            model.detach(URL(fileURLWithPath: "/tmp/견적서.pdf")); model.detach(URL(fileURLWithPath: "/tmp/보낼 사진.png"))
            check(model.attachments.isEmpty, "A picked file can be taken out again")
            capture(destination: destination.appendingPathComponent("slack-typing"))
            model.requestScroll(long.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            capture(destination: destination.appendingPathComponent("slack-stacked"))
            model.toggle(long)
            model.reply(long)
            model.draft = "주차 안내에 지도 링크도 넣어줘"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [self] in
            check(model.open.contains(long.id) && SlackStack.visible(long, expanded: true).replies.count == 5 && model.replyThread?.id == long.id, "Opening shows every reply and aims the reply at that thread")
            check(model.focusThread == long.id && pet.chatSize.height > preferredChatSize.height + 20, "The window grows to show the opened thread whole: \(pet.chatSize.height) viewport \(model.viewportHeight) thread \(model.threadHeights[long.id] ?? 0)")
            check(SlackNotice.pendingApproval(model.threads[1])?.body.contains("승인하면") == true, "An unanswered approval request offers its buttons")
            model.answer(model.threads[1], approve: true)
            check(model.threads[1].replies.count == 5, "Smoke mode sends no approval")
            capture(destination: destination.appendingPathComponent("slack-opened"))
            check(!panel.isKeyWindow || panel.performKeyEquivalent(with: selectAll), "The Slack draft has the keyboard")
            model.send()
            check(model.draft.isEmpty && model.threads[1].replies.count == 5, "Smoke mode never sends")
            model.foldAll()
            check(model.open.isEmpty && pet.chatSize.height == preferredChatSize.height, "Clicking away folds the thread and the window returns to its height: \(pet.chatSize.height)")
            check(SlackSidebar.snapped(20) == 0 && SlackSidebar.snapped(90) == SlackSidebar.width && SlackSidebar.snapped(150) == SlackSidebar.listMinimum
                  && SlackSidebar.snapped(230) == 230 && SlackSidebar.snapped(900) == SlackSidebar.listMaximum, "A dragged strip rests hidden, as tabs, or as a list")
            model.dragSidebar(to: 212)
            check(model.sidebarWidth == 212 && pet.chatSize.width == preferredChatSize.width + 212 && chat.viewportWidth == preferredChatSize.width, "Widening the strip widens the window and leaves the conversation its width")
            check(model.latest["CCOW"].map { SlackText.isThinking($0.body) && $0.speaker == "개인비서" } == true && !slack.incoming.contains { SlackText.isThinking($0.body) },
                  "A thinking line is the room's newest activity, under the character's own name, but raises no bubble")
            check(model.rooms.map(\.id) == ["CCOW", "CTRUTH", "Dassistant", "CTEAM"], "Rooms are in order of their newest activity: \(model.rooms.map(\.name))")
            model.pin("CTEAM", slot: 0); model.pin("Dassistant", slot: 1)
            check(model.rooms.map(\.id) == ["CTEAM", "Dassistant", "CCOW", "CTRUTH"], "Pinned rooms hold the first and second places: \(model.rooms.map(\.name))")
            model.pin("Dassistant", slot: nil)
            check(model.rooms.map(\.id) == ["CTEAM", "CCOW", "CTRUTH", "Dassistant"], "Unpinning returns a room to the order of activity")
            model.hide("CTEAM")
            check(!model.rooms.contains { $0.id == "CTEAM" } && model.hiddenRooms.map(\.id) == ["CTEAM"] && model.pins == Array(repeating: "", count: SlackRoomOrder.slots), "A room taken off the list leaves it and gives up its pin")
            model.restore("CTEAM")
            check(model.rooms.map(\.id) == ["CCOW", "CTRUTH", "Dassistant", "CTEAM"] && model.hiddenRooms.isEmpty, "Putting it back returns it to the list")
            let badge = unreadTotal
            model.toggleMute(room: "CTRUTH")
            check(model.muted == ["CTRUTH"] && unreadTotal == badge - 1 && model.unread["CTRUTH"] == 1 && !slack.incoming.contains { $0.id.hasPrefix("slack:CTRUTH:") }, "A muted room keeps its count but leaves the pet's badge and bubbles")
            model.toggleMute()
            check(model.muted == ["CTRUTH", "CCOW"] && model.shownMuted, "The bell in the header mutes the room being shown")
            model.toggleMute()
            model.query = "주차"
            check(model.hits.count == 3 && model.hits.allSatisfy { $0.id.hasPrefix("slack:CCOW:") }, "Search finds the lines that mention it: \(model.hits.map(\.body))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [self] in
            capture(destination: destination.appendingPathComponent("slack-search"))
            if let hit = model.hits.last { model.onReveal?(hit.id); check(model.open.contains(long.id) && model.selected == "CCOW", "Choosing a found line opens its thread") }
            check(model.findHighlight?.thread == long.id && model.findHighlight?.term == "주차", "Sidebar search selection highlights its thread")
            model.query = ""
            check(model.findHighlight == nil, "Clearing sidebar search clears the highlight")
            if let line = long.messages.last {
                slack.reveal(line.id)
                check(model.findHighlight == nil, "Pet reveal does not enable search highlighting")
            }
            model.foldAll()
            check((chat.smokeFrames["slack-notices"]?.height ?? 0) > 0, "The notice bar is visible before searching")
            model.draft = "작성 중인 글"
            let findKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
            check(panel.onChatKey?(findKey) == true && model.findOpen, "Command-F opens whole Slack search")
            model.findQuery = "주차"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                check(model.findGroups.count == 2 && model.findGroups.reduce(0) { $0 + $1.matches.count } == 3, "Whole search groups the three matching lines into two threads")
                check((chat.smokeFrames["slack-notices"]?.height ?? 0) == 0, "The notice bar is absent during whole search")
                capture(destination: destination.appendingPathComponent("slack-find"))
                guard let group = model.findGroups.first, let line = group.matches.first else { smokeFailed("Search has a result") }
                model.onFindReveal?(group, line)
                check(!model.findOpen && model.selected == group.room && model.open.contains(group.id), "Choosing a search result opens its room and thread")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    check(model.scrollTarget == line.id && model.flash == line.id, "The matching line is scrolled to and highlighted")
                    check(model.target?.id == group.id && model.draft.isEmpty, "The words typed before searching do not go to the found thread: \(model.draft)")
                    check(model.findHighlight?.thread == group.id && model.findHighlight?.term == "주차", "Arriving keeps the query on the selected thread")
                    slack.publish()
                    check(model.findTerm(line) == "주차", "Polling preserves the arrived search highlight")
                    capture(destination: destination.appendingPathComponent("slack-find-arrived"))
                    model.foldAll()
                    check(model.findHighlight == nil, "Folding all threads clears search highlights")
                    check(model.draft == "작성 중인 글", "Leaving the found thread brings back the words typed for the room: \(model.draft)")
                    model.findHighlight = (group.id, "주차")
                    model.select("CTRUTH")
                    check(model.findHighlight == nil, "Changing rooms clears search highlights")
                    model.select(group.room)
                    model.findHighlight = (group.id, "주차")
                    model.openFind()
                    check(model.findHighlight == nil, "Searching again clears the arrived highlight")
                    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
                    let escaped = panel.onChatKey?(escape)
                    check(escaped == true && !model.findOpen && chatExpanded, "Escape closes search first: handled=\(String(describing: escaped)) open=\(model.findOpen) chat=\(chatExpanded)")
                    model.draft = ""; model.foldAll()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [self] in
            check((chat.smokeFrames["slack-notices"]?.height ?? 0) > 0, "Closing search restores the notice bar")
            capture(destination: destination.appendingPathComponent("slack-list"))
            model.toggleSidebar()
            check(model.sidebarWidth == 0 && pet.chatSize.width == preferredChatSize.width, "Hiding the strip returns the window to the conversation's width")
            model.toggleSidebar()
            check(model.sidebarWidth == 212, "Showing it again restores the width it had")
            model.dragSidebar(to: SlackSidebar.width)
            if IMessageFeature.enabled { model.source = .imessage }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                if IMessageFeature.enabled {
                    check(!chat.messages.isEmpty && !slackWide && pet.chatSize.width == preferredChatSize.width, "The iMessage side is still there at its own width")
                    check(!panel.isKeyWindow || panel.performKeyEquivalent(with: selectAll), "The iMessage draft has the keyboard again")
                } else { check(slackWide && model.source == .slack, "The conversation stays on Slack with iMessage disabled") }
                capture(destination: destination.appendingPathComponent("slack-back"))
                try? "slack smoke passed\n".write(to: destination.appendingPathComponent("slack.txt"), atomically: true, encoding: .utf8)
                verifyApprovalControls(destination: destination) { self.verifySidebarInteraction(destination: destination) { self.verifyComposer(destination: destination) { DispatchQueue.main.async { self.verifyRoomFaces(destination: destination) } } } }
            }
        }
    }
}

// MARK: ddots
extension AppDelegate {
    /// Some runs reach the checks without the synthetic workspace having been started (seen 2026-10-16, cause not
    /// found; the unchanged build did it too). The check starts it then and leaves a note, so the run still checks the UI.
    @MainActor func ensureDdotsSmoke(destination: URL) async {
        guard !slack.connected else { return }
        try? "synthetic ddots workspace started by the check at \(ProcessInfo.processInfo.systemUptime)\n".write(to: destination.appendingPathComponent("late-ddots-start.txt"), atomically: true, encoding: .utf8)
        startDdotsSmoke()
        for _ in 0..<80 where slack.model.rooms.count < 3 { try? await Task.sleep(nanoseconds: 100_000_000) }
        // The room list may have chosen another room meanwhile; the checks are about workspace.
        if !slack.model.isDdots { slack.model.choose(Ddots.room) }
        for _ in 0..<80 where !(slack.model.isDdots && !slack.model.threads.isEmpty) { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    func startDdotsSmoke() {
        slack.persists = false
        slack.characters = chat.characters
        let now = Date().timeIntervalSince1970
        // Two conversations hold something new; the rest were read a moment ago.
        slack.lastRead = ["DDS": now, "Dassistant": now - 2000, "DCOW": now, "DJANG": now - 2000, "DRACCOON": now - 2000, "CHUB": now, "CCOW": now, "CTRUTH": now, "CTEAM": now]
        slack.model.selected = Ddots.room
        // The record is kept in a folder of its own for the check. Three earlier months already hold a thread each.
        let shelf = DdotsArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent("ddots-record-smoke-\(UUID().uuidString)"))
        SmokeLeftovers.note(shelf.root)
        func before(_ months: Int, _ profile: String, _ name: String, _ text: String) -> DdotsLine {
            let at = (Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()).timeIntervalSince1970
            return DdotsLine(ts: String(format: "%.6f", at), thread: String(format: "%.6f", at), profile: profile, name: name, mine: false, at: at, text: text)
        }
        try? shelf.append([before(3, "personal-secretary", "개인비서", "석 달 전에 정리한 일정표야."), before(2, "system-doctor", "진단담당", "두 달 전 점검 기록이야."), before(1, "sns-manager", "SNS담당", "지난달 문의는 모두 답했어.")],
                          names: ["personal-secretary": "개인비서", "system-doctor": "진단담당", "sns-manager": "SNS담당"])
        slack.openRecord(root: shelf.root, keeps: true)
        if CommandLine.arguments.contains("--ui-smoke-ddots-entry") {
            let script = DdotsEntryScript(); DdotsEntryScript.current = script
            slack.start(script.api)
        } else { slack.start(SlackSmokeFixture.api(ddots: true)) }
        slack.model.source = .slack
        // The smoke timer does not poll, so the made-up rooms are read here.
        for delay in stride(from: 0.2, through: 2.6, by: 0.3) { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.slack.tick() } }
    }
    /// With the channel there, ddots writes new posts to it and shows its threads among the characters' own.
    func verifyDdotsHub(destination: URL) {
        func check(_ condition: Bool, _ message: String) { if !condition { smokeFailed(message) } }
        let model = slack.model
        check(model.ddotsHub == "CHUB" && !model.rooms.contains { $0.id == "CHUB" } && model.rooms.first?.id == Ddots.room && model.rooms.first?.name == "workspace" && model.isDdots, "The channel is part of ddots, not a tab of its own: \(model.rooms.map(\.id))")
        let there = model.threads.filter { $0.room == "CHUB" }
        check(there.count == 2 && model.threads.map(\.room) == ["CHUB", "CHUB"], "The room shows the channel and nothing else: \(model.threads.map(\.room))")
        check(model.unread["DRACCOON"] == 1 && model.stacked.count == 5, "The characters' own conversations stay behind their tab")
        check(model.ddotsOwner(there[0])?.profile == "system-doctor" && model.ddotsOwner(there[1]) == nil, "A thread there is whoever answered it, and nobody's until then")
        check(model.target == nil && model.postRoom == "CHUB" && model.recipient?.profile == Ddots.defaultTarget && model.outgoing("안녕") == "안녕" && model.outgoing("@SNS담당 안녕") == "@SNS담당 안녕", "A new post reaches the usual character without an automatic mention")
        check(model.hubPost("안녕") == DdotsPost(shown: "안녕", sent: "안녕", called: []) && model.hubPost("@개인비서 안녕") == DdotsPost(shown: "@개인비서 안녕", sent: "<@Uassistant> 안녕", called: ["Uassistant"]) && model.hubPost("@SNS담당야 이거 봐")?.sent == "<@UCOW> 이거 봐",
              "The call is a real mention, also under another name the character answers to: \(String(describing: model.hubPost("@개인비서 안녕")))")
        check(model.hubPost("") == DdotsPost(shown: "", sent: "", called: []), "Files alone reach the usual character without a call")
        if let assistant = model.ddotsMembers.first(where: { $0.profile == Ddots.defaultTarget }) {
            model.aim(assistant)
            check(model.hubPost("안녕")?.sent == "<@Uassistant> 안녕" && model.hubPost("")?.sent == "<@Uassistant>", "Pressing the usual face calls it for text and files")
            model.aim(assistant)
        }
        check(model.place(of: there[0]) == "#workspace", "A thread of the channel says where it is")
        let draftBody = "### 안내 메일 초안\n\n> 예약 실행이라 발송하지 않았습니다. 발송은 승인 전입니다."
        let mailRoot = ChatMessage(id: "slack:CREPORT:1791000000.000100", fromUser: false, speaker: "진단담당", body: draftBody, date: Date(), profile: "system-doctor")
        let mailThread = SlackThread(id: "slack:CREPORT:1791000000.000100", room: "CREPORT", ts: "1791000000.000100", root: mailRoot, replies: [], replyCount: 0, loaded: true, latest: 1, latestFromUser: false)
        let relay = model.mailRelay(mailThread, ask: "그대로 발송해줘.")
        check(relay?.room == "CHUB" && relay?.member.profile == "system-doctor" && relay?.text.contains("「안내 메일 초안」") == true
              && relay?.post.called == ["UJANG"] && relay?.post.sent.hasPrefix("<@UJANG> ") == true,
              "A mail draft posted outside workspace is asked of its character in the channel: \(String(describing: relay))")
        var inside = mailThread; inside.room = "CHUB"
        check(model.mailRelay(inside, ask: "") == nil, "A mail draft already in workspace is answered in its own thread")
        let projectApproval = ThreadProject.Approval(id: "1234567890abcdef", profile: "personal-secretary", status: "pending", previewText: "받는 사람: 예시 · 본문: 검토 요청", expiresAt: Date().timeIntervalSince1970 + 300)
        model.projects = [ThreadProject(id: "fixture", scopeId: "T1", chatId: "CHUB", threadId: there[0].ts,
            ownerId: "OWNER", title: "행사 준비", goal: "자료를 찾아 메일 초안 준비", status: "open",
            tasks: [.init(id: "step1", profile: "work-assistant", title: "자료 확인", status: "recorded", summary: "행사 자료 확인", nextStep: "메일 초안 작성", references: ["https://example.invalid/source"])],
            updatedAt: Date().timeIntervalSince1970, currentProfile: "system-doctor", decisions: [.init(text: "금요일 진행", messageId: "1")], approvals: [projectApproval])]
        model.pick(there[0], foldable: false); model.draft = "행사 초안"
        model.attachments = [URL(fileURLWithPath: "/synthetic/fixture.txt")]
        model.pick(there[1], foldable: false)
        check(model.draft.isEmpty && model.attachments.isEmpty, "another project starts with its own draft and attachments")
        model.draft = "다른 프로젝트 초안"
        model.pick(there[0], foldable: false)
        check(model.draft == "행사 초안" && model.attachments.count == 1, "returning to a project restores only its draft")
        model.draft = ""; model.attachments = []; model.writeNewPost()
        model.select("DJANG"); model.draft = "개별 방 초안"
        model.select(Ddots.room)
        model.select("DJANG")
        check(model.draft == "개별 방 초안", "leaving the hub also restores the individual room draft")
        model.draft = ""; model.select(Ddots.room)
        let projectSend = model.onSend
        var choices = 0
        model.onSend = { text, room, thread, files in
            choices += 1
            check(text == "프로젝트 승인 1234567890abcdef" && room == "CHUB" && thread?.id == there[0].id && files.isEmpty, "approval is bound to the exact server ID and project thread")
        }
        model.projectChoice(there[0], approval: projectApproval, approve: true)
        var expired = projectApproval; expired.expiresAt = 0
        model.projectChoice(there[0], approval: expired, approve: true)
        check(choices == 1, "stale or changed approvals cannot send")
        model.onSend = projectSend
        // A character who is not in the channel cannot be called there: the post is not sent and the words stay.
        let everyone = model.members["CHUB"] ?? []
        var refusal: String?, sends = 0
        let keptSend = model.onSend, keptRefuse = model.onRefuse
        model.onSend = { _, _, _, _ in sends += 1 }; model.onRefuse = { refusal = $0 }
        model.members["CHUB"] = everyone.filter { $0.user != "UJANG" }
        model.draft = "@진단담당 오늘 토큰 얼마나 썼어?"; model.send()
        check(sends == 0 && refusal == "진단담당이 #workspace 채널에 없어요. 슬랙에서 채널에 초대한 뒤 다시 보내 주세요." && model.draft == "@진단담당 오늘 토큰 얼마나 썼어?", "A character missing from the channel is said so and nothing is sent: \(String(describing: refusal))")
        model.members["CHUB"] = everyone; refusal = nil
        model.send()
        check(sends == 1 && refusal == nil && model.draft.isEmpty, "With everyone there the post goes out")
        model.onSend = keptSend; model.onRefuse = keptRefuse
        model.draft = "오늘 토큰 얼마나 썼어?"
        check(model.postRoom == "CHUB" && model.outgoing(model.draft) == "오늘 토큰 얼마나 썼어?", "Unmentioned requests reach the hub without a client-side classification")
        if let cow = model.ddotsMembers.first(where: { $0.profile == "sns-manager" }) {
            model.aim(cow)
            let sent = model.outgoing("이거 확인해줘")
            check(sent == "@SNS담당 이거 확인해줘" && SlackMention.outgoing(sent, members: model.members["CHUB"] ?? []) == "<@UCOW> 이거 확인해줘", "A pressed face is sent as a mention: \(sent)")
            model.aim(cow)
        }
        model.draft = ""
        let revision = model.beginPost()
        model.followPost(room: "CHUB", ts: there[0].ts, revision: revision)
        check(model.target?.id == there[0].id, "An answered new post automatically selects its reply")
        model.draft = "인스타 피드 확인해줘"
        check(model.target?.id == there[0].id && model.hubPost(model.draft) == nil, "A different task stays within its project thread")
        model.draft = ""
        check(model.target?.id == there[0].id, "Removing those words restores the automatic reply")
        for words in ["고마워", "토큰 얼마나 썼어?", "@SNS담당 @진단담당"] {
            model.draft = words
            check(model.target?.id == there[0].id, "Fallback, the same owner, and several names keep the automatic reply: " + words)
        }
        model.draft = "인스타 피드 확인해줘"
        var routedSends = 0
        model.onSend = { text, room, thread, _ in
            routedSends += 1
            check(room == "CHUB" && thread?.id == there[0].id && text == "인스타 피드 확인해줘", "The send callback receives a channel post and its mention")
            _ = model.beginPost()
        }
        model.send()
        check(routedSends == 1 && model.target?.id == there[0].id && !model.newPost && model.draft.isEmpty, "Sending a routed new post does not restore the old reply")
        model.onSend = keptSend
        model.followPost(room: "CHUB", ts: there[0].ts, revision: model.composeRevision)
        model.writeReply(); model.draft = "인스타 피드 확인해줘"
        check(model.target?.id == there[0].id, "Choosing reply explicitly keeps the thread despite other words")
        model.pick(there[0], foldable: false)
        check(model.target?.id == there[0].id, "Clicking a thread explicitly keeps it despite other words")
        model.draft = ""
        model.pick(there[0], foldable: false); model.reply(there[0])
        check(model.target?.room == "CHUB" && model.recipient?.profile == "system-doctor" && model.outgoing("고마워") == "고마워", "An answer goes into the thread, to the character whose it is")
        model.writeNewPost()
        guard let shelf = slack.archive else { smokeFailed("The check keeps a record") }
        slack.fileQueue.sync {}
        let written = shelf.read(month: DdotsArchive.month(Date())).filter { $0.hub == true }
        check(written.map(\.profile) == ["system-doctor", "system-doctor"] && written.contains { $0.mine } && !shelf.read(month: DdotsArchive.month(Date())).contains { $0.text == "아무나 대답해줘" },
              "A thread of the channel is written with the character who answered it, an unanswered one not yet: \(written.map(\.text))")
        model.select("DJANG")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            check(model.threads.count == 2 && model.threads.allSatisfy { $0.room == "DJANG" }, "A character's own room keeps its own lines, the record's too, and leaves the channel out: \(model.threads.map(\.room))")
            model.select(Ddots.room)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                check(model.threads.map(\.room) == ["CHUB", "CHUB"], "Back in ddots each of its threads is there once")
                capture(destination: destination.appendingPathComponent("ddots-hub"))
                // What the room says when the character a post calls is not in the channel.
                model.members["CHUB"] = (model.members["CHUB"] ?? []).filter { $0.user != "UJANG" }
                model.draft = "@진단담당 오늘 토큰 얼마나 썼어?"; model.send()
                check(model.notice?.hasPrefix("진단담당이 #workspace 채널에 없어요.") == true && model.draft == "@진단담당 오늘 토큰 얼마나 썼어?", "The room says why the post was not sent: \(String(describing: model.notice))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    capture(destination: destination.appendingPathComponent("ddots-hub-absent"))
                    verifyDdotsFind(destination: destination) { [self] in
                        try? FileManager.default.removeItem(at: shelf.root)
                        verifyDdotsActivity(destination: destination) {
                            try? "ddots hub smoke passed\n".write(to: destination.appendingPathComponent("ddots-hub.txt"), atomically: true, encoding: .utf8)
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }
    func verifyDdotsFind(destination: URL, done: @escaping () -> Void) {
        verifyDdotsFindBatches(destination: destination) { [self] in verifyDdotsFindOld(destination: destination, done: done) }
    }
    /// Whole search reads the record a few months at a time and shows each batch's results before the next is read.
    /// A garbled line is passed over and a file that cannot be opened is said, while everything else is still found.
    func verifyDdotsFindBatches(destination: URL, done: @escaping () -> Void) {
        func check(_ condition: Bool, _ message: String) { if !condition { smokeFailed(message) } }
        let model = slack.model
        guard let shelf = slack.archive else { smokeFailed("The check keeps a record") }
        func month(_ back: Int) -> String { DdotsArchive.month(Calendar.current.date(byAdding: .month, value: -back, to: Date()) ?? Date()) }
        let oldest = shelf.recordURL(name: "개인비서", month: month(3)), locked = shelf.recordURL(name: "진단담당", month: month(2))
        if let handle = try? FileHandle(forWritingTo: oldest) { handle.seekToEndOfFile(); handle.write(Data("{망가진 줄\n".utf8)); handle.closeFile() }
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        // A character's folder whose list cannot be read.
        let hidden = shelf.root.appendingPathComponent(DdotsArchive.records).appendingPathComponent("합성 잠긴 폴더")
        try? FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: hidden.path)
        func unlock() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path); try? FileManager.default.removeItem(at: hidden)
        }
        SlackFind.pause = 0.6
        // Closed at once, nothing more is read.
        model.openFind(); model.closeFind()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            check(slack.find.lines.isEmpty && slack.find.months.isEmpty && slack.find.pending.isEmpty && !slack.find.loadingArchive && model.findProgress == nil,
                  "Closing search stops the record being read: \(slack.find.months)")
            model.openFind(); model.findQuery = "달"
            func firstBatch(_ tries: Int) {
                if slack.find.months.count == 2 || tries == 0 {
                    check(slack.find.known.count == 4 && slack.find.months == [month(1), month(0)].sorted(), "The newest months are read first: \(slack.find.months) of \(slack.find.known)")
                    check(model.findProgress == "기록 2/4개월 읽음", "Search says how far it has read: \(String(describing: model.findProgress))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                        let shown = model.findGroups.flatMap(\.matches).map(\.body)
                        check(shown.contains("지난달 문의는 모두 답했어.") && !shown.contains("석 달 전에 정리한 일정표야.") && model.findBusy,
                              "What the first months hold is shown while the rest is read: \(shown)")
                        capture(destination: destination.appendingPathComponent("ddots-find-partial"))
                        func rest(_ tries: Int) {
                            if !slack.find.loadingArchive || tries == 0 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                                    let found = model.findGroups.flatMap(\.matches).map(\.body)
                                    check(found.contains("석 달 전에 정리한 일정표야.") && found.contains("지난달 문의는 모두 답했어.") && !found.contains("두 달 전 점검 기록이야."),
                                          "The rest is found; the file that cannot be opened is left out: \(found)")
                                    check(model.findGaps.contains("기록 파일 1개를 읽지 못해 검색 결과가 빠졌을 수 있어요") && model.findGaps.contains("손상된 기록 1줄은 건너뛰고 나머지를 찾았어요")
                                          && model.findGaps.contains("기록 폴더 1개의 목록을 읽지 못해 그 안의 기록이 검색에서 빠졌을 수 있어요") && model.findProgress == nil && !model.findBusy,
                                          "Search says the results may be missing something: \(model.findGaps)")
                                    capture(destination: destination.appendingPathComponent("ddots-find-gaps"))
                                    unlock(); SlackFind.pause = 0
                                    model.closeFind()
                                    check(model.findGaps.isEmpty && slack.find.lines.isEmpty, "Closing search forgets what it read")
                                    done()
                                }
                            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { rest(tries - 1) } }
                        }
                        rest(60)
                    }
                } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { firstBatch(tries - 1) } }
            }
            firstBatch(80)
        }
    }
    func verifyDdotsFindOld(destination: URL, done: @escaping () -> Void) {
        let model = slack.model
        model.openFind(); model.findQuery = "석 달"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            guard let group = model.findGroups.first, let message = group.matches.first,
                  group.room == "Dassistant", !model.threads.contains(where: { $0.id == group.id }) else { smokeFailed("Whole search finds a month outside the loaded record") }
            model.onFindReveal?(group, message)
            guard model.selected == "Dassistant", model.open.contains(group.id), model.threads.contains(where: { $0.id == group.id }) else { smokeFailed("An old record search result loads its month and opens its room") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                guard model.scrollTarget == message.id else { smokeFailed("Old record result scrolls to the matching line") }
                capture(destination: destination.appendingPathComponent("ddots-find-old"))
                model.draft = ""; model.select(Ddots.room); model.foldAll(); done()
            }
        }
    }
    /// Exercise publication and the live scroll view with synthetic replies only.
    func verifyDdotsActivity(destination: URL, done: @escaping () -> Void) {
        let model = slack.model
        model.draft = ""; model.notice = nil; model.foldAll(animated: false); model.writeNewPost()
        let live = model.threads.filter { thread in slack.snapshot.threads[thread.room]?.contains { $0.id == thread.id } == true }
        guard live.count >= 2 else { smokeFailed("Activity check needs two live threads") }
        let old = live[0], other = live[1]
        var report: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { smokeFailed(message) }; report.append(message)
        }
        func reply(_ thread: SlackThread, mine: Bool = false) -> ChatMessage {
            ChatMessage(id: "slack-smoke:" + UUID().uuidString, fromUser: mine, speaker: mine ? "" : "개인비서",
                        body: mine ? "이 스레드에 답글을 달게" : (1...8).map { "합성 답글 \($0): 이전 대화의 진행 상황을 확인했어." }.joined(separator: "\n"),
                        date: Date(), profile: mine ? "" : "personal-secretary")
        }
        model.requestScroll("slack-bottom")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            check((model.place()?.fromBottom ?? 9999) < 32, "Activity starts at the bottom: \(model.place()?.fromBottom ?? -1)")
            slack.smokeReply(reply(old), to: old)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                check(model.threads.last(where: { !$0.ts.isEmpty })?.id == old.id && (model.place()?.fromBottom ?? 9999) < 32,
                      "An old thread's agent reply moves it last and follows: \(model.place()?.fromBottom ?? -1)")
                capture(destination: destination.appendingPathComponent("ddots-activity"))
                // Keep one card open so even the small channel fixture has room to read above the foot.
                model.open = [old.id]
                slack.smokeReply(reply(old), to: old)
                slack.smokeReply(reply(old), to: old)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                    guard let scroll = model.scrollView, let document = scroll.documentView else { smokeFailed("Activity has a scroll view") }
                    model.userScrolls += 1
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? document.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.height))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    let before = model.place()!.fromBottom, origin = scroll.contentView.bounds.minY, revision = model.scrollRevision
                    check(before > SlackModel.followDistance, "Reading above the foot: \(before)")
                    slack.smokeReply(reply(other), to: other)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                        let after = model.place()?.fromBottom ?? -1
                        check(model.threads.last?.id == other.id && after > SlackModel.followDistance && model.scrollRevision == revision,
                              "Another thread moves last without pulling the reader down: bottom \(before) -> \(after), origin \(origin) -> \(scroll.contentView.bounds.minY)")
                        capture(destination: destination.appendingPathComponent("ddots-activity-reading"))
                        model.picked = old.id
                        let echo = reply(old, mine: true)
                        slack.addEcho(room: old.room, thread: old.ts, message: echo); slack.publish()
                        model.requestScroll("slack-bottom")
                        check(model.threads.last?.id == old.id, "A user's pending reply immediately moves its thread last")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                            slack.removeEcho(echo.id); slack.smokeReply(reply(old, mine: true), to: old)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                                check(model.threads.last?.id == old.id && (model.place()?.fromBottom ?? 9999) < 32, "Replacing the echo stays at the bottom")
                                model.userScrolls += 1
                                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? document.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.height))
                                scroll.reflectScrolledClipView(scroll.contentView)
                                slack.smokeReply(reply(old), to: old)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    check((model.place()?.fromBottom ?? 9999) < 32, "An agent reply in the chosen open thread follows from above")
                                    try? (report.joined(separator: "\n") + "\n").write(to: destination.appendingPathComponent("ddots-activity.txt"), atomically: true, encoding: .utf8)
                                    model.foldAll(animated: false); done()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func verifyDdots(destination: URL, waited: Int = 0) {
        // Slack's calls are spaced since 1.6.73, so the channels and the last direct conversations may still be unread
        // when the capture timer fires. The order and counts below need them read; wait up to a minute, ticking (the history gate allows about 46 a minute).
        if waited < 240, DdotsEntryScript.current == nil, !CommandLine.arguments.contains("--ui-smoke-record-memory"),
           ["CCOW", "CTRUTH", "DRACCOON"].contains(where: { slack.model.latest[$0] == nil }) {
            slack.tick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.verifyDdots(destination: destination, waited: waited + 1) }
            return
        }
        if waited > 0 { try? "rooms read after \(Double(waited) / 4) s more\n".write(to: destination.appendingPathComponent("ddots-rooms-wait.txt"), atomically: true, encoding: .utf8) }
        if CommandLine.arguments.contains("--ui-smoke-ddots-hub") { verifyDdotsHub(destination: destination); return }
        if CommandLine.arguments.contains("--ui-smoke-record-memory") { Task { @MainActor in await verifyRecordMemory(destination: destination) }; return }
        if let script = DdotsEntryScript.current { Task { @MainActor in await verifyDdotsEntry(destination: destination, script: script) }; return }
        func check(_ condition: Bool, _ message: String) { if !condition { smokeFailed(message) } }
        let model = slack.model
        check(model.rooms.first?.id == Ddots.room && model.rooms.first?.name == "workspace" && model.selected == Ddots.room && model.isDdots, "ddots is the first room and stays chosen: \(model.rooms.map(\.name))")
        let inRoom = ChatCharacter.preferred.filter { !Ddots.excluded.contains($0) }
        check(model.ddotsMembers.map(\.profile) == inRoom && inRoom.count == 4 && model.members[Ddots.room]?.map(\.profile) == [Ddots.defaultTarget], "Every character but the ones left out is in ddots, in the usual order: \(model.ddotsMembers.map(\.name))")
        check(model.threads.map(\.room) == ["DJANG", "DCOW", "Dassistant", "DCOW", "Dassistant", "DDS", "DJANG", "Dassistant"], "What the record keeps comes first, then the conversations as one line of time: \(model.threads.map(\.room))")
        guard let shelf = slack.archive else { smokeFailed("The check keeps a record") }
        slack.fileQueue.sync {}
        let quiet = CommandLine.arguments.contains("--ui-smoke-ddots-quiet")
        let written = shelf.read(month: DdotsArchive.month(Date()))
        check(written.count == (quiet ? 10 : 9) && !written.contains { SlackText.isThinking($0.text) }, "Every message of the characters' conversations is written down, a thinking line left out: \(written.count)")
        check(written.first { $0.text.contains("치과는 오후로") }.map { $0.mine && $0.profile == "personal-secretary" && $0.thread != $0.ts } == true, "A reply is written with its thread and its conversation")
        let report = written.first { !$0.files.isEmpty }?.files.first
        check(report?.name == "점검 보고서.pdf" && report.map { FileManager.default.fileExists(atPath: shelf.fileURL($0.path).path) && $0.path.hasPrefix("파일/진단담당/") } == true, "A file that came with a message is fetched into the record: \(String(describing: report))")
        check(shelf.readCast().map(\.profile) == inRoom, "Who is in ddots is noted beside the record")
        check(model.hasOlder && model.threads.first?.root.body == "두 달 전 점검 기록이야.", "The two newest months of the record are shown, with more behind them")
        check(model.threads.allSatisfy(\.loaded), "Every thread on screen has its replies")
        // However recent the direct conversations, their tab stays under every channel.
        check(model.rooms.map(\.id) == [Ddots.room, Ddots.group(1), Ddots.group(2), Ddots.group(3), Ddots.stack] && !model.stackOpen,
              "Direct conversations are folded behind one tab at the bottom of the list: \(model.rooms.map(\.id))")
        model.pin(Ddots.stack, slot: 2)
        check(model.rooms.last?.id == Ddots.stack, "Even pinned, the tab stays at the bottom: \(model.rooms.map(\.id))")
        model.pin(Ddots.stack, slot: nil)
        model.toggleStack()
        check(Array(model.rooms.map(\.id).suffix(6)) == [Ddots.stack, "DDS", "Dassistant", "DCOW", "DJANG", "DRACCOON"], "Unfolded, its conversations follow it: \(model.rooms.map(\.id))")
        model.toggleStack()
        check(model.rooms.map(\.id) == [Ddots.room, Ddots.group(1), Ddots.group(2), Ddots.group(3), Ddots.stack] && model.pins.allSatisfy(\.isEmpty), "Folded again, the tab is back at the bottom: \(model.rooms.map(\.id))")
        check(model.stacked.map(\.id) == ["DDS", "Dassistant", "DCOW", "DJANG", "DRACCOON"] && model.members[Ddots.stack]?.count == 5, "Behind it are all of them, characters first: \(model.stacked.map(\.id))")
        // Channels put in no section are in the first; two or more fold behind its tab. One alone shows as itself.
        check(model.groups[1]?.map(\.id) == ["CCOW", "CTRUTH", "CTEAM"] && model.rowZones[Ddots.room] == 0 && model.rowZones[Ddots.stack] == 4,
              "ddots stands above the sections; the channels fill the first and the direct conversations are the fourth: \(model.rowZones)")
        model.move("CCOW", toZone: 2)
        check(model.rooms.map(\.id) == [Ddots.room, Ddots.group(1), "CCOW", Ddots.group(3), Ddots.stack] && model.groups[2]?.map(\.id) == ["CCOW"] && model.rowZones["CCOW"] == 2,
              "A channel dragged alone into a section shows as itself there: \(model.rooms.map(\.id))")
        model.move("CTRUTH", toZone: 2)
        check(model.rooms.map(\.id) == [Ddots.room, "CTEAM", Ddots.group(2), Ddots.group(3), Ddots.stack] && model.chosenTab == Ddots.room,
              "With two in it the section folds behind its tab, and the one left in the first shows as itself: \(model.rooms.map(\.id))")
        model.toggleGroup(2)
        check(model.rooms.map(\.id) == [Ddots.room, "CTEAM", Ddots.group(2), "CCOW", "CTRUTH", Ddots.group(3), Ddots.stack], "Unfolded, the section shows its rooms under its tab: \(model.rooms.map(\.id))")
        model.move(Ddots.room, toZone: 2); model.move("DDS", toZone: 2); model.move(Ddots.stack, toZone: 3); model.move(Ddots.group(3), toZone: 2); model.move("CTEAM", toZone: 4)
        check(model.zoneOf == ["CCOW": 2, "CTRUTH": 2], "ddots, the tabs and the direct conversations keep their places, and no channel goes among them: \(model.zoneOf)")
        model.groupNames[3] = "업무"
        model.onZones?()
        check(model.rooms.first { $0.id == Ddots.group(3) }?.name == "업무" && model.groupName(2) == "section 2" && model.groupName(Ddots.directZone) == "section 4",
              "A section goes by the name given it, or by its number")
        model.move("CCOW", toZone: 1); model.move("CTRUTH", toZone: 1); model.toggleGroup(2); model.groupNames = [:]; model.onZones?()
        check(model.rooms.map(\.id) == [Ddots.room, Ddots.group(1), Ddots.group(2), Ddots.group(3), Ddots.stack] && model.zoneOf.isEmpty && model.groupsOpen.isEmpty,
              "Dragged back, they join the first section again: \(model.rooms.map(\.id))")
        // A new section comes empty at the bottom of the channel sections; taking one away sends its channels to the first.
        model.addSection()
        check(model.sections == [1, 2, 3, 5] && model.rooms.map(\.id) == [Ddots.room, Ddots.group(1), Ddots.group(2), Ddots.group(3), Ddots.group(5), Ddots.stack]
              && model.groupName(5) == "section 4" && model.groupName(Ddots.directZone) == "section 5", "A new section is added above the direct conversations: \(model.rooms.map(\.id))")
        model.move("CCOW", toZone: 5)
        check(model.rowZones["CCOW"] == 5, "A channel can be dragged into the new section")
        model.removeSection(5)
        check(model.sections == [1, 2, 3] && model.zoneOf.isEmpty && model.groups[1]?.contains { $0.id == "CCOW" } == true, "Its channels go back to the first section")
        model.removeSection(1)
        check(model.sections == [2, 3] && model.groups[2]?.count == 3 && model.rooms.map(\.id) == [Ddots.room, Ddots.group(2), Ddots.group(3), Ddots.stack] && model.groupName(2) == "section 1",
              "Without the first section the next one takes its channels and its place: \(model.rooms.map(\.id))")
        model.removeSection(3); model.removeSection(2)
        check(model.sections == [2], "The last section stays")
        model.sections = Ddots.defaultSections; model.onZones?()
        check(model.stackWaiting && model.unread[Ddots.stack] == nil && model.unread["DRACCOON"] == 1, "Folded, the tab only marks that something waits; the count belongs to the room: \(model.unread)")
        check(model.target == nil && model.recipient?.profile == Ddots.defaultTarget && model.postRoom == "Dassistant", "A new post goes to the usual character by default")
        check(model.notices.map(\.title) == ["개인비서 질문", "알림"], "The notice counts what waits across every character: \(model.notices.map(\.title))")
        check(slackWide && pet.chatSize.width == preferredChatSize.width + SlackSidebar.width, "ddots is a room of the Slack side, so the window is as wide as there")
        var heldPlace: CGFloat?
        var heldRead: (id: String, offset: CGFloat)?, heldCount = 0
        /// The thread at the top of the view, and how far below the view's top edge it is drawn.
        func readAt() -> (id: String, offset: CGFloat)? {
            guard let bounds = model.scrollView?.contentView.bounds,
                  let thread = model.threads.first(where: { model.rowFrame($0.id).map { $0.maxY > bounds.minY + 1 } ?? false }),
                  let frame = model.rowFrame(thread.id) else { return nil }
            return (thread.id, frame.minY - bounds.minY)
        }
        let cow = model.threads.first { $0.room == "DCOW" && $0.replyCount == 2 }!
        // The last replies have only just come in; the first picture waits for the view to reach the newest line.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            capture(destination: destination.appendingPathComponent("ddots"))
            // With no face pressed, the words say who a new post is for, as in the room every character shares.
            let samples = DdotsConfig.shared.document["routing_samples"] as? [[String:String]] ?? []
            check(samples.count >= 30, "Hermes oracle samples must be supplied to the smoke test")
            for sample in samples {
                let words = sample["text"]!, expected = sample[model.ddotsHub == nil ? "base" : "hub"]!
                let member = model.ddotsMembers.first { $0.profile == expected }
                    ?? model.ddotsMembers.first { $0.profile == Ddots.defaultTarget } ?? model.ddotsMembers.first
                model.draft = words
                check(model.recipient?.profile == member?.profile && model.postRoom == (model.ddotsHub ?? member?.room),
                      "Hermes oracle recipient: " + words)
            }
            model.draft = "인스타 DM 온 거 있어?"
            if let jang = model.ddotsMembers.first(where: { $0.profile == "system-doctor" }) {
                model.aim(jang); check(model.recipient?.profile == "system-doctor", "A pressed face wins over the words")
                model.aim(jang); check(model.recipient?.profile == "sns-manager", "Pressing it again lets the words decide")
            }
            if let cowFace = model.ddotsMembers.first(where: { $0.profile == "sns-manager" }) {
                model.aim(cowFace); model.draft = "이거 확인해줘"
                check(model.ddotsPicked && model.postRoom == "DCOW", "A pressed face takes the next message")
                model.send()
                check(!model.ddotsPicked && model.draft.isEmpty && model.recipient?.profile == Ddots.defaultTarget, "It is let go once that message is sent")
                model.draft = "위키 찾아줘"; check(model.recipient?.profile == "default", "and the words decide again")
            }
            model.draft = ""
            if let boss = model.ddotsMembers.first(where: { $0.profile == "default" }) {
                model.aim(boss)
                check(model.recipient?.profile == "default" && model.postRoom == "DDS" && model.target == nil, "Pressing a face aims a new post at that character")
            }
            model.writeReply()
            check(model.target?.id == model.threads.last?.id && model.recipient?.profile == "personal-secretary", "답글 answers the most recent thread, and its character is the one reached")
            model.writeNewPost()
            check(model.target == nil && model.recipient?.profile == "default", "새 글 goes back to the picked face")
            model.pick(cow, foldable: false); model.reply(cow); model.draft = "영어로도 한 줄 붙여줘"; model.requestScroll(cow.id)
            model.toggleStack()
            check(model.stackOpen && Array(model.rooms.map(\.id).suffix(6)) == [Ddots.stack, "DDS", "Dassistant", "DCOW", "DJANG", "DRACCOON"],
                  "Pressing the tab unfolds the conversations under it: \(model.rooms.map(\.id))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            check(model.target?.room == "DCOW" && model.recipient?.profile == "sns-manager" && model.open == [cow.id], "A picked thread is answered in its own character's conversation")
            capture(destination: destination.appendingPathComponent("ddots-reply"))
            model.send()
            check(model.draft.isEmpty && model.threads.first { $0.id == cow.id }?.replies.count == 2, "Smoke mode never sends")
            model.foldAll()
            slack.lastRead["DJANG"] = Date().timeIntervalSince1970 - 2000; slack.publish()
            model.toggleStack(); model.select("DCOW")
            check(!model.stackOpen && model.chosenTab == Ddots.stack && model.selected == "DCOW" && model.room?.name == "SNS담당", "A room folded away can still be the one shown, and the tab stands for it")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [self] in
            check(!model.isDdots && model.threads.map(\.room) == ["DCOW", "DCOW"], "A character's own room shows that character alone, the record's part of it too")
            capture(destination: destination.appendingPathComponent("ddots-one"))
            model.select(Ddots.room); model.dragSidebar(to: 212)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            check(model.isDdots && model.threads.count == 8, "Going back to ddots shows everyone again")
            capture(destination: destination.appendingPathComponent("ddots-list"))
            // Read from the top of what is shown, then ask for older lines: they fill in above without moving the reader.
            if let scroll = model.scrollView, let document = scroll.documentView {
                // As a scroll of the user's: the room's entry stops holding the newest line in view.
                model.userScrolls += 1
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? document.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            heldPlace = model.place()?.fromBottom
            heldRead = readAt(); heldCount = model.threads.count
            model.onOlder?()
            slack.chatOpen = false
            check(model.ddotsTarget == Ddots.defaultTarget, "Folding the window puts new posts back on the usual character")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [self] in
            // What is being read is the thread at the top of the view: it keeps its place on screen. Growth below the view,
            // such as the space under the newest line, moves the distance from the bottom without moving the reader.
            let nowRead = heldRead.flatMap { held in model.rowFrame(held.id).flatMap { frame in model.scrollView.map { (id: held.id, offset: frame.minY - $0.contentView.bounds.minY) } } }
            check((heldPlace ?? 0) > 100 && model.threads.count > heldCount && heldRead != nil && nowRead?.id == heldRead?.id && abs((heldRead?.offset ?? 0) - (nowRead?.offset ?? -100)) < 2,
                  "Older lines fill in above without moving what is being read: \(String(describing: heldRead)) then \(String(describing: nowRead)), \(heldCount) then \(model.threads.count) threads")
            check(model.threads.count == 9 && model.threads.first?.root.body == "석 달 전에 정리한 일정표야." && !model.hasOlder, "Asking for older lines reads one more month of the record, and then there is no more: \(model.threads.count)")
            try? FileManager.default.removeItem(at: shelf.root)
            // Folding does not cut the conversation off: it is drawn away into the pet as a picture of itself, or
            // blurred away where that picture is not used, and opening brings it back the same way.
            // With motion turned down it is simply put away and brought back.
            let still = CommandLine.arguments.contains("--ui-smoke-reduce-motion")
            collapseChat()
            let drawnAway = pet.genieActive
            check((pet.chatShown || drawnAway) != still, "A folded conversation stays on screen while it goes")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [self] in
                check(!pet.chatShown && pet.chatBlur == 0, "Once folded it is put away")
                check(!pet.genieActive, "The picture of it is gone with it")
                check(still ? pet.chatBlurPeak == 0 : pet.chatBlurPeak > 0 || drawnAway, "It was blurred or drawn away on the way: \(pet.chatBlurPeak)")
                showChat()
                let drawnOut = pet.genieActive
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [self] in
                    check(pet.chatBlur == 0 && pet.chatShown, "Open, it is sharp")
                    check(still ? pet.chatBlurPeak == 0 : pet.chatBlurPeak > 0 || drawnOut, "Opening started blurred or drawn out: \(pet.chatBlurPeak)")
                    verifyDdotsActivity(destination: destination) {
                        try? "ddots smoke passed\n".write(to: destination.appendingPathComponent("ddots.txt"), atomically: true, encoding: .utf8)
                        self.verifySidebarInteraction(destination: destination) { self.verifyComposer(destination: destination) { NSApp.terminate(nil) } }
                    }
                }
            }
        }
    }
}

// MARK: Approval controls
extension AppDelegate {
    func verifyApprovalControls(destination: URL, then finish: @escaping () -> Void) {
        Task { @MainActor [self] in
            let model = slack.model, size = preferredChatSize, source = slack.model.source
            let sending = model.onSend
            var sent = 0
            model.onSend = { _, _, _, _ in sent += 1 }
            model.source = .slack; model.select("CCOW")
            guard let thread = model.threads.first(where: { SlackNotice.pendingApproval($0, confirmed: model.confirmed) != nil }) else {
                smokeFailed("Approval captures require a synthetic pending request")
            }
            let reader = SlackController(); reader.persists = false
            reader.model.onConfirm?(thread)
            smokeCheck(reader.localThreads == [thread.room + ":" + thread.ts: thread.latest], "Confirm queues only its target")
            for approve in [true, false] {
                let completed = SlackController(); completed.persists = false
                var sentWord = ""
                completed.model.onSend = { text, room, target, _ in
                    smokeCheck(room == thread.room && target?.id == thread.id, "Approval reply targets the handled thread")
                    sentWord = text; completed.didSend(to: target)
                }
                completed.model.answer(thread, approve: approve)
                smokeCheck(sentWord == SlackNotice.answerText(thread, approve: approve)
                           && completed.localThreads == [thread.room + ":" + thread.ts: thread.latest],
                           "Approval and denial dispatch to the successful reply completion")
                let flow = ([thread.root] + thread.replies.filter(\.slackBroadcast)).map { $0.date.timeIntervalSince1970 }.max() ?? 0
                smokeCheck(completed.localRead == [thread.room: flow], "Reply completion queues only observed channel-flow messages")
                completed.model.onSend = nil
            }
            let unopened = SlackController(); unopened.persists = false
            unopened.didSend(to: nil)
            smokeCheck(unopened.localRead.isEmpty && unopened.localThreads.isEmpty, "New post completion does not mark any old thread")
            if let completed = model.threads.first(where: { SlackNotice.isSettled($0) }) {
                model.open = [completed.id]; model.requestScroll(completed.id)
                try? await Task.sleep(nanoseconds: 800_000_000)
                capture(destination: destination.appendingPathComponent("settled-status"))
            }
            model.open = [thread.id]
            model.requestScroll(SlackModel.end(thread.id))
            for (name, width) in [("approval-narrow", PetLayout.minimumChatSize.width), ("approval-wide", CGFloat(620))] {
                resizeChat(to: CGSize(width: width + slackStrip, height: 620))
                model.requestScroll(SlackModel.end(thread.id))
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let row = chat.smokeFrames["approval-" + thread.id] else { smokeFailed("Approval row must be measurable") }
                smokeCheck(row.width <= chat.viewportWidth - ChatMetrics.horizontalInset * 2 - ChatMetrics.avatar - 9,
                           "Four approval controls fit the conversation without wrapping: \(row)")
                capture(destination: destination.appendingPathComponent(name))
            }
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let frame = chat.smokeFrames["confirm-" + thread.id],
                  let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first else { smokeFailed("Confirm button must be measurable") }
            let point = host.convert(CGPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            smokeCheck(slack.localThreads[thread.room + ":" + thread.ts] == thread.latest,
                       "Confirm queues the handled thread even when smoke disables remote writes")
            smokeCheck(model.bells[thread.id] == nil && sent == 0 && !model.notices.contains { $0.threads.contains(thread.id) },
                       "Clicking Confirm removes the question and bell without sending")
            smokeCheck(SlackNotice.pendingApproval(thread, confirmed: model.confirmed) == nil
                       && SlackNotice.state(thread, confirmed: model.confirmed) == nil
                       && !SlackNotice.displayed(thread, confirmed: model.confirmed).messages.flatMap(\.marks).contains { $0.text == SlackNotice.draft }
                       && chat.smokeFrames["approval-" + thread.id] == .zero
                       && chat.smokeFrames["confirm-" + thread.id] == .zero,
                       "Confirm removes the approval row and waiting state")
            capture(destination: destination.appendingPathComponent("approval-confirmed"))
            model.confirm(thread)
            smokeCheck(model.bells[thread.id] == nil && sent == 0, "Confirm never restores the question")
            try! "PASS: four approval controls at minimum and wide widths; real Confirm click sends nothing and removes the row, waiting state, bell and count; repeated Confirm stays settled.\n"
                .write(to: destination.appendingPathComponent("approval.txt"), atomically: true, encoding: .utf8)
            guard let learning = model.threads.first(where: { SlackNotice.isLearningReport($0) }) else {
                smokeFailed("Learning captures require a synthetic report")
            }
            model.open = [learning.id]
            for (name, width) in [("learning-narrow", PetLayout.minimumChatSize.width), ("learning-wide", CGFloat(620))] {
                resizeChat(to: CGSize(width: width + slackStrip, height: 620))
                model.requestScroll(SlackModel.end(learning.id))
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let row = chat.smokeFrames["approval-" + learning.id] else { smokeFailed("Learning buttons must be measurable") }
                smokeCheck(row.width <= chat.viewportWidth - ChatMetrics.horizontalInset * 2 - ChatMetrics.avatar - 9,
                           "Four learning controls fit without wrapping: \(row)")
                capture(destination: destination.appendingPathComponent(name))
            }
            var words: [String] = []
            model.onSend = { text, room, target, _ in
                smokeCheck(room == learning.room && target?.id == learning.id, "Learning replies stay in their report thread")
                self.slack.didSend(to: target) // A successful fake send uses the production completion path.
                smokeCheck(self.slack.localThreads[learning.room + ":" + learning.ts] == learning.latest,
                           "Approval and denial queue a read receipt after successful sending")
                words.append(text)
            }
            let queuedBeforeNewPost = slack.localThreads
            slack.didSend(to: nil)
            smokeCheck(slack.localThreads == queuedBeforeNewPost, "New posts do not mark other threads read")
            model.answer(learning, approve: true); model.answer(learning, approve: false)
            smokeCheck(words == ["학습승인", "학습거절"], "Learning buttons send review words")
            model.reply(learning)
            smokeCheck(model.replyThread?.id == learning.id && words.count == 2, "Revision aims the composer without sending")
            model.confirm(learning)
            try? await Task.sleep(nanoseconds: 600_000_000)
            smokeCheck(model.bells[learning.id] == nil && words.count == 2
                       && SlackNotice.pendingApproval(learning, confirmed: model.confirmed) == nil
                       && SlackNotice.state(learning, confirmed: model.confirmed) == nil
                       && !model.notices.contains { $0.threads.contains(learning.id) }
                       && chat.smokeFrames["approval-" + learning.id] == .zero,
                       "Learning confirmation removes the waiting state, row, bell and count without sending")
            try! "PASS: learning controls fit minimum and wide widths; review words, revision target and confirmation settling the report checked.\n"
                .write(to: destination.appendingPathComponent("learning.txt"), atomically: true, encoding: .utf8)
            model.onSend = sending; model.foldAll(); model.source = source
            resizeChat(to: CGSize(width: size.width + slackStrip, height: size.height))
            try? await Task.sleep(nanoseconds: 400_000_000)
            finish()
        }
    }
}

// MARK: Room portraits
extension AppDelegate {
    /// Isolated synthetic rooms after the interaction checks, with several members in each.
    func verifyRoomFaces(destination: URL) {
        let wide = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        let square = SlackRoomPictures.squared(wide)
        smokeCheck(square?.size == NSSize(width: SlackRoomPictures.side, height: SlackRoomPictures.side), "A channel's picture is kept as a small square: \(String(describing: square?.size))")
        let styled = DdotsConfig.shared.appearance["roomPictures"] != nil
        if styled {
            smokeCheck(Ddots.roomPictures.count == 4, "The 학습 채널, 보고 채널, SNS담당방 and secret room pictures load from the app bundle: \(Ddots.roomPictures.keys.sorted())")
        } else {
            smokeCheck(Ddots.roomPictures.isEmpty, "Without local room picture settings, no bundled room pictures are applied")
        }
        let senderStyled = DdotsConfig.shared.appearance["senderPictures"] != nil
        if senderStyled {
            smokeCheck(Ddots.senderPictures["새우튀김"] != nil, "The shrimp picture loads from the app bundle")
            smokeCheck(Ddots.avatar(nil, name: "새우튀김")?.image != nil
                       && Ddots.avatar(ProfileAvatar(), name: "새우튀김")?.image != nil
                       && Ddots.avatar(nil, name: "다른 이름") == nil, "Only the exact sender name supplies a missing picture")
        } else {
            smokeCheck(Ddots.senderPictures.isEmpty && Ddots.avatar(nil, name: "새우튀김") == nil,
                       "Without local sender picture settings, no bundled sender pictures are applied")
        }
        if !styled && !senderStyled {
            smokeCheck(Ddots.roomPictures.isEmpty && Ddots.senderPictures.isEmpty && Ddots.avatar(nil, name: "새우튀김") == nil,
                       "Without the local appearance file, no bundled room or sender pictures are applied")
        }
        let existing = ProfileAvatar(image: wide)
        smokeCheck(Ddots.avatar(existing, name: "새우튀김") == existing, "An existing profile picture takes precedence")
        let model = slack.model
        let rooms = [SlackRoom(id: "CCOW", name: "SNS담당방", direct: false),
                     SlackRoom(id: "Coffice", name: "업무비서방", direct: false),
                     SlackRoom(id: "CMAINT", name: "maintencance", direct: false)]
        let cast = [(profile: "sns-manager", name: "SNS담당"),
                    (profile: "work-assistant", name: "업무비서"),
                    (profile: "system-doctor", name: "진단담당")]
        if let (id, profile) = (DdotsConfig.shared.document["rooms"] as? [String: String])?.sorted(by: { $0.key < $1.key }).first {
            let configuredRoom = SlackRoom(id: id, name: "가짜", direct: false)
            smokeCheck(Ddots.representative(configuredRoom)?.profile == profile,
                       "Room owners come from the Hermes config by Slack ID")
        }
        let members = cast.map { SlackMember(profile: $0.profile, name: $0.name, user: "U-" + $0.profile) }
        let home = ProcessInfo.processInfo.environment["HERMES_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        let cache = ProfileAvatarCache()
        var pictures: [String: ProfileAvatar] = [:], sources: [String] = []
        for (who, symbol) in zip(cast, ["leaf.fill", "drop.fill", "wrench.fill"]) {
            let root = home.appendingPathComponent("profiles/" + who.profile)
            let avatar = cache.load(profile: who.profile, root: root, url: ProfileAvatarCache.avatarURL(root: root))
            let photo = avatar.image != nil
            pictures[who.profile] = photo ? avatar : ProfileAvatar(image: NSImage(systemSymbolName: symbol, accessibilityDescription: who.name))
            chat.avatars[who.profile] = pictures[who.profile]
            sources.append(who.profile + ": " + (photo ? "사진" : "기호"))
            smokeCheck(chat.avatars[who.profile]?.image != nil, "Room portrait fixture decodes: " + who.profile)
        }
        model.source = .slack
        model.rooms = rooms + [SlackRoom(id: "CSECRET", name: "secret", direct: false),
                               SlackRoom(id: "DSHRIMP", name: "새우튀김", direct: true)]
        for room in rooms { model.members[room.id] = members }
        model.members["CSECRET"] = []; model.members["DSHRIMP"] = []
        chat.avatars.removeValue(forKey: "")
        model.selected = "CSECRET"
        model.foldAll(); model.notices = []; model.draft = ""
        let message = ChatMessage(id: "shrimp-fixture", fromUser: false, speaker: "새우튀김",
                                  body: "가짜 자료로 사진을 확인하고 있어요.", date: Date(), profile: "")
        let cow = ChatMessage(id: "cow-fixture", fromUser: false, speaker: "SNS담당",
                              body: "다른 캐릭터의 프로필 사진은 그대로예요.", date: Date(), profile: "sns-manager")
        model.threads = [message, cow].enumerated().map { index, line in
            SlackThread(id: line.id, room: "CSECRET", ts: String(index + 1), root: line,
                        replies: [], replyCount: 0, loaded: true, latest: line.date.timeIntervalSince1970, latestFromUser: false)
        }
        model.requestScroll("slack-bottom")
        model.dragSidebar(to: SlackSidebar.width)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            smokeCheck(pictures.allSatisfy { chat.avatars[$0.key] == $0.value }, "Room portraits survive until the tab capture")
            smokeCheck(model.threads.first?.root == message, "The empty-profile shrimp message survives until the tabs capture")
            capture(destination: destination.appendingPathComponent("room-faces-tabs"))
            smokeCheck(rooms.allSatisfy { model.members[$0.id]?.count == 3 }, "A single portrait leaves all three mention members intact")
            model.dragSidebar(to: 212)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                smokeCheck(pictures.allSatisfy { chat.avatars[$0.key] == $0.value }, "Room portraits survive until the list capture")
                smokeCheck(model.threads.first?.root == message, "The empty-profile shrimp message survives until the list capture")
                capture(destination: destination.appendingPathComponent("room-faces-list"))
                try! ("PASS: three room portraits plus secret and the empty shrimp DM captured at 68pt and 212pt; three members retained in the original rooms; empty-profile shrimp sender shown.\n" + sources.joined(separator: "\n") + "\n")
                    .write(to: destination.appendingPathComponent("room-faces.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }
}
