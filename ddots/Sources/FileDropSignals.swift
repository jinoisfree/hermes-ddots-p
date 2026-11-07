import AppKit
import PDFKit
import CoreServices
import Darwin

struct FileDropSignals: Codable {
    var today = FileDropSignals.localToday()
    var account = ""
    var names: [String] = []
    var kinds: [String] = []
    var source = ""
    var folder = ""
    var hosts: [String] = []
    var content = ""
    /// Something was left unread: a file in `unread`, or text cut at the limit (`truncated`). The Mac mini reader may
    /// still read the unread files; it reports the final answer in `FileDropAnswer.partial`.
    var partial = false
    /// Names of the dropped files this app could not read completely.
    var unread: [String] = []
    var truncated = false
    var sensitive = false
    /// Assigned at runtime from the organization's roles (FileDropCast); never a fixed ID.
    var profile = ""
    var agentRoles: [String: [String]] = [:]
    var works: [String] = []
    var recent: [[String: String]] = []
    var memories: [String] = []
    var habits: [String: Int] = [:]
    var custom: [String] = []
    var feature: String { [kinds.sorted().joined(separator: ","), source, folder, hosts.sorted().joined(separator: ",")].joined(separator: "|") }
    static func localToday(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        let weekday = ["일", "월", "화", "수", "목", "금", "토"][parts.weekday! - 1]
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!) + "(" + weekday + ")"
    }
    /// The hint words resolve to a role; the card turns the role into whichever profile holds it.
    static func role(_ hint: String) -> String {
        let hint = hint.lowercased()
        return ["영수증", "개인", "receipt"].contains(where: hint.contains) ? "personal" : "work"
    }
    var hint: String { (names.joined(separator: " ") + " " + source + " " + content).lowercased() }
    /// Plain text of the formats the app reads itself: UTF-8 first, then EUC-KR. Returns nil when neither decodes.
    static func plainText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        return String(data: data, encoding: korean)
    }
    /// Body text of an HTML page: tags, scripts, styles and comments are dropped; table cells stay separated.
    static func htmlText(_ html: String) -> String {
        func replace(_ text: String, _ pattern: String, _ with: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with)
        }
        var text = replace(html, #"<!--.*?-->"#, " ", [.dotMatchesLineSeparators])
        for tag in ["script", "style", "noscript", "head"] { text = replace(text, "<\(tag)\\b.*?</\(tag)\\s*>", " ", [.caseInsensitive, .dotMatchesLineSeparators]) }
        text = replace(text, #"</t[dh]\s*>"#, " | ")
        text = replace(text, #"</(tr|p|div|li|h[1-6]|table|section|article)\s*>|<br\s*/?>"#, "\n")
        text = replace(text, #"<[^>]*>"#, "", [.dotMatchesLineSeparators])
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: value) }
        text = replace(text, #"[ \t\u00A0]+"#, " ")
        text = replace(text, #"( \| )+\n"#, "\n")
        text = replace(text, #"\n[ ]*"#, "\n")
        text = replace(text, #"\n{2,}"#, "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func originHosts(_ file: URL) -> [String] {
        let item = MDItemCreate(kCFAllocatorDefault, file.path as CFString)
        var origins = item.flatMap { MDItemCopyAttribute($0, kMDItemWhereFroms) as? [String] }
        if origins == nil {
            // Temporary/unindexed files still carry the same metadata as an xattr.
            let key = "com.apple.metadata:kMDItemWhereFroms"
            let size = getxattr(file.path, key, nil, 0, 0, 0)
            if size > 0 && size <= 64 * 1024 {
                var bytes = Data(count: size)
                let count = bytes.withUnsafeMutableBytes { getxattr(file.path, key, $0.baseAddress, size, 0, 0) }
                if count == size { origins = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String] }
            }
        }
        return (origins ?? []).compactMap { URL(string: $0)?.host }
    }

    static func initial(_ payload: FileDropIntake.Payload) -> Self {
        var value = Self()
        value.names = payload.files.map(\.lastPathComponent)
        if !payload.text.isEmpty { value.names.append(String(payload.text.split(separator: "\n").first.map(String.init)?.prefix(30) ?? "글".prefix(30))) }
        value.kinds = payload.files.map { $0.pathExtension.lowercased() }
        if !payload.text.isEmpty { value.kinds.append(payload.text.hasPrefix("https://") ? "link" : "text") }
        value.source = payload.source
        if let first = payload.files.first {
            let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
            if first.deletingLastPathComponent().path.hasPrefix(home) {
                value.folder = "~/" + first.deletingLastPathComponent().path.dropFirst(home.count).split(separator: "/").prefix(2).joined(separator: "/")
            }
        }
        value.content = payload.text; value.sensitive = secret(value.names.joined(separator: " ") + "\n" + payload.text)
        return value
    }
    /// Runs off the UI thread. A deadline never authorizes sending an unchecked original.
    static func read(_ payload: FileDropIntake.Payload, initial: Self, budget: TimeInterval = 1) -> Self {
        var value = initial, chunks = [payload.text]
        let deadline = Date().addingTimeInterval(budget)
        for (position, file) in payload.files.enumerated() {
            if Date() > deadline { value.unread += payload.files[position...].map(\.lastPathComponent); break }
            value.hosts += originHosts(file)
            do {
                let text: String
                var complete = true
                switch file.pathExtension.lowercased() {
                case "pdf":
                    guard let pdf = PDFDocument(url: file) else { throw CocoaError(.fileReadCorruptFile) }
                    var pages: [String] = []
                    for index in 0..<pdf.pageCount {
                        guard Date() < deadline, let page = pdf.page(at: index) else { complete = false; break }
                        if let string = page.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pages.append(string) }
                        else if let image = page.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox).tiffRepresentation {
                            pages.append(try ClipboardOCR.recognize(data: image) ?? "")
                        }
                    }
                    text = pages.joined(separator: "\n")
                case "png", "jpg", "jpeg", "tiff", "heic": text = try ClipboardOCR.recognize(file: file) ?? ""
                case "txt", "md", "csv", "log", "json", "html", "htm", "eml":
                    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                    let limit = 8 * 1024 * 1024
                    let data = try handle.read(upToCount: limit + 1) ?? Data()
                    if data.count > limit { complete = false }
                    if file.pathExtension.lowercased() == "eml" {
                        guard let mail = FileDropMail.read(Data(data.prefix(limit))) else { throw CocoaError(.fileReadCorruptFile) }
                        text = mail.text; complete = complete && mail.complete
                    } else {
                        guard let plain = plainText(data.prefix(limit)) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                        text = ["html", "htm"].contains(file.pathExtension.lowercased()) ? htmlText(plain) : plain
                    }
                case "rtf", "docx":
                    let type: NSAttributedString.DocumentType = file.pathExtension.lowercased() == "docx" ? .officeOpenXML : .rtf
                    text = try NSAttributedString(url: file, options: [.documentType: type], documentAttributes: nil).string
                default: complete = false; text = ""
                }
                if !complete { value.unread.append(file.lastPathComponent) }
                value.sensitive = value.sensitive || secret(text)
                chunks.append(text)
            } catch { value.unread.append(file.lastPathComponent) }
        }
        value.hosts = Array(Set(value.hosts)).sorted()
        let text = chunks.joined(separator: "\n")
        value.sensitive = value.sensitive || secret(text)
        value.truncated = text.count > contentLimit
        value.content = String(text.prefix(contentLimit))
        value.partial = !value.unread.isEmpty || value.truncated
        return value
    }
    static let contentLimit = 30_000
    static func secret(_ text: String) -> Bool {
        let token = #"xox[abprs]-|sk-[A-Za-z0-9_-]+|AKIA[A-Z0-9]+|ghp_[A-Za-z0-9]+|-----BEGIN|(?:비밀번호|password|passwd)\s*[:=]\s*\S+"#
        if text.range(of: token, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        func matches(_ pattern: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range, in: text).map { String(text[$0]) }
            }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for match in matches(#"\b[0-9]{6}[- ]?[1-8][0-9]{6}\b"#) {
            let digits = match.compactMap(\.wholeNumberValue)
            let year = ([1, 2, 5, 6].contains(digits[6]) ? 1900 : 2000) + digits[0] * 10 + digits[1]
            let month = digits[2] * 10 + digits[3], day = digits[4] * 10 + digits[5]
            let parts = DateComponents(year: year, month: month, day: day)
            if let date = calendar.date(from: parts) {
                let actual = calendar.dateComponents([.year, .month, .day], from: date)
                if actual.year == year && actual.month == month && actual.day == day { return true }
            }
        }
        // Match whole runs so a longer order ID cannot be tested as a card prefix.
        for match in matches(#"[0-9](?:[ -]?[0-9])+"#) {
            let digits = match.compactMap(\.wholeNumberValue)
            guard (15...19).contains(digits.count) else { continue }
            let total = digits.reversed().enumerated().reduce(0) { sum, entry in
                let value = entry.offset.isMultiple(of: 2) ? entry.element : entry.element * 2
                return sum + (value > 9 ? value - 9 : value)
            }
            if total.isMultiple(of: 10) { return true }
        }
        return false
    }
    static func condensed(_ text: String) -> String {
        // Keep salient lines from ALL pages before filling the remaining prefix budget.
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.address.rawValue)
        let lines = text.components(separatedBy: .newlines)
        let salient = lines.filter { line in
            line.contains("|") || line.hasPrefix("#") || line.range(of: #"\d+[,.]?\d*\s*(원|달러|만원|%)|\d{1,2}월\s*\d{1,2}일|마감"#, options: .regularExpression) != nil ||
            (detector?.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) ?? 0) > 0
        }.joined(separator: "\n")
        let important = String(salient.prefix(1500))
        return String((important + "\n" + text.prefix(max(0, 2499 - important.count))).prefix(2500))
    }
}
