import Foundation

/// What the page beside the conversation can show, and where typed words lead.
enum WebAddress {
    static let textTypes: Set<String> = ["txt", "md", "csv", "json", "log"]
    static let fileTypes: Set<String> = textTypes.union(["pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg",
                                                         "html", "htm", "mp4", "mov", "m4v", "mp3", "m4a", "wav"])
    /// Pages on the web open beside the conversation; anything else (`slack:`, `mailto:` and so on) belongs to another app.
    static func isWeb(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil }
    /// A saved file the page can draw itself. Other kinds are left to the app that owns them.
    static func showsFile(_ url: URL) -> Bool { url.isFileURL && fileTypes.contains(url.pathExtension.lowercased()) }
    static func isText(_ url: URL) -> Bool { textTypes.contains(url.pathExtension.lowercased()) }

    /// What is typed in the address field: an address as it is, a bare host with `https://` put before it,
    /// and anything else as words to search for.
    static func destination(for typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let spaced = text.contains { $0.isWhitespace }
        if !spaced, let url = URL(string: text), isWeb(url) { return url }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if !spaced, !text.contains("://"), host.contains(".") || host.hasPrefix("localhost"),
           let url = URL(string: "https://" + text), isWeb(url) { return url }
        var search = URLComponents(string: "https://www.google.com/search")
        search?.queryItems = [URLQueryItem(name: "q", value: text)]
        return search?.url
    }

    /// A name for a downloaded file that is one path component and does not replace a file already there.
    static func downloadTarget(folder: URL, suggested: String, exists: (URL) -> Bool) -> URL {
        let cleaned = String(suggested.map { "/:\\\0\n\r".contains($0) ? "_" : $0 }).trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty || cleaned.hasPrefix(".") ? "내려받은 파일" + cleaned : cleaned
        let base = (name as NSString).deletingPathExtension, kind = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name), count = 2
        while exists(target) {
            target = folder.appendingPathComponent(kind.isEmpty ? "\(base) \(count)" : "\(base) \(count).\(kind)"); count += 1
        }
        return target
    }
}
