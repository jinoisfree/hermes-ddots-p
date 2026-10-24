import Foundation

/// Where files that pass through the Slack side are kept: one folder per room inside a folder in iCloud Drive,
/// so they are on every device. Nothing is written until a file is opened or sent.
struct SlackFileStore {
    static let folderName = "HermesWorkspace"
    static let largest = 200 * 1024 * 1024
    var root: URL

    /// The folder in this Mac's iCloud Drive, or the same name under Downloads when iCloud Drive is off.
    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isFolder: ObjCBool = false
        let base = FileManager.default.fileExists(atPath: cloud.path, isDirectory: &isFolder) && isFolder.boolValue ? cloud : home.appendingPathComponent("Downloads")
        return base.appendingPathComponent(folderName)
    }

    private static func cleaned(_ name: String) -> String {
        let cleaned = String(name.map { "/:\\\0\n\r".contains($0) ? "_" : $0 }).trimmingCharacters(in: .whitespaces)
        return cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
    }
    /// A name that is safe as one path component, whatever the room or file was called.
    static func safe(_ name: String) -> String {
        let trimmed = cleaned(name)
        return trimmed.isEmpty ? "이름 없음" : String(trimmed.prefix(120))
    }
    /// How long a file's name may get, in bytes, leaving room for the stamp in front of it.
    static let nameBytes = 200
    /// A file's name with Slack's own ID for the file in it, so two files of one name sent in the same minute stay two files.
    /// The extension is kept however long the name was. Without an ID the name is as `safe` makes it.
    static func named(_ name: String, id: String) -> String {
        let tag = id.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !tag.isEmpty else { return safe(name) }
        let whole = cleaned(name).isEmpty ? "이름 없음" : cleaned(name)
        var base = whole, ending = ""
        // A dot at the very start, or a long tail after the last one, is not an extension.
        if let dot = whole.lastIndex(of: "."), dot != whole.startIndex, whole[dot...].utf8.count <= 16 { base = String(whole[..<dot]); ending = String(whole[dot...]) }
        let tail = " (\(tag))" + ending
        while base.utf8.count + tail.utf8.count > nameBytes, !base.isEmpty { base.removeLast() }
        return base + tail
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HHmm"; return formatter
    }()

    /// The same message's file always lands on the same path, so opening it twice does not fetch it twice.
    /// `id` is Slack's ID for the file; a file saved before names carried it is still where `id: ""` says.
    func destination(room: String, name: String, date: Date, id: String = "") -> URL {
        root.appendingPathComponent(Self.safe(room)).appendingPathComponent(Self.stamp.string(from: date) + " " + Self.named(name, id: id))
    }

    func save(_ data: Data, room: String, name: String, date: Date, id: String = "") throws -> URL {
        let target = destination(room: room, name: name, date: date, id: id)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// Keeps a copy of a file that was sent. A file already inside the store is left where it is,
    /// and a different file that already has the name is not written over: the copy gets a number after its name.
    func keep(copyOf source: URL, room: String, date: Date) throws -> URL {
        if source.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") { return source }
        let data = try Data(contentsOf: source)
        let first = destination(room: room, name: source.lastPathComponent, date: date)
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ending = first.pathExtension.isEmpty ? "" : "." + first.pathExtension
        let base = first.deletingPathExtension().lastPathComponent
        for number in 1...99 {
            let target = number == 1 ? first : first.deletingLastPathComponent().appendingPathComponent("\(base) \(number)\(ending)")
            if FileManager.default.fileExists(atPath: target.path) {
                let size = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.intValue
                if size == data.count, (try? Data(contentsOf: target)) == data { return target }
                continue
            }
            try data.write(to: target, options: .atomic)
            return target
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func sizeText(_ bytes: Int) -> String {
        if bytes <= 0 { return "" }
        if bytes < 1024 { return "\(bytes)B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes) / 1024, unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return (value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))) + units[unit]
    }
}

/// A file about to be sent. Only its name and size are known until it is its turn; then its bytes are read,
/// sent and let go before the next file is read, so ten large files never sit in memory together.
struct SlackOutgoingFile {
    var name: String
    /// The size the file had when it was checked. Bytes read later that differ mean the file changed in between.
    var size: Int
    var load: () throws -> Data

    static func size(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { return nil }
        return values.fileSize
    }
    /// Checks every file by its size on disk before any is read. The first that is missing or too large stops the send.
    static func prepare(_ urls: [URL], largest: Int = SlackFileStore.largest, size: (URL) -> Int? = size(of:),
                        load: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) -> Result<[SlackOutgoingFile], SlackOutgoingProblem> {
        var result: [SlackOutgoingFile] = []
        for url in urls {
            guard let bytes = size(url) else { return .failure(.missing(url.lastPathComponent)) }
            if bytes > largest { return .failure(.tooLarge(url.lastPathComponent)) }
            result.append(SlackOutgoingFile(name: url.lastPathComponent, size: bytes, load: { try load(url) }))
        }
        return .success(result)
    }
}

enum SlackOutgoingProblem: Error, Equatable {
    case missing(String), tooLarge(String), unreadable(String), changed(String)
    var message: String {
        switch self {
        case .missing(let name): return "파일을 찾지 못했어요: \(name)"
        case .tooLarge(let name): return "200MB보다 큰 파일은 보낼 수 없어요: \(name)"
        case .unreadable(let name): return "파일을 읽지 못했어요: \(name)"
        case .changed(let name): return "보내는 사이 파일이 바뀌었어요. 다시 보내 주세요: \(name)"
        }
    }
}
