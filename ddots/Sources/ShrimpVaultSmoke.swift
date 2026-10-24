import Foundation
import AppKit
import SwiftUI

private let smokeVaultBot = "UFAKEVAULTBOT"

extension AppDelegate {
    /// No live bridge, default writes, Finder calls or workspace opens.
    func verifyShrimpVaultSmoke() {
        let model = SlackModel()
        model.source = .slack; model.selected = "FAKE-VAULT"
        model.vaultOverride = ShrimpVault(root: FileManager.default.temporaryDirectory.path, bot: smokeVaultBot)
        let now = Date()
        var selected = ChatMessage(id: "fake-selected", fromUser: false, speaker: "새우튀김",
            body: "선택: 가짜 문서.md", date: now)
        selected.slackUserID = smokeVaultBot
        var fallback = selected
        fallback.id = "fake-buttons"; fallback.body = "경로 줘 · 열어줘 · 다운로드 · 수정 · 종결 — 글로 보내도 됩니다"
        var preview = selected
        preview.id = "upload-preview"
        preview.body = "저장 미리보기\n- 가짜.txt · .txt · 4바이트 · 파일 추가\n5분 안에 이 스레드에서 승인해 주세요. ‘승인’ 또는 ‘거부’로 답하면 돼요."
        let approvalThread = SlackThread(id: "upload-approval", room: "FAKE-VAULT", ts: "1", root: preview,
            replies: [], replyCount: 0, loaded: true, latest: now.timeIntervalSince1970, latestFromUser: false)
        smokeCheck(SlackNotice.pendingApproval(approvalThread) != nil, "Uploaded file preview uses existing approval controls")
        preview.body = "어느 폴더에 넣을까요?\n0. 최상위\n1. 가짜 폴더"
        smokeCheck(!SlackNotice.requestsApproval(preview.body), "Folder choice does not become approval")
        let thread = SlackThread(id: "fake-vault-thread", room: "FAKE-VAULT", ts: "1", root: selected,
            replies: [fallback], replyCount: 1, loaded: true, latest: now.timeIntervalSince1970, latestFromUser: false)
        model.threads = [thread]
        model.vaultOverride = ShrimpVault(root: FileManager.default.temporaryDirectory.path, bot: "")
        smokeCheck(model.vaultSelection(thread) == nil, "Vault buttons appear only when vaultBotUserID is set")
        model.vaultOverride = ShrimpVault(root: FileManager.default.temporaryDirectory.path, bot: smokeVaultBot)
        guard let selection = model.vaultSelection(thread) else { smokeFailed("Trusted selection offers vault buttons") }
        var sends: [String] = [], opens: [String] = []
        model.onSend = { text, room, target, _ in
            smokeCheck(room == thread.room && target?.id == thread.id, "Vault action keeps thread destination")
            sends.append(text)
        }
        model.vaultOpen = { opens.append($0); return nil }
        model.vaultAction("경로 줘", thread: thread, selection: selection)
        model.vaultAction("경로 줘", thread: thread, selection: selection)
        model.vaultAction("다운로드", thread: thread, selection: selection)
        model.vaultAction("다운로드", thread: thread, selection: selection)
        smokeCheck(sends == ["경로 줘: 가짜 문서.md", "다운로드: 가짜 문서.md"], "Vault path/download send each exact command once")
        model.vaultAction("파일오픈", thread: thread, selection: selection)
        smokeCheck(opens == ["가짜 문서.md"] && sends.count == 2, "Vault open is local-only through injected operation")
        var revealed: [String] = []
        model.vaultReveal = { revealed.append($0); return nil }
        var pathMessage = selected
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("FAKE-note.md")
        pathMessage.body = "대상: 가짜 문서.md\n" + path.path
        smokeCheck(model.vaultPath(path, message: pathMessage) && revealed == [path.path] && sends.count == 2,
            "Trusted path click reveals locally without Slack")
        pathMessage.slackUserID = "OTHER"
        smokeCheck(!model.vaultPath(path, message: pathMessage) && revealed.count == 1, "Untrusted path click rejected")
        model.replyTo = "another"
        model.vaultAction("파일오픈", thread: thread, selection: selection)
        smokeCheck(opens.count == 2, "Other reply target does not hide independent selection")
        model.replyTo = nil
        var changed = thread
        changed.replies.append(ChatMessage(id: "new-search", fromUser: true, speaker: "나", body: "다른 검색", date: now))
        model.threads = [changed]
        model.vaultAction("파일오픈", thread: thread, selection: selection)
        smokeCheck(opens.count == 3 && model.vaultSelection(changed) != nil, "New search preserves captured selection")
        model.threads = [thread]
        var other = thread
        other.id = "new-root"; other.root = ChatMessage(id: "new-root", fromUser: true, speaker: "나",
            body: "새 자료", date: now.addingTimeInterval(1)); other.replies = []
        model.threads.append(other)
        smokeCheck(model.vaultSelection(thread) != nil, "New channel-root search preserves old buttons")
        model.threads = [thread]; model.selected = "OTHER"
        model.vaultAction("파일오픈", thread: thread, selection: selection)
        smokeCheck(opens.count == 3, "Changing rooms invalidates captured buttons")
        model.threads = [thread]; model.selected = thread.room; model.replyTo = nil
        model.draft = "작성 중"
        model.vaultAction("수정", thread: thread, selection: selection)
        model.vaultAction("수정", thread: thread, selection: selection)
        smokeCheck(model.target?.id == thread.id && model.draft == "작성 중" && sends == ["경로 줘: 가짜 문서.md", "다운로드: 가짜 문서.md", "수정: 가짜 문서.md"],
            "Modify sends once, keeps draft, and routes questions to this thread")
        smokeCheck(model.vaultSelection(thread) != nil, "Modify preserves other actions")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vault-picker-" + UUID().uuidString)
        let suite = "vault-picker-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: scratch) }
        model.vaultSettings = ShrimpVaultSettings(defaults: defaults, file: scratch.appendingPathComponent("root.json"))
        model.vaultOverride = ShrimpVault(root: nil, bot: smokeVaultBot)
        model.vaultPicker = { scratch }
        model.chooseVaultFolder()
        smokeCheck(model.vault.root == scratch.path && model.vaultSettings?.restore() == scratch.path, "Injected folder picker saves both stores")
        var second = selected; second.id = "second"; second.body = "선택: 가짜표.xlsx → 시험 시트 → 김가짜\n- pw: 0012"
        var multiple = thread; multiple.replies += [second]
        model.threads = [multiple]; model.vaultOverride = ShrimpVault(root: nil, bot: smokeVaultBot)
        let choices = model.vaultSelections(multiple)
        smokeCheck(choices.count == 2 && choices[1].editable, "Each selection persists and workbook row defaults editable")
        model.vaultAction("다운로드", thread: multiple, selection: choices[1])
        smokeCheck(sends.last == "다운로드: 가짜표.xlsx → 시험 시트 → 김가짜", "Text action works without root")
        let closeModel = SlackModel()
        closeModel.source = .slack; closeModel.selected = thread.room
        closeModel.vaultOverride = model.vaultOverride; closeModel.threads = [thread]
        var closes: [String] = []
        closeModel.onSend = { text, _, _, _ in closes.append(text) }
        closeModel.vaultAction("종결", thread: thread, selection: selection)
        closeModel.vaultAction("종결", thread: thread, selection: selection)
        smokeCheck(closes == ["종결: 가짜 문서.md"] && closeModel.vaultSelection(thread) == nil, "Close sends once and immediately hides buttons")
    }
}

