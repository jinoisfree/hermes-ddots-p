import Foundation

/// A QuickConnect link that names a file in the Synology Drive folder synced to this Mac, so it opens here without signing in.
enum SynologyLink {
    enum Target: Equatable { case open(URL), reveal(URL), folder(URL) }

    /// Kinds that run something when opened. They are only shown in Finder, as is a file with no kind at all.
    /// The sync folder marks ordinary documents executable, so the kind decides, not the permission bits.
    static let programs: Set<String> = ["app", "command", "sh", "zsh", "bash", "csh", "ksh", "fish", "tool", "scpt", "scptd", "applescript", "workflow", "action",
                                        "pkg", "mpkg", "dmg", "py", "rb", "pl", "php", "js", "jar", "exe", "bat", "cmd", "terminal", "webloc", "url", "inetloc",
                                        "fileloc", "shortcut", "prefpane", "osax", "kext", "plugin", "bundle", "framework", "mobileconfig", "jnlp"]

    /// A file a message links to: the address as written, and its path inside the folder.
    struct Item: Equatable {
        let url: URL
        let path: String
        var name: String { (path as NSString).lastPathComponent }
        var folder: String { (path as NSString).deletingLastPathComponent }
    }
    /// The buttons under a linking message, each drawn with the picture 새우튀김's button of the same use has.
    static let actions = [(name: "경로", icon: "경로 줘"), (name: "열기", icon: "파일오픈"), (name: "다운", icon: "다운로드"), (name: "수정", icon: "수정"), (name: "확인", icon: "종결")]
    /// What is sent into the thread for the buttons that ask the sender for something.
    static let commands = ["다운": "다운로드", "수정": "수정"]

    private static let written = try? NSRegularExpression(pattern: #"https?://[A-Za-z0-9.-]+\.quickconnect\.to[^\s<>"|)\]]*#drive=[^\s<>"|)\]]+"#, options: .caseInsensitive)
    /// The files a message links to, in the order written, each once.
    static func links(in body: String) -> [Item] {
        var items: [Item] = []
        for match in written?.matches(in: body, range: NSRange(body.startIndex..., in: body)) ?? [] {
            guard var range = Range(match.range, in: body) else { continue }
            // Punctuation that closes the sentence is not part of the address.
            while let last = body[range].last, ".,;:!?}'…*".contains(last) { range = range.lowerBound..<body.index(before: range.upperBound) }
            guard let url = URL(string: String(body[range])), let parts = components(of: url) else { continue }
            let path = parts.joined(separator: "/")
            if !items.contains(where: { $0.path == path }) { items.append(Item(url: url, path: path)) }
        }
        return items
    }

    /// An address written out in full is shown as the name of its file; the name is what is pressed.
    /// A link the writer already gave words to keeps them.
    static func titled(_ text: AttributedString) -> AttributedString {
        var result = text
        for run in text.runs.reversed() {
            guard let url = run.link, let name = components(of: url)?.last,
                  String(text[run.range].characters).lowercased().hasPrefix("http") else { continue }
            var title = AttributedString(name)
            title.setAttributes(run.attributes)
            result.replaceSubrange(run.range, with: title)
        }
        return result
    }

    static var roots: [URL] {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? []
        return names.filter { $0.hasPrefix("SynologyDrive-") }.sorted().map { cloud.appendingPathComponent($0) }
    }

    /// The path after `#drive=` of a `*.quickconnect.to` address, as components that stay inside the folder.
    static func components(of url: URL) -> [String]? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), host.hasSuffix(".quickconnect.to"),
              let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment, fragment.hasPrefix("drive="),
              let path = String(fragment.dropFirst("drive=".count)).removingPercentEncoding,
              !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return nil }
        var parts = path.components(separatedBy: "/")
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts
    }

    /// What to do with the link on this Mac, or nil when it is not such a link, the file is not here, or the path is refused.
    static func target(for url: URL, roots: [URL] = SynologyLink.roots) -> Target? {
        guard let parts = components(of: url) else { return nil }
        for root in roots {
            guard kind(of: root) == .typeDirectory else { continue }
            var file = root, last: FileAttributeType?
            for part in parts {
                file.appendPathComponent(part)
                last = kind(of: file)
                // A symbolic link anywhere on the way could lead out of the folder.
                guard last == .typeDirectory || last == .typeRegular else { last = nil; break }
            }
            guard let last else { continue }
            let risky = parts.contains { programs.contains(($0 as NSString).pathExtension.lowercased()) }
            if last == .typeDirectory { return risky ? .reveal(file) : .folder(file) }
            return risky || file.pathExtension.isEmpty ? .reveal(file) : .open(file)
        }
        return nil
    }

    /// The kind of the item itself; a symbolic link is not followed.
    private static func kind(of url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }
}
