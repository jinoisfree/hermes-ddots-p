import AppKit

/// Clipboard images need a file until the existing upload queue has finished with them.
/// Originals copied in Finder are referenced directly; only our own temporary images are removed.
/// They are kept in a folder of ddots's own, one `run-<UUID>` folder per run. A run that ended before its folder was
/// removed leaves it there, and the next run removes it; nothing else in that folder or outside it is touched.
final class ClipboardAttachments {
    static let defaultArea = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-pasted-images", isDirectory: true)
    /// A slow disk for the checks: called on the working thread as a removal ("remove") or the next run's removal ("recover") begins.
    static var stall: ((String) -> Void)?
    let area: URL
    private var folder: URL?
    /// What earlier runs left, listed before this run makes a folder of its own, so the two never meet.
    private var leftovers: [URL]
    init(area: URL = ClipboardAttachments.defaultArea) {
        self.area = area
        leftovers = Self.runFolders(in: area)
    }
    deinit { cleanup() }
    func cleanup() { if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil }
    private var closed = false
    /// As the app closes: no new folder is made, and the one made so far is handed over to be removed elsewhere.
    func close() -> URL? {
        closed = true
        defer { folder = nil }
        return folder
    }
    /// Only folders named as this class names them, and real folders rather than links to somewhere else.
    static func runFolders(in area: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: area.path)) ?? []
        return names.filter { name in
            guard name.hasPrefix("run-"), UUID(uuidString: String(name.dropFirst(4))) != nil else { return false }
            let values = try? area.appendingPathComponent(name).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }.map { area.appendingPathComponent($0, isDirectory: true) }
    }
    static func remove(_ folder: URL) {
        stall?("remove")
        try? FileManager.default.removeItem(at: folder)
    }
    /// Removes what earlier runs left, away from the main thread; `done` is called on the main thread with how many went.
    func recoverLeftovers(done: ((Int) -> Void)? = nil) {
        let folders = leftovers; leftovers = []
        DispatchQueue.global(qos: .utility).async {
            Self.stall?("recover")
            var removed = 0
            for folder in folders where (try? FileManager.default.removeItem(at: folder)) != nil { removed += 1 }
            DispatchQueue.main.async { done?(removed) }
        }
    }

    struct Result {
        var files: [URL] = []
        var notice: String?
    }

    static func containsAttachments(_ board: NSPasteboard) -> Bool {
        board.availableType(from: [.fileURL, .png, .tiff]) != nil
    }

    /// nil leaves ordinary text paste to the text editor.
    func read(_ board: NSPasteboard, available: Int, temporary: SlackTemporaryFiles? = nil) -> Result? {
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard !urls.isEmpty || board.availableType(from: imageTypes) != nil else { return nil }
        guard available > 0 else { return Result(notice: "사진·파일은 한 번에 10개까지 첨부할 수 있어요.") }
        if !urls.isEmpty {
            var result = Result()
            for url in urls {
                guard result.files.count < available else { result.notice = "사진·파일은 한 번에 10개까지 첨부할 수 있어요."; break }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                      FileManager.default.isReadableFile(atPath: url.path) else {
                    result.notice = "읽을 수 있는 파일만 첨부할 수 있어요. 폴더는 압축한 뒤 첨부해 주세요."; continue
                }
                guard (values.fileSize ?? 0) <= SlackFileStore.largest else { result.notice = "200MB보다 큰 파일은 첨부할 수 없어요."; continue }
                if !result.files.contains(url) { result.files.append(url) }
            }
            return result
        }
        guard let type = board.availableType(from: imageTypes), let data = board.data(forType: type),
              data.count <= SlackFileStore.largest,
              let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= SlackFileStore.largest else { return Result(notice: "클립보드의 이미지를 읽지 못했거나 200MB를 넘었어요.") }
        do {
            if let temporary { return Result(files: [try temporary.save(png, name: "붙여넣은 이미지.png")]) }
            guard !closed else { throw CocoaError(.fileWriteNoPermission) }
            let root = folder ?? area.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            folder = root
            let file = root.appendingPathComponent("붙여넣은 이미지-" + UUID().uuidString + ".png")
            try png.write(to: file, options: .atomic)
            return Result(files: [file])
        } catch { return Result(notice: "붙여넣은 이미지를 저장하지 못했어요. " + error.localizedDescription) }
    }
}