extension AppDelegate {
    func showShrimpVaultSmoke(destination: URL) {
        if CommandLine.arguments.contains("--ui-smoke-thread-actions") { Task { await self.threadActionsSmoke(destination: destination) }; return }
        let model = slack.model
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-vault-ui-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SmokeLeftovers.note(root)
        model.vaultOverride = ShrimpVault(root: root.path, bot: smokeVaultBot)
        model.vaultOpen = { _ in nil }; model.vaultReveal = { _ in nil }; model.onSend = { _, _, _, _ in }
        model.query = ""; model.draft = ""; model.replyTo = nil; model.picked = nil
        var choice = ChatMessage(id: "vault-choice", fromUser: false, speaker: "새우튀김",
            body: "선택: 회사 자료/가짜 메모.md", date: Date(), profile: "fried-shrimp")
        choice.slackUserID = smokeVaultBot
        var buttons = choice; buttons.id = "vault-fallback"
        buttons.body = "경로 줘 · 열어줘 · 다운로드 · 수정 · 종결 — 글로 보내도 됩니다"
        var path = choice; path.id = "vault-path"
        path.body = "대상: 회사 자료/가짜 메모.md\n" + root.appendingPathComponent("회사 자료/가짜 메모.md").path
        let thread = SlackThread(id: "vault-ui", room: "CCOW", ts: "1", root: choice,
            replies: [buttons, path], replyCount: 2, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
        var multiple = thread
        var second = choice; second.id = "vault-second"; second.body = "선택: 가짜표.xlsx → 시험 시트 → 김가짜\n- id: FAKE-ID\n- pw: 0012"
        multiple.replies.append(second); multiple.replyCount += 1
        model.threads = [multiple]; model.open = [thread.id]; model.reply(multiple)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            for action in ["경로 줘", "파일오픈", "다운로드", "수정", "종결"] {
                smokeCheck((chat.smokeFrames["vault-" + action + "-" + choice.id]?.width ?? 0) > 0, "Vault button is laid out: " + action)
            }
            let rowFrames = ["경로 줘", "파일오픈", "다운로드", "수정", "종결"].compactMap { chat.smokeFrames["vault-" + $0 + "-" + choice.id] }
            smokeCheck(rowFrames.count == 5 && (rowFrames.map(\.midY).max()! - rowFrames.map(\.midY).min()!) < 2, "Five vault buttons share one row")
            smokeCheck(rowFrames.count == 5 && (rowFrames.map(\.maxX).max()! - rowFrames.map(\.minX).min()!) <= 330, "Five compact buttons fit 330pt")
            smokeCheck(model.vaultSelections(multiple).count == 2, "Both visible selections retain actions")
            capture(destination: destination.appendingPathComponent("vault-buttons"))
            model.vaultOverride = ShrimpVault(root: nil, bot: smokeVaultBot)
            var picture = choice; picture.id = "vault-picture"; picture.body = "표 사진과 복사용 글"
            picture.files = [ChatFile(id: "FAKE-TABLE", name: "표.png", mimetype: "image/png"),
                             ChatFile(id: "FAKE-DELETED", name: "표.png", mimetype: "image/png", deleted: true)]
            let image = NSImage(size: NSSize(width: 800, height: 240))
            image.lockFocus()
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 800, height: 240).fill()
            ("합성 표 사진   이름 / id / pw\n김가짜   FAKE-ID   0012" as NSString).draw(at: NSPoint(x: 30, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
            image.unlockFocus()
            model.thumbs["FAKE-TABLE"] = image
            multiple.replies.append(picture); multiple.replyCount += 1
            model.threads = [multiple]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                model.scrollTarget = "slack-bottom"; model.scrollRevision += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                capture(destination: destination.appendingPathComponent("vault-image-and-missing-root"))
                try? "vault model and UI checks passed\n".write(to: destination.appendingPathComponent("vault.txt"), atomically: true, encoding: .utf8)
                var upload = ChatMessage(id: "upload-demo", fromUser: true, speaker: "본인", body: "가짜 서류 폴더에 넣어줘", date: Date())
                upload.files = [ChatFile(id: "UPLOAD-DEMO", name: "가짜서류.txt", size: 4)]
                var preview = choice; preview.id = "upload-demo-preview"
                preview.body = "저장 미리보기\n- 가짜 서류/가짜서류.txt · .txt · 4바이트 · 파일 추가\n5분 안에 이 스레드에서 승인해 주세요. ‘승인’ 또는 ‘거부’로 답하면 돼요."
                let staging = SlackThread(id: "upload-demo-thread", room: "CCOW", ts: "2", root: upload,
                    replies: [preview], replyCount: 1, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
                model.threads = [staging]; model.open = [staging.id]; model.reply(staging)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.capture(destination: destination.appendingPathComponent("upload-preview"))
                    self.showShrimpOrderSmoke(destination: destination, old: false)
                }
            }
        }
    }
    func showShrimpOrderSmoke(destination: URL, old: Bool) {
        let model = slack.model
        var picture = ChatMessage(id: "order-picture", fromUser: false, speaker: "새우튀김", body: "", date: Date(), profile: "fried-shrimp")
        picture.slackUserID = smokeVaultBot
        picture.files = [ChatFile(id: "FAKE-TABLE", name: "표-120000.png", mimetype: "image/png")]
        var choice = picture; choice.id = "order-choice"; choice.files = []
        choice.body = "선택: 가짜표.xlsx → 시험 시트 → 김가짜\n- 이름: 김가짜\n- id: FAKE-ID\n- pw: 0012"
        var fallback = choice; fallback.id = "order-fallback"
        fallback.body = "경로 줘 · 열어줘 · 다운로드 · 수정 · 종결 — 글로 보내도 됩니다"
        let lines = old ? [choice,picture,fallback] : [picture,choice,fallback]
        let thread = SlackThread(id: "order-demo", room: "CCOW", ts: "3", root: lines[0], replies: Array(lines.dropFirst()), replyCount: 2, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
        model.threads = [thread]; model.open = [thread.id]; model.reply(thread)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.capture(destination: destination.appendingPathComponent(old ? "old-image-order" : "new-image-order"))
            if old { self.showShrimpTableRequestSmoke(destination: destination) } else { self.showShrimpOrderSmoke(destination: destination, old: true) }
        }
    }

