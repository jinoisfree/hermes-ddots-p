import Foundation
import AppKit

/// Configuration only is persistent. Selected paths, click claims and message contents are not.
struct ShrimpVault {
    static let rootKey = "shrimpVaultRoot"
    static let botKey = "shrimpBotUserID"
    static var defaultBot: String { DdotsConfig.shared.appearance["vaultBotUserID"] as? String ?? "" }
    var root: String?
    var bot: String
    init(root: String?, bot: String = Self.defaultBot) { self.root = root; self.bot = bot }
    static var configured: ShrimpVault {
        ShrimpVault(root: ShrimpVaultSettings.standard.restore(),
                    bot: defaultBot)
    }
    func trusted(_ message: ChatMessage) -> Bool {
        !bot.isEmpty && !message.fromUser && message.slackUserID == bot
    }
    struct Selection: Equatable {
        var message: String
        var label: String
        var relative: String
        var editable: Bool
        var sent: Set<String>
        var table = false
        var actions: [String] {
            ["경로 줘", "파일오픈", "다운로드"] + (table ? ["표"] : []) + (editable ? ["수정"] : []) + ["종결"]
        }
    }
    static let ending: Set<String> = ["종결", "끝", "그만", "종료"]
    static let followups: Set<String> = Set(["경로 줘", "맥미니 경로 줘", "다운로드", "열어줘", "보내줘", "내용 보여줘", "읽어줘", "요약해줘", "표", "표 보여줘", "표로 보여줘", "수정"]).union(ending)
    func fallback(_ message: ChatMessage) -> Bool? {
        guard trusted(message) else { return nil }
        switch message.body {
        case "경로 줘 · 열어줘 · 다운로드 · 표 · 수정 · 종결 — 글로 보내도 됩니다": return true
        case "경로 줘 · 열어줘 · 다운로드 · 표 · 종결 — 글로 보내도 됩니다": return false
        case "경로 줘 · 열어줘 · 다운로드 · 수정 · 종결 — 글로 보내도 됩니다": return true
        case "경로 줘 · 열어줘 · 다운로드 · 종결 — 글로 보내도 됩니다": return false
        default: return nil
        }
    }
    static let lifetime: TimeInterval = 24 * 60 * 60
    func selections(_ thread: SlackThread, now: Date = Date()) -> [Selection] {
        guard thread.loaded else { return [] }
        var results: [Selection] = []
        var closed = Set<String>()
        // Associate a fallback with the immediately preceding selection, even if it has expired.
        var fallbackOwner: String?
        for message in thread.messages {
            if trusted(message), message.body.hasPrefix("선택: ") {
                fallbackOwner = message.id
                let label = String(message.body.components(separatedBy: "\n")[0].dropFirst(4))
                let relative = label.components(separatedBy: " → ")[0]
                guard now.timeIntervalSince(message.date) < Self.lifetime, Self.validRelative(relative) else { continue }
                let ext = (relative as NSString).pathExtension.lowercased()
                let editable = ["txt", "md", "markdown", "csv", "tsv", "json", "log", "docx", "hwpx"].contains(ext)
                    || (["xlsx", "xlsm"].contains(ext) && label.contains(" → "))
                results.append(Selection(message: message.id, label: label, relative: relative, editable: editable, sent: [], table: ["xlsx", "xlsm"].contains(ext) && label.components(separatedBy: " → ").count == 3))
            } else if trusted(message), message.body.hasPrefix("종결했어요 — ") {
                let label = String(message.body.dropFirst("종결했어요 — ".count))
                if let index = results.lastIndex(where: { $0.label == label }) { closed.insert(results[index].message) }
            } else if let editable = fallback(message), let index = results.lastIndex(where: { $0.message == fallbackOwner }) {
                results[index].editable = editable
                results[index].table = message.body.contains(" · 표 · ")
                fallbackOwner = nil
            } else if message.fromUser {
                let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
                for action in ["경로 줘", "다운로드", "표", "수정", "종결"] {
                    let prefix = action + ": "
                    let index = text.hasPrefix(prefix)
                        ? results.lastIndex(where: { $0.label == String(text.dropFirst(prefix.count)) })
                        : (text == action ? results.indices.last : nil)
                    if let index { results[index].sent.insert(action) }
                }
            }
        }
        return results.filter { !closed.contains($0.message) }
    }
    struct Presentation {
        var anchors: [String: Selection] = [:]
        var hidden = Set<String>()
    }
    /// What a button sends into the thread: the action, then the selection it is for, word for word as the bot wrote it.
    static func command(_ action: String, for selection: Selection) -> String { action + ": " + selection.label }
    func hiddenPageCommand(_ message: ChatMessage, in thread: SlackThread) -> Bool {
        message.fromUser && (message.body == "전체 보기" || message.body.range(of: #"\A쪽: [0-9]+\z"#, options: .regularExpression) != nil)
            && thread.messages.contains(where: trusted)
    }
    func hidingPageCommands(_ thread: SlackThread) -> SlackThread {
        var displayed = thread
        let latest = thread.messages.last { trusted($0) && ShrimpAllHeader.parse($0.body) != nil }?.id
        displayed.replies.removeAll { hiddenPageCommand($0, in: thread) || (trusted($0) && ShrimpAllHeader.parse($0.body) != nil && $0.id != latest) }
        displayed.replyCount = max(displayed.replies.count, thread.replyCount - (thread.replies.count - displayed.replies.count))
        return displayed
    }
    /// Page buttons a newer search further down the thread has replaced; 새우튀김 answers only its newest list.
    func staleControls(_ message: ChatMessage, in thread: SlackThread) -> Bool {
        guard let index = thread.messages.firstIndex(where: { $0.id == message.id }) else { return false }
        return thread.messages[(index + 1)...].contains { later in
            trusted(later) && ShrimpAllHeader.parse(later.body) == nil && !ShrimpCandidates.scan(later.body).0.isEmpty
        }
    }
    /// Why `allList` is empty, as counts only.
    func allDiagnosis(_ thread: SlackThread) -> String {
        var shapes: [String] = []
        for message in thread.messages {
            if message.fromUser { shapes.append(message.body.range(of: #"\A(?:[0-9]+번|[0-9]+|쪽: [0-9]+|[0-9]+\s*(?:쪽|페이지)|다음(?: 목록)?|이전(?: 목록)?|더 보여줘|전체 보기)\z"#, options: .regularExpression) == nil ? "U" : "u"); continue }
            guard trusted(message) else { shapes.append("o"); continue }
            if let page = ShrimpPage.parse(message.body) { shapes.append("C\(page.total)"); continue }
            if let header = ShrimpAllHeader.parse(message.body) {
                let rows = ShrimpCandidates.scan(message.body).0
                shapes.append("A\(header.part)/\(header.parts)t\(header.total)r\(rows.count)")
                continue
            }
            if message.body.hasPrefix("전체 목록") { shapes.append("A?") ; continue }
            let rows = ShrimpCandidates.scan(message.body).0.count
            shapes.append(rows > 0 ? "L\(rows)" : "b")
        }
        return "messages=\(thread.messages.count) replies=\(thread.replyCount) loaded=\(thread.loaded) shapes=" + shapes.suffix(40).joined(separator: ",")
    }
    /// Complete, current generation only; all contents remain in the received messages.
    func allList(_ thread: SlackThread) -> [ShrimpCandidates.Candidate] {
        var rows: [Int: ShrimpCandidates.Candidate] = [:]
        var seen = Set<Int>(), parts = 0, total = 0
        var currentTotal: Int?
        func reset() { rows = [:]; seen = []; parts = 0; total = 0 }
        for message in thread.messages {
            if message.fromUser && message.body.range(of: #"\A(?:[0-9]+번|[0-9]+|쪽: [0-9]+|[0-9]+\s*(?:쪽|페이지)|다음(?: 목록)?|이전(?: 목록)?|더 보여줘|전체 보기)\z"#, options: .regularExpression) == nil { reset() }
            guard trusted(message) else { continue }
            if let page = ShrimpPage.parse(message.body) { currentTotal = page.total; continue }
            if let header = ShrimpAllHeader.parse(message.body) {
                if header.part == 1 { reset(); parts = header.parts; total = header.total }
                guard parts == header.parts, total == header.total, !seen.contains(header.part) else { reset(); continue }
                seen.insert(header.part)
                for row in ShrimpCandidates.scan(message.body).0 { rows[row.number] = row }
            } else if !ShrimpCandidates.scan(message.body).0.isEmpty {
                // A newly posted search/list body invalidates an older complete list, and the page
                // buttons above it: a search of ten or fewer comes without buttons of its own.
                reset(); currentTotal = nil
            }
        }
        guard parts > 0, total > 0, seen == Set(1...parts), (currentTotal ?? total) == total,
              rows.count == min(total, 300), Set(rows.keys) == Set(1...min(total, 300)) else { return [] }
        return rows.values.sorted { $0.number < $1.number }
    }
    func presentation(_ thread: SlackThread, active: [Selection], visible: Set<String>, pending: String?) -> Presentation {
        var result = Presentation()
        result.hidden.formUnion(thread.messages.filter { hiddenPageCommand($0, in: thread) }.map(\.id))
        let messages = thread.messages
        for choice in active {
            guard let index = messages.firstIndex(where: { $0.id == choice.message }) else { continue }
            var anchor = choice.message
            // Only an immediately following, trusted table upload belongs to an old-order selection.
            if index + 1 < messages.count {
                let image = messages[index + 1]
                if trusted(image), !image.files.isEmpty,
                   image.files.allSatisfy({ $0.isImage && ($0.name.hasPrefix("표-") || $0.name == "표.png") }),
                   visible.contains(image.id) { anchor = image.id }
            }
            if visible.contains(anchor) { result.anchors[anchor] = choice }
        }
        var owner: String?
        for message in messages {
            if trusted(message), message.body.hasPrefix("선택: ") { owner = message.id }
            if fallback(message) != nil, let owner,
               result.anchors.values.contains(where: { $0.message == owner }) { result.hidden.insert(message.id) }
            if trusted(message), message.body == "승인 · 거부 — 글로 보내도 됩니다",
               let pending, visible.contains(pending),
               let request = messages.first(where: { $0.id == pending }), trusted(request),
               let a = messages.firstIndex(where: { $0.id == pending }),
               let b = messages.firstIndex(where: { $0.id == message.id }), a < b { result.hidden.insert(message.id) }
        }
        return result
    }
    func selection(_ thread: SlackThread, now: Date = Date()) -> Selection? { selections(thread, now: now).last }
    var unavailable: String? {
        guard let root, root.hasPrefix("/"), root != "/" else { return "보관함 폴더 미지정" }
        return Self.isDirectory(mounted ?? root) ? nil : "보관함 연결 안 됨"
    }
    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    /// Where the configured folder is now. When a share comes back while its old folder is still in /Volumes,
    /// macOS mounts it again as `<name>-1`; 새우튀김 still writes the configured path, so the same share is followed there.
    var mounted: String? {
        guard let root, root.hasPrefix("/"), root != "/" else { return nil }
        if Self.isDirectory(root) { return root }
        return Self.remounted(root, mounts: Self.networkMounts())
    }
    /// The one directory that is `root` on the same share mounted again as `<volumes>/<name>-N`, or nil.
    static func remounted(_ root: String, mounts: [(target: String, source: String)], volumes: String = "/Volumes",
                          exists: (String) -> Bool = isDirectory) -> String? {
        let base = volumes.hasSuffix("/") ? volumes : volumes + "/"
        guard root.hasPrefix(base) else { return nil }
        let parts = String(root.dropFirst(base.count)).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first.map(String.init), !name.isEmpty else { return nil }
        let rest = parts.count > 1 ? "/" + parts[1] : ""
        let found = mounts.compactMap { mount -> String? in
            let number = mount.target.hasPrefix(base + name + "-") ? mount.target.dropFirst(base.count + name.count + 1) : ""
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let share = mount.source.split(separator: "/").last?.removingPercentEncoding,
                  share.caseInsensitiveCompare(name) == .orderedSame else { return nil }
            let candidate = mount.target + rest
            return exists(candidate) ? candidate : nil
        }
        return found.count == 1 ? found[0] : nil
    }
    /// Network file systems now mounted on this Mac: mount point and `//user@server/share`.
    static func networkMounts() -> [(target: String, source: String)] {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard let entries, count > 0 else { return [] }
        return (0..<Int(count)).compactMap { index in
            var item = entries[index]
            func text<T>(_ field: inout T, _ size: Int) -> String {
                withUnsafePointer(to: &field) { $0.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) } }
            }
            guard ["smbfs", "afpfs", "nfs", "webdav"].contains(text(&item.f_fstypename, Int(MFSTYPENAMELEN))) else { return nil }
            return (text(&item.f_mntonname, Int(MAXPATHLEN)), text(&item.f_mntfromname, Int(MAXPATHLEN)))
        }
    }
    static func validRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    func pathLines(_ message: ChatMessage) -> [String] {
        guard trusted(message), let root, root.hasPrefix("/"), !root.isEmpty else { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return message.body.components(separatedBy: .newlines).filter {
            $0.hasPrefix(prefix) && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }
    func linkified(_ input: AttributedString, message: ChatMessage) -> AttributedString {
        let paths = Set(pathLines(message))
        guard !paths.isEmpty else { return input }
        var result = AttributedString()
        for (index, line) in input.characters.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            var piece = AttributedString(input[line.startIndex..<line.endIndex])
            if paths.contains(String(line)) { piece.link = URL(fileURLWithPath: String(line)) }
            result.append(piece)
        }
        return result
    }
    enum Failure: Error { case configuration, missing, outside }
    func resolved(_ path: String, absolute: Bool = false) throws -> URL {
        guard let root, root.hasPrefix("/"), root != "/" else { throw Failure.configuration }
        let fm = FileManager.default
        let configured = URL(fileURLWithPath: root).standardizedFileURL.path + "/"
        if !absolute && !Self.validRelative(path) { throw Failure.outside }
        if absolute && !path.hasPrefix(configured) { throw Failure.outside }
        // A message names the configured folder; the file is looked up wherever that folder is mounted now.
        guard let current = mounted else { throw Failure.missing }
        let lexicalRoot = URL(fileURLWithPath: current).standardizedFileURL
        let relative = absolute ? String(path.dropFirst(configured.count)) : path
        let target = lexicalRoot.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let actualRoot = lexicalRoot.resolvingSymlinksInPath()
        let base = actualRoot.path.precomposedStringWithCanonicalMapping + "/"
        guard target.path.precomposedStringWithCanonicalMapping.hasPrefix(base) else { throw Failure.outside }
        guard fm.fileExists(atPath: target.path) else { throw Failure.missing }
        return target
    }
    static func revealOnly(_ url: URL) -> Bool {
        let risky: Set<String> = ["app","command","sh","scpt","scptd","workflow","pkg","dmg","py","js","zsh","bash","exe","jar","action","terminal","webloc","url"]
        if url.pathComponents.contains(where: { risky.contains(($0 as NSString).pathExtension.lowercased()) }) { return true }
        let documents: Set<String> = ["txt","md","markdown","csv","tsv","json","log","pdf","doc","docx","rtf","odt","xlsx","xlsm","xls","hwp","hwpx","png","jpg","jpeg","heic","tif","tiff","gif","bmp","webp"]
        return !documents.contains(url.pathExtension.lowercased()) || FileManager.default.isExecutableFile(atPath: url.path)
    }
    /// All side effects are injectable; tests never invoke Finder or open a real vault.
    func perform(_ path: String, reveal: Bool, absolute: Bool = false,
                 open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
                 show: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) -> String? {
        do {
            let url = try resolved(path, absolute: absolute)
            if reveal || Self.revealOnly(url) { show(url) }
            else if !open(url) { return "파일을 열지 못했어요. Finder에서 확인해 주세요." }
            return nil
        } catch Failure.configuration { return "보관함 경로를 먼저 설정해 주세요." }
        catch Failure.outside { return "보관함 밖의 경로는 열 수 없어요." }
        catch { return "보관함이 연결돼 있지 않거나 파일이 없어요." }
    }
}

/// Only the configured root is written. No selection, message, field or click is persisted.
struct ShrimpVaultSettings {
    var defaults: UserDefaults
    var file: URL
    static var standard: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Smoke tests must not touch the user's real settings backup.
        let base = CommandLine.arguments.contains("--ui-smoke")
            ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["HERMES_HOME"] ?? NSTemporaryDirectory())
            : home.appendingPathComponent("Library/Application Support/ddots")
        return Self(defaults: .standard, file: base.appendingPathComponent("shrimp-vault-root.json"))
    }
    private func valid(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), path != "/", !path.contains("\n") else { return nil }
        return path
    }
    func restore() -> String? {
        let primary = valid(defaults.string(forKey: ShrimpVault.rootKey))
        let backup = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(String.self, from: $0) }.flatMap(valid)
        guard let root = primary ?? backup else { return nil }
        if primary == nil { defaults.set(root, forKey: ShrimpVault.rootKey) }
        if backup != root { try? write(root) }
        return root
    }
    func save(_ root: String) throws {
        guard valid(root) != nil else { throw ShrimpVault.Failure.configuration }
        try write(root)
        defaults.set(root, forKey: ShrimpVault.rootKey)
    }
    private func write(_ root: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic replacement inherits a private permission mask before any bytes are written.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".vault-setting-" + UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(root))
        try handle.synchronize()
        if fm.fileExists(atPath: file.path) { _ = try fm.replaceItemAt(file, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: file) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
