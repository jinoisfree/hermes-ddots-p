import Foundation

@main struct ShrimpVaultTests {
    static func main() throws {
        var checks = try ShrimpReceiptsTests.run()
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !condition() { fatalError(label) }
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("ddots-vault-test-" + UUID().uuidString)
        let root = scratch.appendingPathComponent("vault")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let vault = ShrimpVault(root: root.path)
        let mixed = "전체 목록 1/1 · 총 4건\n\n가짜.xlsx\n   폴더\n1. → 시험 시트 → 가짜하나\n2. → 시험 시트 → 가짜둘\n\n3. 최상위.md\n\n4. 다른.txt\n   폴더"
        check(ShrimpCandidates.scan(mixed).0.map(\.number) == [1,2,3,4], "First full-list candidate survives header and mixed grouping")
        let searchRows = ShrimpCandidates.scan(mixed).0
        check(ShrimpListSearch.filter(searchRows, query: "가짜 둘").map(\.number) == [2], "All words match while original number survives")
        check(ShrimpListSearch.filter(searchRows, query: "가짜 XLSX").map(\.number) == [1,2], "Case insensitive filename matching")
        check(ShrimpListSearch.filter(searchRows, query: "폴더".decomposedStringWithCanonicalMapping).map(\.number) == [1,2,4], "Canonical Korean folder matching")
        check(ShrimpListSearch.filter(searchRows, query: "없는말").isEmpty, "No matches")
        check(ShrimpListSearch.filter(searchRows, query: "  ") == searchRows, "Cleared query restores all numbers")
        struct Fixture: Decodable { let text: String; let expected: [ShrimpCandidates.Candidate] }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/candidate-list.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtureURL))
        for fixture in fixtures {
            check(ShrimpCandidates.scan(fixture.text).0 == fixture.expected, "Shared Python/Swift candidates preserve numbers and locations")
            let styled = ShrimpCandidates.styled(fixture.text, trusted: true, accent: .blue)!
            check(String(styled.characters) == fixture.text, "Candidate styling preserves exact copy text")
            check(ShrimpCandidates.styled(fixture.text, trusted: false, accent: .blue) == nil, "Other senders are not styled")
        }
        struct PagesFixture: Decodable { let page: String; let fallback: String; let all: [String]; let candidates: [ShrimpCandidates.Candidate] }
        let pagesURL = fixtureURL.deletingLastPathComponent().appendingPathComponent("pagination.json")
        let pagesFixture = try JSONDecoder().decode(PagesFixture.self, from: Data(contentsOf: pagesURL))
        check(ShrimpPage.parse(pagesFixture.fallback) == ShrimpPage(current: 1, pages: 3, total: 25), "Shared page fallback")
        check(ShrimpPage.parse(pagesFixture.fallback + " garbage") == nil, "Page fallback anchored")
        check(ShrimpPage.parse(pagesFixture.fallback.replacingOccurrences(of: "1/3", with: "4/3")) == nil, "Invalid page refused")
        check(pagesFixture.all.flatMap { ShrimpCandidates.scan($0).0 } == pagesFixture.candidates, "Shared whole-list numbering")
        check(pagesFixture.all.allSatisfy { ShrimpAllHeader.parse($0)?.total == 25 }, "Whole headers")
        check(ShrimpPage(current: 50, pages: 100, total: 1000).numbers == [1,48,49,50,51,52,100], "Bounded page controls")
        var memoryCache = SlackCache()
        memoryCache.state.history["FAKE"] = [SlackMessage(ts: "1", user: "FAKE", text: "SAFE")]
        memoryCache.state.replies["FAKE"] = ["1": [SlackMessage(ts: "2", threadTS: "1", user: "FAKE", text: pagesFixture.all[0])]]
        let memoryBytes = memoryCache.fitted()!
        check(!String(decoding: memoryBytes, as: UTF8.self).contains("가짜연락망"), "Full list omitted from disk cache")
        let archive = DdotsArchive(root: scratch.appendingPathComponent("record"))
        try archive.append([DdotsLine(ts: "2", thread: "1", profile: "FAKE", name: "FAKE", mine: false, at: 1, text: pagesFixture.all[0])], names: [:])
        check(!fm.fileExists(atPath: archive.root.path), "Full list creates no archive file")
        let selectionText = "선택: 가짜/긴 파일.xlsx → 시험 시트 → 가짜새\n- 이름: 가짜새"
        check(ShrimpCandidates.scan(selectionText).1.count == 1, "Selection first line styles filename only")
        check(String(ShrimpCandidates.styled(selectionText, trusted: true, accent: .blue)!.characters) == selectionText, "Selection label unchanged")
        let numbered = "5. 8. 가짜 메모.md\n   가짜/모음"
        let numberedScan = ShrimpCandidates.scan(numbered)
        check(numberedScan.0 == [.init(number: 5, file: "8. 가짜 메모.md", folder: "가짜/모음", location: "")], "A name starting with a number keeps it")
        check(numberedScan.1.map { (numbered as NSString).substring(with: $0.range) + "|\($0.kind)" } == ["5.|2", "8. 가짜 메모.md|0", "   가짜/모음|1"],
              "The candidate number is styled apart from a name that starts with one: \(numberedScan.1.map { (numbered as NSString).substring(with: $0.range) })")
        let now = Date()
        func message(_ text: String, user: Bool = false, sender: String = ShrimpVault.defaultBot, id: String = UUID().uuidString) -> ChatMessage {
            var message = ChatMessage(id: id, fromUser: user, speaker: "합성 발신자", body: text, date: now)
            message.slackUserID = sender
            return message
        }
        func thread(_ messages: [ChatMessage]) -> SlackThread {
            SlackThread(id: "FAKE:1", room: "FAKE", ts: "1", root: messages[0], replies: Array(messages.dropFirst()), replyCount: messages.count - 1, loaded: true, latest: now.timeIntervalSince1970, latestFromUser: false)
        }
        let chosen = message("선택: 계정 관리.xlsx → 개인 시트 → 가짜 개인용")
        let fallback = message("경로 줘 · 열어줘 · 다운로드 · 수정 · 종결 — 글로 보내도 됩니다")
        let pageOwn = message("쪽: 2", user: true, sender: "ME")
        check(vault.hiddenPageCommand(pageOwn, in: thread([chosen,pageOwn])), "Own exact page command hidden in trusted thread")
        let hiddenThread = vault.hidingPageCommands(thread([chosen,pageOwn,pageOwn]))
        check(hiddenThread.replies.isEmpty && hiddenThread.replyCount == 0, "Hidden commands do not occupy collapsed reply slots or counts")
        check(!vault.hiddenPageCommand(pageOwn, in: thread([pageOwn])), "Untrusted conversation not hidden")
        for candidate in [message("쪽: 2", sender: "OTHER"), message("쪽: 2\n", user: true), message("쪽:2", user: true), message("전체 보기\n", user: true), message("전체 보기", sender: "OTHER")] {
            check(!vault.hiddenPageCommand(candidate, in: thread([chosen,candidate])), "Other sender or nonexact command remains visible")
        }
        let allOwn = message("전체 보기", user: true)
        check(vault.hiddenPageCommand(allOwn, in: thread([chosen, allOwn])), "Own exact all command hidden")
        check(vault.hidingPageCommands(thread([chosen, allOwn, allOwn])).replies.isEmpty, "Repeated all commands leave no slots")
        let page = message("쪽 1/2 · 총 12건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다")
        let part1 = message("전체 목록 1/2 · 총 12건\n\n1. 가짜.xlsx", id: "all1")
        let part2 = message("전체 목록 2/2 · 총 12건\n\n" + (2...12).map { "\($0). 가짜.md" }.joined(separator: "\n\n"), id: "all2")
        let complete = thread([chosen, page, part1, part2])
        check(vault.allList(complete).map(\.number) == Array(1...12), "Complete generation reusable")
        check(vault.allList(thread([chosen,page,part1])).isEmpty, "Incomplete generation not reusable")
        let mismatch = message("쪽 1/2 · 총 13건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다")
        check(vault.allList(thread([chosen,page,part1,part2,mismatch])).isEmpty, "Count mismatch invalidates reuse")
        check(vault.allList(thread([chosen,page,part1,part2,message("1. 새검색.xlsx")])).isEmpty, "New bot search invalidates reuse")
        check(vault.allList(thread([chosen,page,part1,part2,message("새 검색", user:true)])).isEmpty, "New user search invalidates reuse")
        // A later search of ten or fewer has no buttons; 전체 보기 on the older buttons answers with that newer list.
        let olderBody = message("1/2쪽 · 총 12건\n\n" + (1...10).map { "\($0). 옛것.md" }.joined(separator: "\n\n"))
        let newerSearch = message("새 검색", user: true), newerBody = message((1...3).map { "\($0). 새것.md" }.joined(separator: "\n\n"))
        let newerAll = message("전체 목록 1/1 · 총 3건\n\n" + (1...3).map { "\($0). 새것.md" }.joined(separator: "\n\n"))
        let replaced = thread([message("옛 검색", user: true), olderBody, page, newerSearch, newerBody, allOwn, newerAll])
        check(vault.allList(replaced).map(\.file) == ["새것.md", "새것.md", "새것.md"], "The newer search's whole list shows under older buttons")
        check(vault.staleControls(page, in: replaced) && !vault.staleControls(page, in: complete), "Buttons a newer search replaced are stale; a whole list does not replace them")
        let shownAll = vault.hidingPageCommands(thread([chosen,part1,part2,allOwn]))
        check(shownAll.replies.map(\.id) == [part2.id] && shownAll.replyCount == 1, "Only newest all-list notice retains a slot")
        var staleCount = thread([chosen,pageOwn,fallback]); staleCount.replyCount = 1
        check(vault.hidingPageCommands(staleCount).replyCount == 1, "Stale Slack reply count cannot hide remaining bot replies")
        let selection = vault.selection(thread([chosen, fallback]))!
        check(selection.relative == "계정 관리.xlsx" && selection.editable, "row label and editable fallback")
        check(vault.selections(thread([chosen, message("새 검색", user: true)])).count == 1, "new search preserves selection")
        let changed = message("선택: 폴더/새 문서.md\n- 메모: 합성")
        check(vault.selections(thread([chosen, changed])).map(\.relative) == ["계정 관리.xlsx", "폴더/새 문서.md"], "each selection retains its own first-line label")
        check(vault.selection(thread([chosen]), now: now.addingTimeInterval(86399)) != nil, "24h not yet expired")
        check(vault.selection(thread([chosen]), now: now.addingTimeInterval(86400)) == nil, "24h boundary expires")
        check(vault.selection(thread([message(chosen.body, sender: "OTHER")])) == nil, "sender cannot spoof")
        check(vault.selection(thread([message(chosen.body, user: true)])) == nil, "human cannot spoof")
        check(vault.selection(thread([chosen]))?.editable == true, "xlsx row defaults to editable")
        check(vault.selection(thread([message("선택: 가짜.xlsm → 가짜 시트 → 행")]))?.editable == true, "xlsm row defaults editable")
        check(vault.selection(thread([message("선택: 가짜.xlsx")]))?.editable == false, "whole workbook is not a row")
        check(vault.selection(thread([chosen, message("경로 줘 · 열어줘 · 다운로드 · 종결 — 글로 보내도 됩니다")]))?.editable == false, "read-only fallback")
        check(vault.fallback(message(fallback.body, sender: "OTHER")) == nil, "untrusted fallback ignored")
        check(vault.selection(thread([chosen, message("경로 줘", user: true)]))?.sent == ["경로 줘"], "plain latest command claim")
        let targeted = message("다운로드: " + selection.label, user: true)
        check(vault.selections(thread([chosen, changed, targeted]))[0].sent == ["다운로드"], "targeted old selection command")
        let close = message("종결했어요 — " + selection.label)
        check(vault.selections(thread([chosen, changed, close])).map(\.message) == [changed.id], "only matching label closed")
        let again = message(chosen.body)
        check(vault.selections(thread([chosen, again, close, close])).map(\.message) == [chosen.id], "repeated closure cannot cascade to older identical selection")
        check(vault.selections(thread([chosen, message(close.body, sender: "OTHER")])).count == 1, "other sender cannot close")
        for text in ["새 검색", "2번", "새 값", "수정", "종결", "끝", "그만", "종료"] {
            check(vault.selection(thread([chosen, message(text, user: true)])) != nil, "user requests do not remove buttons before confirmation")
        }
        for text in ["어느 칸을 수정할까요?", "새 값을 보내 주세요", "어느 항목인가요?"] {
            check(vault.selection(thread([chosen, message(text)])) != nil, "questions retain independent buttons")
        }
        check(vault.selections(thread([chosen, fallback, changed, message("경로 줘 · 열어줘 · 다운로드 · 종결 — 글로 보내도 됩니다")])).map(\.editable) == [true, false], "fallback association is local")
        let suite = "ddots-vault-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShrimpVaultSettings(defaults: defaults, file: scratch.appendingPathComponent("settings/root.json"))
        check(settings.restore() == nil, "missing both stores stays unconfigured")
        try settings.save(root.path)
        check(defaults.string(forKey: ShrimpVault.rootKey) == root.path, "picker root stored in defaults")
        let backupRoot = try JSONDecoder().decode(String.self, from: Data(contentsOf: settings.file))
        check(backupRoot == root.path, "backup stores root only")
        defaults.removeObject(forKey: ShrimpVault.rootKey)
        check(settings.restore() == root.path && defaults.string(forKey: ShrimpVault.rootKey) == root.path, "backup restores defaults")
        try fm.removeItem(at: settings.file)
        check(settings.restore() == root.path && fm.fileExists(atPath: settings.file.path), "defaults restores backup")
        let otherRoot = root.appendingPathComponent("new")
        try settings.save(otherRoot.path)
        check(settings.restore() == otherRoot.path, "atomic replacement works")
        let permissions = try fm.attributesOfItem(atPath: settings.file.path)[.posixPermissions] as? Int
        check(permissions == 0o600, "private settings permissions")
        check(ShrimpVault(root: nil).unavailable == "보관함 폴더 미지정", "configuration reason")
        check(ShrimpVault(root: otherRoot.path).unavailable == "보관함 연결 안 됨", "missing mount reason")
        check(vault.unavailable == nil, "mounted folder available")
        check(vault.fallback(message("경로 줘 · 열어줘 · 다운로드 · 수정 — 글로 보내도 됩니다")) == nil, "old fallback deliberately unsupported")
        check(vault.fallback(message("경로 줘 · 열어줘 · 다운로드 — 글로 보내도 됩니다")) == nil, "old read-only fallback deliberately unsupported")
        var unloaded = thread([chosen]); unloaded.loaded = false
        check(vault.selection(unloaded) == nil, "unloaded history cannot grant actions")
        for path in ["../escape.txt", "/outside.txt", "folder/../../escape", "folder//file", "folder\\file", "folder/./file"] {
            check(vault.selection(thread([message("선택: " + path)])) == nil, "invalid relative path")
        }
        let relative = "서명 자료".decomposedStringWithCanonicalMapping + "/가짜 도장.png"
        let file = root.appendingPathComponent(relative)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("FAKE".utf8).write(to: file)
        check(vault.selection(thread([message("선택: " + relative)]))?.relative == relative, "NFD names retained")
        var opened: [URL] = [], shown: [URL] = []
        let perform: (String, Bool, Bool) -> String? = { path, reveal, absolute in
            vault.perform(path, reveal: reveal, absolute: absolute, open: { opened.append($0); return true }, show: { shown.append($0) })
        }
        check(perform(relative, false, false) == nil && opened.count == 1 && shown.isEmpty, "local open uses injected interface")
        let pathMessage = message("대상: 가짜 도장\n" + file.path)
        check(vault.pathLines(pathMessage) == [file.path], "whole path line")
        check(vault.pathLines(message("경로 " + file.path)).isEmpty, "inline path is not a link")
        check(vault.pathLines(message(pathMessage.body, sender: "OTHER")).isEmpty, "path sender restricted")
        let linked = vault.linkified(AttributedString(pathMessage.body), message: pathMessage)
        check(linked.runs.contains { $0.link == file }, "native selectable attributed link")
        let repeated = message("inline " + file.path + "\n" + file.path)
        let onlyLine = vault.linkified(AttributedString(repeated.body), message: repeated)
        check(onlyLine.runs.filter { $0.link != nil }.map { String(onlyLine.characters[$0.range]) } == [file.path], "only entire path line linked even if repeated inline")
        check(perform(file.path, true, true) == nil && shown.count == 1 && opened.count == 1, "path click reveals only")
        check(perform("../outside", false, false) != nil, "relative escape refused")
        check(perform(scratch.appendingPathComponent("outside.txt").path, false, true) != nil, "absolute outside refused")
        let outside = scratch.appendingPathComponent("outside.txt")
        try Data("FAKE".utf8).write(to: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        check(perform("link.txt", false, false) != nil, "symlink outside refused")
        check(perform(root.path + "/../outside.txt", true, true) != nil, "standardized escape refused")
        check(perform("missing.txt", false, false) != nil, "missing file notice")
        check(ShrimpVault(root: nil).perform("fake.txt", reveal: false) != nil, "unconfigured root")
        check(ShrimpVault(root: scratch.appendingPathComponent("unmounted").path).perform("fake.txt", reveal: false) != nil, "unmounted root")
        for ext in ["app", "command", "sh", "scpt", "workflow", "pkg", "dmg", "unknown"] {
            let path = root.appendingPathComponent("fake." + ext)
            try Data("FAKE".utf8).write(to: path)
            check(perform(path.lastPathComponent, false, false) == nil && shown.last == path, "executable/unknown only reveals")
        }
        let executable = root.appendingPathComponent("executable.txt")
        try Data("FAKE".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        check(perform("executable.txt", false, false) == nil && shown.last == executable, "executable bit only reveals")
        check(opened.count == 1, "no unsafe open occurred")
        // A share mounted again as <name>-1 while the old mount point was still there.
        let volumes = scratch.appendingPathComponent("Volumes")
        let remountedRoot = volumes.appendingPathComponent("fried_shrimp-1/vault_Private")
        try fm.createDirectory(at: remountedRoot.appendingPathComponent("ID:PW"), withIntermediateDirectories: true)
        try "FAKE".write(to: remountedRoot.appendingPathComponent("ID:PW/가짜 홈페이지.md"), atomically: true, encoding: .utf8)
        let configured = volumes.appendingPathComponent("fried_shrimp/vault_Private").path
        let share = (target: volumes.appendingPathComponent("fried_shrimp-1").path, source: "//fried_shrimp@100.64.0.1/fried_shrimp")
        check(ShrimpVault.remounted(configured, mounts: [share], volumes: volumes.path) == remountedRoot.path, "same share followed to <name>-1")
        check(ShrimpVault.remounted(configured, mounts: [(share.target, "//fried_shrimp@100.64.0.1/other")], volumes: volumes.path) == nil, "other share not followed")
        check(ShrimpVault.remounted(configured, mounts: [(volumes.appendingPathComponent("fried_shrimp-x").path, share.source)], volumes: volumes.path) == nil, "only numbered remounts")
        check(ShrimpVault.remounted(configured, mounts: [share, (volumes.appendingPathComponent("fried_shrimp-2").path, share.source)], volumes: volumes.path,
                                    exists: { _ in true }) == nil, "two remounts are ambiguous")
        check(ShrimpVault.remounted(configured, mounts: [share], volumes: scratch.appendingPathComponent("Elsewhere").path) == nil, "root outside volumes")
        check(ShrimpVault.remounted(configured + "-missing", mounts: [share], volumes: volumes.path) == nil, "missing folder on remount")
        check(!ChatText.mayOpen(file), "generic file URL policy unchanged")
        check(thread([chosen, fallback]).messages[1].body == fallback.body, "fallback copy source unchanged")
        var photo = message("")
        photo.files = [ChatFile(id: "FAKE-PHOTO", name: "표-120000.png", mimetype: "image/png")]
        let oldOrder = thread([chosen,photo,fallback])
        let visible = Set(oldOrder.messages.map(\.id))
        let oldLayout = vault.presentation(oldOrder, active: vault.selections(oldOrder), visible: visible, pending: nil)
        check(oldLayout.anchors[photo.id]?.message == chosen.id, "old-order buttons follow image")
        check(oldLayout.hidden.contains(fallback.id), "active fallback hidden")
        let newOrder = thread([photo,chosen,fallback])
        check(vault.presentation(newOrder, active: vault.selections(newOrder), visible: visible, pending: nil).anchors[chosen.id] != nil, "new-order buttons follow body")
        check(vault.presentation(oldOrder, active: [], visible: visible, pending: nil).hidden.isEmpty, "expired or closed selection fallback visible")
        check(vault.presentation(oldOrder, active: vault.selections(oldOrder), visible: [fallback.id], pending: nil).hidden.isEmpty, "folded-away controls preserve fallback")
        let foreign = message(fallback.body, sender: "OTHER")
        check(!vault.presentation(thread([chosen,foreign]), active: [selection], visible: [chosen.id,foreign.id], pending: nil).hidden.contains(foreign.id), "untrusted fallback stays visible")
        let approval = message("승인해 주세요.")
        let approvalFallback = message("승인 · 거부 — 글로 보내도 됩니다")
        let approvalThread = thread([approval,approvalFallback])
        check(vault.presentation(approvalThread, active: [], visible: [approval.id,approvalFallback.id], pending: approval.id).hidden.contains(approvalFallback.id), "rendered approval hides its fallback")
        check(vault.presentation(approvalThread, active: [], visible: [approval.id,approvalFallback.id], pending: nil).hidden.isEmpty, "no approval keeps fallback")
        check(oldOrder.messages.last?.body == fallback.body, "presentation does not change source copy or search")
        let excel = message("선택: 가짜.xlsx → 시험 시트 → 김가짜\n- pw: FAKE")
        let tableFallback = message("경로 줘 · 열어줘 · 다운로드 · 표 · 수정 · 종결 — 글로 보내도 됩니다")
        let tableReadOnly = message("경로 줘 · 열어줘 · 다운로드 · 표 · 종결 — 글로 보내도 됩니다")
        let excelThread = thread([excel,tableFallback])
        check(vault.selection(thread([excel]))?.table == true, "Excel row before fallback offers table")
        check(vault.selection(thread([message("선택: 가짜.xlsx")]))?.table == false, "Excel file alone has no table")
        check(vault.selection(thread([message("선택: 가짜.md")]))?.table == false, "text selection has no table")
        check(vault.selection(excelThread)?.actions == ["경로 줘", "파일오픈", "다운로드", "표", "수정", "종결"], "table precedes edit in six buttons")
        check(vault.selection(thread([excel,fallback]))?.table == false, "explicit old fallback suppresses table")
        check(vault.selection(thread([excel,tableReadOnly]))?.actions == ["경로 줘", "파일오픈", "다운로드", "표", "종결"], "read-only table fallback")
        check(vault.fallback(message(tableFallback.body, sender: "OTHER")) == nil, "foreign table fallback refused")
        let tableVisible = Set(excelThread.messages.map(\.id))
        check(vault.presentation(excelThread, active: vault.selections(excelThread), visible: tableVisible, pending: nil).hidden.contains(tableFallback.id), "new fallback hidden behind active controls")
        var request = message("표: 가짜.xlsx → 시험 시트 → 김가짜"); request.fromUser = true
        let requested = thread([excel,tableFallback,request,photo])
        let requestedLayout = vault.presentation(requested, active: vault.selections(requested), visible: Set(requested.messages.map(\.id)), pending: nil)
        check(requestedLayout.anchors[excel.id] != nil && requestedLayout.anchors[photo.id] == nil, "requested image never relocates controls")
        check(vault.selection(requested)?.sent.contains("표") == true, "targeted table claim restored in memory")
        // The wording both sides go by. The bot's project keeps the same file and checks that it writes and reads these lines.
        struct Wire: Decodable {
            struct Chosen: Decodable { let text: String; let label: String; let relative: String }
            struct Fallback: Decodable { let text: String; let table: Bool; let editable: Bool }
            struct Closed: Decodable { let text: String; let label: String }
            struct Saved: Decodable { let text: String; let source: String; let count: Int }
            struct Commands: Decodable { let targeted: [String]; let targetedSample: String; let page: String; let all: String; let choice: String }
            let selections: [Chosen]; let fallbacks: [Fallback]; let closed: Closed; let receipts: [Saved]; let commands: Commands
        }
        let wire = try JSONDecoder().decode(Wire.self, from: Data(contentsOf: fixtureURL.deletingLastPathComponent().appendingPathComponent("vault-wire.json")))
        for sample in wire.selections {
            let read = vault.selection(thread([message(sample.text)]))
            check(read?.label == sample.label && read?.relative == sample.relative, "Shared selection line is read: \(sample.label)")
        }
        let first = wire.selections[0]
        for sample in wire.fallbacks {
            let read = vault.selection(thread([message(first.text), message(sample.text)]))
            check(read?.table == sample.table && read?.editable == sample.editable, "Shared button line decides the buttons: \(sample.text)")
        }
        check(wire.closed.label == first.label && vault.selections(thread([message(first.text), message(wire.closed.text)])).isEmpty,
              "Shared closing line puts the selection's buttons away")
        for sample in wire.receipts {
            check(ShrimpReceipts.parse(sample.text) == ShrimpReceipts.Receipt(source: sample.source, count: sample.count), "Shared saved line is read")
        }
        let chosenFirst = vault.selection(thread([message(first.text)]))!
        check(wire.commands.targeted.sorted() == ["경로 줘", "다운로드", "표", "수정", "종결"].sorted()
              && ShrimpVault.command("다운로드", for: chosenFirst) == wire.commands.targetedSample, "A button sends the shared command for its selection")
        for action in wire.commands.targeted {
            let sent = thread([message(first.text), message(ShrimpVault.command(action, for: chosenFirst), user: true)])
            check(vault.selection(sent)?.sent == [action], "The sent command is known again as \(action)")
        }
        let asked = thread([message(first.text), message(wire.commands.page, user: true), message(wire.commands.all, user: true), message(wire.commands.choice, user: true)])
        check(vault.hiddenPageCommand(asked.messages[1], in: asked) && vault.hiddenPageCommand(asked.messages[2], in: asked) && !vault.hiddenPageCommand(asked.messages[3], in: asked),
              "Shared page commands are the ones kept out of the conversation")
        print("ShrimpVaultTests: \(checks) passed")
    }
}