    func showShrimpTableRequestSmoke(destination: URL) {
        let model = slack.model
        model.vaultOverride = ShrimpVault(root: FileManager.default.temporaryDirectory.path, bot: smokeVaultBot)
        var choice = ChatMessage(id: "table-choice", fromUser: false, speaker: "새우튀김",
            body: "선택: 가짜표.xlsx → 시험 시트 → 김가짜\n- 이름: 김가짜\n- id: FAKE-ID\n- pw: 0012", date: Date(), profile: "fried-shrimp")
        choice.slackUserID = smokeVaultBot
        var fallback = choice; fallback.id = "table-fallback"
        fallback.body = "경로 줘 · 열어줘 · 다운로드 · 표 · 수정 · 종결 — 글로 보내도 됩니다"
        let thread = SlackThread(id: "table-thread", room: "CCOW", ts: "4", root: choice,
            replies: [fallback], replyCount: 1, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
        model.threads = [thread]; model.open = [thread.id]; model.reply(thread)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let actions = ["경로 줘", "파일오픈", "다운로드", "표", "수정", "종결"]
            let frames = actions.compactMap { self.chat.smokeFrames["vault-" + $0 + "-" + choice.id] }
            smokeCheck(frames.count == 6 && frames.allSatisfy { $0.width > 0 && $0.height > 0 }, "Six table buttons have measurable scroll content frames")
            smokeCheck((frames.map(\.midY).max()! - frames.map(\.midY).min()!) < 2, "Six buttons stay on one horizontal row")
            smokeCheck(zip(frames,frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 1 }, "Six button frames do not overlap inside scroll content")
            self.capture(destination: destination.appendingPathComponent("table-six-buttons"))
            var sent: [String] = []
            model.onSend = { text, room, target, _ in
                smokeCheck(room == "CCOW" && target?.id == thread.id, "Table sends in original thread")
                sent.append(text)
            }
            let selection = model.vaultSelection(thread)!
            model.vaultAction("표", thread: thread, selection: selection)
            model.vaultAction("표", thread: thread, selection: selection)
            smokeCheck(sent == ["표: 가짜표.xlsx → 시험 시트 → 김가짜"], "Table sends exact target once")
            var request = choice; request.id = "table-request"; request.fromUser = true; request.slackUserID = "FAKE-SELF"
            request.body = sent[0]
            var image = choice; image.id = "table-image"; image.body = ""
            image.files = [ChatFile(id: "FAKE-TABLE", name: "표-120000.png", mimetype: "image/png")]
            var shown = thread; shown.replies = [fallback,request,image]; shown.replyCount = 3
            model.threads = [shown]
            let layout = model.vault.presentation(shown, active: model.vault.selections(shown), visible: Set(shown.messages.map(\.id)), pending: nil)
            smokeCheck(layout.anchors[choice.id] != nil && layout.anchors[image.id] == nil, "Requested table leaves buttons below original selection")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.capture(destination: destination.appendingPathComponent("requested-table"))
                var preview = choice; preview.id = "table-preview"
                preview.body = "기존 값 수정 · 가짜표.xlsx · 시험 시트\n- pw: 0012 → 888\n5분 안에 이 스레드에서 승인해 주세요. ‘승인’ 또는 ‘거부’로 답하면 돼요."
                var approval = choice; approval.id = "table-approval"; approval.body = "승인 · 거부 — 글로 보내도 됩니다"
                let final = SlackThread(id: "table-preview-thread", room: "CCOW", ts: "5", root: image,
                    replies: [preview,approval], replyCount: 2, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
                model.threads = [final]; model.open = [final.id]; model.reply(final)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.capture(destination: destination.appendingPathComponent("table-change-preview"))
                    self.showCandidateSmoke(destination: destination)
                }
            }
        }
    }

}

