import AppKit

protocol FileDropPromise {
    var fileNames: [String] { get }
    func receive(at destination: URL, queue: OperationQueue, completion: @escaping (URL, Error?) -> Void)
}
extension NSFilePromiseReceiver: FileDropPromise {
    func receive(at destination: URL, queue: OperationQueue, completion: @escaping (URL, Error?) -> Void) {
        receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue, reader: completion)
    }
}

/// One card owns one temporary area. Closing also invalidates outstanding file promises.
final class FileDropIntake {
    static let area = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-file-drop-" + AppIdentity.bundleID)
    static var types: [NSPasteboard.PasteboardType] {
        ClipboardPasteboard.supported + [.URL, .rtf] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }
    struct Payload {
        var files: [URL] = []
        var text = ""
        var source = ""
        var notice = ""
        var count: Int { files.count + (text.isEmpty ? 0 : 1) }
        var bytes: Int { files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }

    }
    private let area: URL
    private var folder: URL?
    private var generation = UUID()
    private let queue = OperationQueue()
    var promises: (NSPasteboard) -> [FileDropPromise] = { ($0.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? [] }
    init(area: URL = FileDropIntake.area) { self.area = area; queue.maxConcurrentOperationCount = 1 }
    deinit { close() }
    static func concealed(_ board: NSPasteboard) -> Bool {
        let types = Set(board.types ?? [])
        return types.contains(ClipboardPasteboard.concealed) || !types.isDisjoint(with: ClipboardPasteboard.legacySecrets)
    }
    static func urls(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    static func count(_ board: NSPasteboard) -> Int {
        guard !concealed(board) else { return 0 }
        let files = urls(board)
        if !files.isEmpty { return ClipboardAttachments.validate(files, available: 10).files.count }
        if let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            return min(10, receivers.reduce(0) { $0 + max(1, $1.fileNames.count) })
        }
        return board.availableType(from: types) == nil ? 0 : 1
    }
    func recover() {
        let leftovers = ClipboardAttachments.runFolders(in: area)
        DispatchQueue.global(qos: .utility).async {
            for folder in leftovers { ClipboardAttachments.remove(folder) }
        }
    }
    func close() {
        generation = UUID(); queue.cancelAllOperations()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
    private func directory() throws -> URL {
        if let folder { return folder }
        let folder = area.appendingPathComponent("run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.folder = folder; return folder
    }
    func read(_ board: NSPasteboard, completion: @escaping (Payload) -> Void) {
        precondition(Thread.isMainThread)
        guard !Self.concealed(board) else { completion(Payload(notice: "비밀번호 복사는 맡길 수 없어요")); return }
        var payload = Payload(source: board.string(forType: ClipboardPasteboard.source) ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        let files = Self.urls(board)
        if !files.isEmpty {
            let result = ClipboardAttachments.validate(files, available: 10)
            payload.files = result.files; payload.notice = result.notice ?? ""; completion(payload); return
        }
        let receivers = promises(board)
        if !receivers.isEmpty {
            do {
                let root = try directory(), request = generation
                let group = DispatchGroup()
                // File-promise callbacks can arrive on background threads. Collect on main only.
                for receiver in receivers {
                    for _ in 0..<max(1, receiver.fileNames.count) { group.enter() }
                    receiver.receive(at: root, queue: queue) { [weak self] url, error in
                        DispatchQueue.main.async {
                            defer { group.leave() }
                            guard let self, self.generation == request else {
                                try? FileManager.default.removeItem(at: root); return
                            }
                            if error == nil { payload.files.append(url) } else { payload.notice = "받지 못한 파일이 있어요" }
                        }
                    }
                }
                group.notify(queue: .main) { [weak self] in
                    guard let self, self.generation == request else { try? FileManager.default.removeItem(at: root); return }
                    let result = ClipboardAttachments.validate(payload.files, available: 10)
                    payload.files = result.files
                    if let notice = result.notice { payload.notice = notice }
                    completion(payload)
                }
            } catch { payload.notice = "파일을 받을 임시 공간을 만들지 못했어요"; completion(payload) }
            return
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, ClipboardPasteboard.video, .init("com.apple.quicktime-movie")] {
            guard let data = board.data(forType: type) else { continue }
            guard data.count <= SlackFileStore.largest else { payload.notice = "200MB보다 큰 파일은 뺐어요"; completion(payload); return }
            do {
                let suffix = type == .png ? "png" : type == .tiff ? "tiff" : "mov"
                let file = try directory().appendingPathComponent(UUID().uuidString + "." + suffix)
                try data.write(to: file, options: .atomic); payload.files = [file]
            } catch { payload.notice = "파일을 받지 못했어요" }
            completion(payload); return
        }
        let rich = board.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        let text = board.string(forType: .string) ?? board.string(forType: .URL) ?? rich ?? ""
        payload.text = String(text.prefix(100_000))
        if text.count > 100_000 { payload.notice = "글은 100,000자까지 맡길 수 있어요" }
        completion(payload)
    }
}