extension AppDelegate {
    func showCandidateSmoke(destination: URL) {
        let model = slack.model
        let text = """
'가짜새' 검색 결과

연락표.xlsx
   가짜팀
1. → 안내 시트 → 가짜새
2. → 둘째 시트 → 가짜새

아주 긴 파일 이름이 붙은 합성 업무 자료.xlsx
   가짜/깊은/폴더
3. → 시험 시트 → 가짜새 (142행)
4. → 시험 시트 → 가짜새 (143행)

최상위.pdf
5. → 7페이지

합성.md
   노트
6. → 12번째 줄

7. 자료.zip

— 유사 결과 —

가짜.txt
8. → 3번째 줄

다음 목록으로 더 볼 수 있어요.

어느 항목인가요?
"""
        var message = ChatMessage(id: "candidate-colors", fromUser: false, speaker: "새우튀김", body: text, date: Date(), profile: "fried-shrimp")
        message.slackUserID = smokeVaultBot
        let thread = SlackThread(id: "candidate-colors-thread", room: "CCOW", ts: "6", root: message, replies: [], replyCount: 0, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
        chat.expandedReplies.insert(message.id)
        model.threads = [thread]; model.open = [thread.id]; model.reply(thread)
        let old = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.capture(destination: destination.appendingPathComponent("candidates-light"))
            NSApp.appearance = NSAppearance(named: .darkAqua)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.capture(destination: destination.appendingPathComponent("candidates-dark"))
                NSApp.appearance = old
                self.showPaginationSmoke(destination: destination)
            }
        }
    }
}


extension AppDelegate {
    func showPaginationSmoke(destination: URL) {
        let model = slack.model
        model.onPageSend = nil
        model.source = .slack; model.selected = "CCOW"
        var first = ChatMessage(id: "page-first", fromUser: false, speaker: "새우튀김", body: "1/3쪽 · 총 30건\n\n1. 가짜연락망.xlsx\n   가짜/깊은/폴더\n\n어느 항목인가요?", date: Date(), profile: "fried-shrimp")
        first.slackUserID = smokeVaultBot
        var controls = first; controls.id = "page-controls"
        controls.body = "쪽 1/3 · 총 30건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다"
        var full = first; full.id = "page-full"
        full.body = "전체 목록 1/1 · 총 30건\n\n" + (1...30).map { "\($0). 가짜연락망-아주긴자료이름-\($0).xlsx\n   가짜/깊은/시험폴더" }.joined(separator: "\n\n")
        var thread = SlackThread(id: "page-thread", room: "CCOW", ts: "8", root: first, replies: [controls], replyCount: 1, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
        model.threads = [thread]; model.open = [thread.id]; model.reply(thread)
        var sent: [String] = []
        model.onSend = { text, room, target, _ in
            smokeCheck(room == "CCOW" && target?.id == thread.id, "Page command preserves thread")
            sent.append(text)
        }
        model.shrimpPageCommand("쪽: 3", message: controls); model.shrimpPageCommand("쪽: 3", message: controls)
        smokeCheck(sent == ["쪽: 3"], "Page command exact and duplicate guarded")
        controls.body = controls.body.replacingOccurrences(of: "1/3", with: "3/3")
        thread.root.body = "3/3쪽 · 총 30건\n\n21. 가짜21.xlsx\n\n30. 가짜30.xlsx"
        thread.replies = [controls]; model.threads = [thread]
        smokeCheck(ShrimpPage.parse(model.threads[0].replies[0].body)?.current == 3 && model.threads[0].root.body.contains("21."), "Same message IDs accept edited page body")
        var foreign = controls; foreign.slackUserID = "OTHER"; thread.replies.append(foreign); model.threads = [thread]
        model.shrimpPageCommand("쪽: 1", message: foreign)
        smokeCheck(sent.count == 1, "Other sender page controls refused")
        thread.replies = [controls,full]; model.threads = [thread]
        smokeCheck(model.shrimpAll(thread.id).map(\.number) == Array(1...30), "Whole list merges in memory with original numbering")
        var allSent = 0
        var finishAll: (() -> Void)?
        model.onPageSend = { command, target, completion in
            smokeCheck(command == "전체 보기" && target.id == thread.id, "All request uses bounded navigation path")
            allSent += 1; finishAll = completion
        }
        model.shrimpPageCommand("전체 보기", message: controls)
        smokeCheck(allSent == 0, "Complete list reopens without sending")
        thread.replies = [controls]; model.threads = [thread]
        model.shrimpPageCommand("전체 보기", message: controls)
        model.shrimpPageCommand("전체 보기", message: controls)
        model.shrimpPageCommand("쪽: 2", message: controls)
        smokeCheck(model.shrimpPendingPages[controls.id] == nil, "Page click while loading all list is refused without stuck spinner")
        smokeCheck(allSent == 1, "Missing list sends once even on repeated clicks")
        finishAll?(); model.onPageSend = nil
        var ownAll = full; ownAll.id = "own-all-command"; ownAll.fromUser = true; ownAll.body = "전체 보기"
        thread.replies = [controls,ownAll,full]; model.threads = [thread]
        smokeCheck(!model.vault.hidingPageCommands(thread).messages.contains { $0.id == ownAll.id }, "All command has no visible reply slot")
        model.shrimpPageCommand("24번", message: full)
        smokeCheck(sent.last == "24번", "Whole item sends numbered selection")
        smokeCheck(model.open.contains(thread.id), "Whole-list numbered selection preserves opened thread")
        model.shrimpListThread = thread.id; model.shrimpListPage = 1; web.showShrimpList()
        let appearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.capture(destination: destination.appendingPathComponent("pagination-light"))
            model.shrimpListPage = 2; NSApp.appearance = NSAppearance(named: .darkAqua)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.capture(destination: destination.appendingPathComponent("pagination-dark-page2"))
                thread.replies = [controls]; model.threads = [thread]
                smokeCheck(model.shrimpAll(thread.id).isEmpty, "Deleted whole-list chunks disappear from native pane")
                NSApp.appearance = appearance; self.showPageUXSmoke(destination: destination, thread: thread, controls: controls, full: full)
            }
        }
    }
}


extension AppDelegate {
    func showPageUXSmoke(destination: URL, thread: SlackThread, controls: ChatMessage, full: ChatMessage) {
        Task { @MainActor in
            let model = slack.model
            var live = thread; live.replies = [controls, full]; model.threads = [live]
            var hidden = ChatMessage(id: "hidden-page-one", fromUser: true, speaker: "가짜 사용자", body: "쪽: 2", date: Date())
            hidden.slackUserID = "FAKEME"
            var hiddenTwo = hidden; hiddenTwo.id = "hidden-page-two"; hiddenTwo.body = "쪽: 3"
            live.replies = [controls,hidden,hiddenTwo,full]; model.threads = [live]
            let presentation = model.vault.presentation(live, active: [], visible: Set(live.messages.map(\.id)), pending: nil)
            smokeCheck(presentation.hidden.contains(hidden.id) && presentation.hidden.contains(hiddenTwo.id), "Consecutive own commands have no rendered row")
            var sent: [String] = [], finishes: [() -> Void] = []
            model.onPageSend = { command, _, completion in sent.append(command); finishes.append(completion) }
            model.shrimpPageCommand("쪽: 2", message: controls)
            model.shrimpPageCommand("쪽: 3", message: controls)
            try? await Task.sleep(nanoseconds: 300_000_000)
            smokeCheck(sent.isEmpty, "Returning to confirmed page cancels unsent move")
            model.shrimpPageCommand("쪽: 2", message: controls)
            model.shrimpPageCommand("쪽: 1", message: controls)
            smokeCheck(model.shrimpPendingPages[controls.id] == 1, "Page click immediately highlights latest target")
            try? await Task.sleep(nanoseconds: 300_000_000)
            smokeCheck(sent == ["쪽: 1"], "Rapid clicks coalesce into final command")
            model.shrimpPageCommand("쪽: 2", message: controls)
            model.shrimpPageCommand("쪽: 1", message: controls)
            try? await Task.sleep(nanoseconds: 300_000_000)
            smokeCheck(sent.count == 1, "No overlapping page send")
            var updated = controls; updated.body = controls.body.replacingOccurrences(of: "3/3", with: "1/3")
            live.replies = [updated, hidden, hiddenTwo, full]; model.threads = [live]
            finishes[0]()
            smokeCheck(model.shrimpPendingPages[controls.id] == nil, "Confirmed final page clears progress without duplicate send")
            model.shrimpPageCommand("쪽: 2", message: updated)
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.capture(destination: destination.appendingPathComponent("pagination-pending"))
            finishes.last?()
            smokeCheck(model.shrimpPendingPages[controls.id] == nil, "Failure or timeout restores confirmed page")
            model.onPageSend = nil
            model.shrimpListPage = 1; web.showShrimpList()
            try? await Task.sleep(nanoseconds: 700_000_000)
            self.capture(destination: destination.appendingPathComponent("pagination-first"))
            web.shrimpQuery = "가짜연락망 24"
            try? await Task.sleep(nanoseconds: 400_000_000)
            smokeCheck(ShrimpListSearch.filter(model.shrimpAll(model.shrimpListThread), query: web.shrimpQuery).map(\.number) == [24], "Whole pane filter keeps selected number 24")
            self.capture(destination: destination.appendingPathComponent("ux58-search"))
            web.shrimpQuery = ""
            try? await Task.sleep(nanoseconds: 300_000_000)
            let expandedWidth = panel.frame.width
            web.toggleShrimpList()
            try? await Task.sleep(nanoseconds: 900_000_000)
            smokeCheck(web.shrimpCollapsed && !web.open && panel.frame.width < expandedWidth, "Fold leaves title and shrinks window")
            self.capture(destination: destination.appendingPathComponent("pagination-collapsed"))
            web.toggleShrimpList()
            try? await Task.sleep(nanoseconds: 900_000_000)
            smokeCheck(!web.shrimpCollapsed && web.open, "Folded title reopens list")
            web.toggleShrimpList(); web.showShrimpList()
            smokeCheck(!web.shrimpCollapsed, "New whole-list request always starts expanded")
            web.close(); smokeCheck(!web.shrimpList, "Whole-list close still works")
            await verifyUX58(destination: destination)
            NSApp.terminate(nil)
        }
    }
    @MainActor private func verifyUX58(destination: URL) async {
        let model = slack.model
        model.pageHold = nil
        var root = ChatMessage(id: "ux58-root", fromUser: false, speaker: "가짜 봇", body: (1...8).map { "가짜 자료 \($0)\n위치 확인" }.joined(separator: "\n"), date: Date(), profile: "fried_shrimp")
        root.slackUserID = smokeVaultBot
        chat.expandedReplies.insert(root.id)
        var control = root; control.id = "ux58-controls"
        control.body = "쪽 1/3 · 총 25건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다"
        var thread = SlackThread(id: "ux58-thread", room: "CCOW", ts: "58", root: root, replies: [control], replyCount: 5, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
        model.threads = [thread]; model.open = [thread.id]; model.focusThread = nil
        var sends: [String] = []; var complete: (() -> Void)?
        model.onPageSend = { text, _, done in sends.append(text); complete = done }
        model.requestScroll(SlackModel.end(thread.id))
        try? await Task.sleep(nanoseconds: 800_000_000)
        let key = "page-anchor:" + control.id
        func position() -> CGFloat? {
            guard let f = model.rowFrame(key), let scroll = model.scrollView else { return nil }
            return f.minY - scroll.contentView.bounds.minY
        }
        let before = position()
        capture(destination: destination.appendingPathComponent("ux58-page-before"))
        // The frame measured for the checks is not read again after a scroll, so it gives only where the button is across the row;
        // how far down it is comes from the row's own view, which is where it is on screen.
        if let rect = chat.smokeFrames["ux58-page-2"], let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first,
           let row = model.rowViews.object(forKey: key as NSString), row.window === panel {
            let point = NSPoint(x: host.convert(NSPoint(x: rect.midX, y: 0), to: nil).x, y: row.convert(NSPoint(x: 0, y: row.bounds.midY), to: nil).y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!, atStart: false)
            }
        } else { smokeFailed("Page button has measured hit target") }
        try? await Task.sleep(nanoseconds: 400_000_000)
        smokeCheck(sends == ["쪽: 2"] && model.open.contains(thread.id), "Actual page click sends once without folding thread: \(sends) open=\(model.open.contains(thread.id))")
        root.body = "짧은 마지막 쪽"; control.body = control.body.replacingOccurrences(of: "1/3", with: "2/3")
        thread.root = root; thread.replies = [control]; model.threads = [thread]; model.restorePage(); complete?()
        try? await Task.sleep(nanoseconds: 600_000_000)
        capture(destination: destination.appendingPathComponent("ux58-page-after"))
        let positions: [String: Any] = ["before": before ?? -9999, "after": position() ?? -9999, "held": model.pageHold != nil, "open": model.open.contains(thread.id)]
        try? JSONSerialization.data(withJSONObject: positions, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("ux58-positions.json"))
        smokeCheck(before != nil && position() != nil && abs(before! - position()!) < 2, "Page button stays within two points after shorter content")
        smokeCheck(model.open.contains(thread.id), "Same-ts update and request cleanup preserve open thread")
        capture(destination: destination.appendingPathComponent("ux58-page-after"))
        model.pageHold = nil
        web.showShrimpList(); web.shrimpQuery = "가짜 24"
        smokeCheck(ShrimpListSearch.filter((1...30).map { .init(number: $0, file: "가짜-\($0).xlsx", folder: "", location: "") }, query: web.shrimpQuery).map(\.number) == [24], "Filtered choice keeps original number")
        web.showShrimpList(); smokeCheck(web.shrimpQuery.isEmpty, "New whole list clears memory query")
        web.close()
        let tall = ChatMessage(id: "ux58-height", fromUser: false, speaker: "가짜 봇", body: (1...70).map { "긴 가짜 문장 \($0)" }.joined(separator: "\n"), date: Date())
        thread.root = tall; thread.replies = []; thread.replyCount = 0; model.threads = [thread]; model.open = []; model.focusThread = nil
        try? await Task.sleep(nanoseconds: 600_000_000)
        var deletions: [String] = []
        let savedDelete = model.onDelete
        model.onDelete = { deletions.append($0.id) }
        var own = thread; own.id = "ux58-own-single"; own.ts = "59"; own.root.fromUser = true
        model.delete(thread)
        smokeCheck(model.confirmingDelete == nil && deletions.isEmpty, "Bot single post cannot be deleted")
        model.delete(own)
        smokeCheck(deletions.isEmpty && model.confirmingDelete == own.id, "Own single delete first asks confirmation")
        model.delete(own)
        smokeCheck(deletions == [own.id], "Own single second click uses existing deletion path")
        model.onDelete = savedDelete
        let base = preferredChatSize.height
        chat.toggleReply(tall.id)
        try? await Task.sleep(nanoseconds: 700_000_000)
        smokeCheck(chat.replyExtraHeight > 0 && layoutChatSize.height > base, "Measured expansion adds panel height")
        if let placement = pet.placement, let screen = panel.screen { smokeCheck(placement.globalBubble.minY >= screen.visibleFrame.minY && placement.globalBubble.maxY <= screen.visibleFrame.maxY, "Expanded panel stays on screen") }
        capture(destination: destination.appendingPathComponent("ux58-height-expanded"))
        chat.toggleReply(tall.id)
        try? await Task.sleep(nanoseconds: 700_000_000)
        smokeCheck(abs(layoutChatSize.height-base) < 1 && preferredChatSize.height == base, "Collapse restores unchanged saved preference")
        capture(destination: destination.appendingPathComponent("ux58-height-collapsed"))
        chat.toggleReply(tall.id)
        try? await Task.sleep(nanoseconds: 600_000_000)
        resizeChat(to: CGSize(width: pet.chatSize.width, height: base + 25))
        let manual = preferredChatSize.height
        chat.toggleReply(tall.id)
        try? await Task.sleep(nanoseconds: 600_000_000)
        smokeCheck(chat.replyExtraHeight == 0 && layoutChatSize.height == manual, "Manual panel resize survives collapse")

    }

}
