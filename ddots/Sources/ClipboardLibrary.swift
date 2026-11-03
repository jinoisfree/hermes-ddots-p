import AppKit
import Combine
import ImageIO

/// The serial queue owns all stored state. Only immutable presentation snapshots cross to the main thread.
final class ClipboardLibrary: ObservableObject {
    let semantic: ClipboardSemanticSearch
    let preview = ClipboardPreview()
    var hoveredID: UUID?
    @Published var selectedIDs: Set<UUID> = []
    @Published var hotKeyError = false
    @Published var commandHeld = false
    @Published var shelfWidth: CGFloat = ClipboardDrawer.load().width
    @Published var visibleShelfCount = 0 { didSet { if oldValue != visibleShelfCount { onChange?() } } }
    @Published var opacityPercent = ClipboardDrawer.opacity() { didSet { onChange?() } }
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var ready = false
    @Published private(set) var tabs = ClipboardTabs()
    // Engine outcomes contain no clipboard text. The actual-environment smoke uses them to distinguish failures.
    @Published private(set) var recognitionStatus: [UUID: String] = [:]
    private var noticeTimer: Timer?
    @Published var notice: String? {
        didSet {
            noticeTimer?.invalidate(); noticeTimer = nil
            if notice != nil { noticeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.notice = nil } }
        }
    }
    @Published var permissionNeeded = false
    @Published private(set) var canUndo = false
    @Published private(set) var restoredID: UUID?
    @Published private(set) var revealedID: UUID?
    func toggleReveal(_ id: UUID) { if revealedID == id { preview.close(); revealedID = nil } else { revealedID = id } }
    func concealSecrets() { revealedID = nil; preview.close() }
    @Published private(set) var permissionRequestAvailable = false
    var clock: () -> Date = Date.init
    private var undo = ClipboardUndo()
    private let byteLimit: Int
    private var undoTimer: Timer?
    var available: Bool { settings.enabled && (!entries.isEmpty || canUndo || (!paused && permissionNeeded)) }
    @Published var settings: ClipboardSettings
    let monitor: ClipboardMonitor
    let store: ClipboardStore
    private let queue = DispatchQueue(label: "ddots.clipboard.storage", qos: .userInitiated)
    private let ocrQueue = DispatchQueue(label: "ddots.clipboard.ocr", qos: .utility)
    private var history = ClipboardHistory()
    private var failed = false
    private var archive = ClipboardArchive()
    private var ocrEnabled = true
    private var sleepObservers: [NSObjectProtocol] = []
    private var sleeping = false
    private var maintenance: Timer?
    var paused = false { didSet { if paused { concealSecrets() }; updateMonitoring(); onChange?() } }
    var onResetSize: (() -> Void)?
    var onChange: (() -> Void)?
    var onCopied: (() -> Void)?
    var onCaptured: ((ClipboardEntry) -> Void)?
    init(root: URL, temporary: URL, keychain: ClipboardKeychain, board: NSPasteboard = .general,
         settings: ClipboardSettings = ClipboardSettings.load(), allowed: (() -> Bool)? = nil,
         byteLimit: Int = ClipboardLimits().totalBytes, semantic: ClipboardSemanticSearch = ClipboardSemanticSearch()) {
        self.semantic = semantic
        self.settings = settings; self.byteLimit = byteLimit
        store = ClipboardStore(root: root, temporary: temporary, keychain: keychain)
        monitor = ClipboardMonitor(board: board, allowed: allowed)
        monitor.onInput = { [weak self] in self?.add($0, fromMonitor: true) }
        monitor.onPermission = { [weak self] needed in
            guard let self else { return }
            let request = needed && self.monitor.canRequestPermission()
            if self.permissionNeeded != needed || self.permissionRequestAvailable != request {
                self.permissionNeeded = needed; self.permissionRequestAvailable = request; self.onChange?()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(true) })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(false) })
        }
        let distributed = DistributedNotificationCenter.default()
        sleepObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setSleeping(true) })
        sleepObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setSleeping(false) })
        queue.async { [self] in
            do {
                archive = try store.load()
                history = ClipboardHistory(entries: archive.entries)
                applyLimits(settings)
                try commit(removed: history.prune())
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    ready = true; updateMonitoring(); onChange?()
                    maintenance = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.expire() }
                }
            } catch { fail() }
        }
    }
    deinit {
        maintenance?.invalidate(); undoTimer?.invalidate(); noticeTimer?.invalidate()
        for token in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(token); DistributedNotificationCenter.default().removeObserver(token) }
    }
    private func setSleeping(_ value: Bool) { sleeping = value; if value { concealSecrets(); purgeUndo() }; updateMonitoring() }
    private func expire() {
        queue.async { [self] in
            guard !failed else { return }
            let removed = history.prune()
            if !removed.isEmpty { do { try commit(removed: removed) } catch { fail() } }
        }
    }
    private func updateMonitoring() {
        monitor.excludedApps = Set(settings.excludedApps); monitor.storesMedia = settings.media
        if ready && settings.enabled && !paused && !sleeping { monitor.start() } else { monitor.stop() }
    }
    func searchMeaning(_ query: String, entries: [ClipboardEntry]) {
        semantic.search(query, entries: entries, enabled: settings.enabled && settings.semanticSearch)
    }
    func requestPermission() { monitor.requestPermission(); notice = "시스템 설정 → 개인정보 보호 및 보안 → 다른 앱에서 붙여넣기 → ddots 항상 허용" }
    func changeSettings(_ value: ClipboardSettings, persist: Bool = true) {
        if !value.enabled { semantic.cancel(); concealSecrets(); purgeUndo() }
        settings = value
        if persist, let bytes = try? JSONEncoder().encode(value) { UserDefaults.standard.set(bytes, forKey: ClipboardSettings.key) }
        updateMonitoring(); onChange?()
        queue.async { [self] in
            guard !failed else { return }
            applyLimits(value)
            do { try commit(removed: history.prune()) } catch { fail() }
        }
    }
    private func applyLimits(_ value: ClipboardSettings) {
        history.limits.days = value.days; history.limits.count = value.count; ocrEnabled = value.ocr
        refreshCapacity()
    }
    private func refreshCapacity() { history.limits.totalBytes = max(0, byteLimit - undo.reservedBytes) }
    private func fail() {
        failed = true
        DispatchQueue.main.async { [weak self] in
            self?.ready = false; self?.monitor.stop(); self?.notice = "클립보드 보관함을 저장하지 못했어요. 앱을 다시 열어 주세요."
        }
    }
    private func commit(removed: [ClipboardEntry] = [], publish: Bool = true) throws {
        archive.entries = history.entries
        try store.save(archive)
        for entry in removed { if let id = entry.dataID { try store.removeData(id) } }
        if publish { publishSnapshot() }
    }
    private func publishSnapshot() {
        let snapshot = history.entries, tabSnapshot = archive.tabs, hasUndo = !undo.items.isEmpty
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries = snapshot; self.tabs = tabSnapshot; self.canUndo = hasUndo; self.onChange?()
        }
    }
    func add(_ input: ClipboardInput, fromMonitor: Bool = false, deduplicating: Bool = true) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                refreshCapacity()
                guard input.byteCount <= history.limits.totalBytes else {
                    DispatchQueue.main.async { [weak self] in self?.notice = "보관할 수 있는 용량을 넘었어요" }; return
                }
                let previous = Set(history.entries.map(\.id))
                let (entry, removed) = try history.insert(input, deduplicating: deduplicating)
                guard history.entries.contains(where: { $0.id == entry.id }) else {
                    try commit(removed: removed)
                    DispatchQueue.main.async { [weak self] in self?.notice = "보관할 수 있는 용량을 넘었어요" }
                    return
                }
                if !previous.contains(entry.id), let id = entry.dataID, let data = input.data { try store.saveData(data, id: id) }
                try commit(removed: removed)
                if fromMonitor {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.settings.enabled, !self.paused, !self.sleeping,
                              self.monitor.running, self.monitor.allowed() else { return }
                        self.onCaptured?(entry)
                    }
                }
                if !previous.contains(entry.id) { recognize(entry, input: input) }
            } catch ClipboardHistoryError.tooLarge {
                DispatchQueue.main.async { [weak self] in self?.notice = "너무 커서 보관하지 못했어요" }
            } catch { fail() }
        }
    }
    private func recognize(_ entry: ClipboardEntry, input: ClipboardInput) {
        guard ocrEnabled, !entry.secret, entry.kind == .image || (entry.kind == .files && entry.files.contains(where: { ClipboardEntry.imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) })) else { return }
        DispatchQueue.main.async { [weak self] in self?.recognitionStatus[entry.id] = "pending" }
        ocrQueue.async { [weak self] in
            let text: String?
            do {
                if entry.kind == .image, let data = input.data { text = try ClipboardOCR.recognize(data: data) }
                else if entry.kind == .files {
                    text = try entry.files.filter { ClipboardEntry.imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                        .compactMap { try ClipboardOCR.recognize(file: URL(fileURLWithPath: $0)) }.joined(separator: "\n")
                } else { return }
            } catch {
                let code = (error as NSError).code
                DispatchQueue.main.async { [weak self] in self?.recognitionStatus[entry.id] = "failed-\(code)" }
                return // Failed recognition only affects search; content never enters diagnostics.
            }
            DispatchQueue.main.async { [weak self] in self?.recognitionStatus[entry.id] = "complete-\(text?.count ?? 0)" }
            guard let self, let text, !text.isEmpty else { return }
            self.queue.async {
                guard !self.failed, self.ocrEnabled, self.history.entries.contains(where: { $0.id == entry.id && !$0.secret }) else { return }
                self.history.update(entry.id) { $0.recognizedText = text }
                do { try self.commit() } catch { self.fail() }
            }
        }
    }
    func pin(_ entry: ClipboardEntry) {
        mutate { history in
            var next = (history.entries.compactMap(\.pinOrder).max() ?? -1) + 1
            for pinned in history.entries.filter({ $0.pinned && $0.pinOrder == nil }) {
                let rank = next; history.update(pinned.id) { $0.pinOrder = rank }; next += 1
            }
            history.update(entry.id) { $0.pinned.toggle(); $0.pinOrder = $0.pinned ? next : nil }
        }
    }
    func reorderPinned(_ moving: UUID, before target: UUID) {
        mutate { history in
            var items = ClipboardHistory.ordered(history.entries.filter(\.pinned))
            guard let from = items.firstIndex(where: { $0.id == moving }), let destination = items.firstIndex(where: { $0.id == target }), from != destination else { return }
            let value = items.remove(at: from); items.insert(value, at: items.firstIndex(where: { $0.id == target }) ?? items.count)
            for (index, entry) in items.enumerated() { history.update(entry.id) { $0.pinOrder = index } }
        }
    }
    func editTabs(_ action: @escaping (inout ClipboardTabs) throws -> Void) {
        queue.async { [self] in
            guard !failed else { return }
            let previous = archive.tabs
            do {
                try action(&archive.tabs)
                let retained = Set(archive.tabs.items.filter { $0.kind == .custom }.map(\.id))
                for entry in history.entries { history.update(entry.id) { $0.memberships.formIntersection(retained) } }
                try commit()
            } catch is ClipboardTabError {
                archive.tabs = previous
                DispatchQueue.main.async { [weak self] in self?.notice = "탭 이름은 비어 있거나 겹칠 수 없고, 탭은 하나 이상 남겨야 해요" }
            } catch { fail() }
        }
    }
    func membership(_ entry: UUID, tab: UUID, add: Bool) {
        queue.async { [self] in
            guard !failed, archive.tabs.items.contains(where: { $0.id == tab && $0.kind == .custom }) else { return }
            history.update(entry) { if add { $0.memberships.insert(tab) } else { $0.memberships.remove(tab) } }
            do { try commit() } catch { fail() }
        }
    }
    func clearTab(_ id: UUID, includingPins: Bool = false) {
        concealSecrets()
        queue.async { [self] in
            guard !failed, let tab = archive.tabs.items.first(where: { $0.id == id }) else { return }
            do {
                try purgeUndoOnQueue()
                var removed: [ClipboardEntry] = []
                if tab.kind == .custom { for entry in history.entries { history.update(entry.id) { $0.memberships.remove(id) } } }
                else { removed = history.remove { tab.contains($0) && (includingPins || !$0.pinned) } }
                try commit(removed: removed); try store.clearTemporary()
            } catch { fail() }
        }
    }
    func delete(_ entry: ClipboardEntry) { delete([entry]) }
    func delete(_ entries: [ClipboardEntry]) {
        let ids = Set(entries.map(\.id)); semantic.cancel(); concealSecrets(); selectedIDs.subtract(ids)
        queue.async { [self] in
            guard !failed else { return }
            do {
                let removed = history.entries.enumerated().filter { ids.contains($0.element.id) }
                guard !removed.isEmpty else { return }
                _ = history.remove { ids.contains($0.id) }
                try commit(publish: false)
                let group = UUID()
                for (index, saved) in removed {
                    if let id = saved.dataID { try store.trashData(id) }
                    if let oldest = undo.append(saved, index: index, now: clock(), group: group), let id = oldest.entry.dataID { try store.removeTrashData(id) }
                }
                refreshCapacity(); publishSnapshot(); publishUndo()
                DispatchQueue.main.async { [weak self] in self?.notice = "삭제했어요"; self?.startUndoTimer() }
            } catch { fail() }
        }
    }
    private func startUndoTimer() {
        guard undoTimer == nil else { return }
        undoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.expireUndo() }
    }
    func shelfPresentation(_ shown: Bool) {
        guard !shown else { return }
        commandHeld = false; concealSecrets()
        queue.async { [self] in undo.closed(now: clock()) }
    }
    private func publishUndo() {
        let value = !undo.items.isEmpty
        DispatchQueue.main.async { [weak self] in
            self?.canUndo = value
            if !value { self?.undoTimer?.invalidate(); self?.undoTimer = nil }
            self?.onChange?()
        }
    }
    private func purgeUndoOnQueue() throws { try store.clearTrash(); undo.clear(); refreshCapacity(); publishUndo() }
    func purgeUndo() { queue.async { [self] in do { try purgeUndoOnQueue() } catch { fail() } } }
    func expireUndo() {
        queue.async { [self] in
            guard undo.expired(now: clock()) else { return }
            do { try purgeUndoOnQueue() } catch { fail() }
        }
    }
    func undoDelete() {
        queue.async { [self] in
            guard !failed else { return }
            do {
                if undo.expired(now: clock()) { try purgeUndoOnQueue(); return }
                let items = undo.popGroup()
                guard !items.isEmpty else { return }
                refreshCapacity()
                var removed: [ClipboardEntry] = []
                let restoring = Set(items.map { $0.entry.id })
                for var item in items {
                    item.entry.memberships.formIntersection(Set(archive.tabs.items.filter { $0.kind == .custom }.map(\.id)))
                    if let id = item.entry.dataID { try store.restoreData(id) }
                    removed += history.restore(item.entry, at: item.index, preservingIDs: restoring)
                }
                try commit(removed: removed + history.prune(now: clock())); publishUndo()
                let restored = items.first?.entry.id
                DispatchQueue.main.async { [weak self] in
                    self?.notice = "되돌렸어요"; self?.restoredID = restored
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restoredID = nil }
                }
            } catch { fail() }
        }
    }
    func clear(includingPins: Bool) {
        semantic.cancel(); concealSecrets(); selectedIDs.removeAll()
        queue.async { [self] in
            guard !failed else { return }
            do {
                try purgeUndoOnQueue()
                let removed = history.remove { includingPins || !$0.pinned }
                try commit(removed: removed); try store.clearTemporary()
            } catch { fail() }
        }
    }
    private func mutate(_ action: @escaping (inout ClipboardHistory) -> Void) {
        queue.async { [self] in guard !failed else { return }; action(&history); do { try commit() } catch { fail() } }
    }
    private func removeEntries(_ action: @escaping (inout ClipboardHistory) -> [ClipboardEntry]) {
        queue.async { [self] in guard !failed else { return }; let removed = action(&history); do { try commit(removed: removed) } catch { fail() } }
    }
    func transform(_ entry: ClipboardEntry, using transform: ClipboardTextTransform) {
        guard entry.kind == .text, !entry.secret, let text = transform.apply(entry.text ?? "") else { return }
        let target = monitor.board
        let secret = entries.contains { $0.kind == .text && $0.secret && $0.text == text }
        monitor.performOwnWrite {
            target.clearContents(); target.setString(text, forType: .string)
            if secret { target.setString("1", forType: ClipboardPasteboard.concealed) }
        }
        add(ClipboardInput(kind: .text, text: text, source: "ddots", secret: secret), deduplicating: false)
        notice = "복사했어요"
    }
    func selection(or entry: ClipboardEntry) -> [ClipboardEntry] {
        selectedIDs.contains(entry.id) ? ClipboardHistory.ordered(entries.filter { selectedIDs.contains($0.id) }) : [entry]
    }
    func writers(_ entries: [ClipboardEntry], forDrag: Bool, completion: @escaping ([NSPasteboardWriting]) -> Void) {
        var result: [NSPasteboardWriting] = []
        if forDrag {
            var individual: [NSPasteboardWriting] = []
            func each(_ index: Int) {
                if index == entries.count { completion(individual); return }
                writers(entries[index], forDrag: true) { values in individual += values; each(index + 1) }
            }
            each(0); return
        }
        let texts = entries.filter { $0.kind == .text }
        if !texts.isEmpty {
            let item = NSPasteboardItem(); item.setString(texts.compactMap(\.text).joined(separator: "\n"), forType: .string)
            if texts.contains(where: \.secret) { item.setString("1", forType: ClipboardPasteboard.concealed) }
            result.append(item)
        }
        let media = entries.filter { $0.kind != .text }
        func next(_ index: Int) {
            if index == media.count { completion(result); return }
            writers(media[index], forDrag: forDrag) { values in result += values; next(index + 1) }
        }
        next(0)
    }
    func copy(_ entries: [ClipboardEntry], to board: NSPasteboard? = nil) {
        writers(entries, forDrag: false) { [weak self] writers in
            guard let self, !writers.isEmpty else { return }
            let target = board ?? self.monitor.board
            var success = false
            let write = { target.clearContents(); success = target.writeObjects(writers) }
            if target === self.monitor.board { self.monitor.performOwnWrite(write) } else { write() }
            if success { self.concealSecrets(); self.notice = "복사했어요"; self.onCopied?() }
            else { self.notice = "클립보드에 복사하지 못했어요" }
        }
    }
    func copy(_ entry: ClipboardEntry, plain: Bool = false, to board: NSPasteboard? = nil) {
        writers(entry, plain: plain, forDrag: false) { [weak self] writers in
            guard let self, !writers.isEmpty else { return }
            let target = board ?? self.monitor.board
            var written = false
            let write = { target.clearContents(); written = target.writeObjects(writers) }
            if target === self.monitor.board { self.monitor.performOwnWrite(write) } else { write() }
            guard written else { self.notice = "클립보드에 복사하지 못했어요"; return }
            self.concealSecrets(); self.notice = "복사했어요"; self.onCopied?()
        }
    }
    func writers(_ entry: ClipboardEntry, plain: Bool = false, forDrag: Bool, completion: @escaping ([NSPasteboardWriting]) -> Void) {
        queue.async { [self] in
            guard !failed else { DispatchQueue.main.async { completion([]) }; return }
            do {
                var payload = Data()
                var export: URL?
                if let id = entry.dataID {
                    payload = try store.data(id)
                    if forDrag { export = try store.export(payload, extension: entry.exportExtension) }
                }
                let data = payload, exported = export
                DispatchQueue.main.async { [weak self] in
                    var writers: [NSPasteboardWriting] = []
                    if entry.kind == .files {
                        writers = entry.files.filter { FileManager.default.fileExists(atPath: $0) }.map { path -> NSPasteboardWriting in
                            let item = NSPasteboardItem()
                            item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                            if entry.secret { item.setString("1", forType: ClipboardPasteboard.concealed) }
                            if forDrag { item.setString(entry.id.uuidString, forType: .init("app.ddots.clipboard-entry")) }
                            return item
                        }
                        if writers.isEmpty { self?.notice = "원본 없음" }
                    } else if let exported {
                        let item = NSPasteboardItem(); item.setString(exported.absoluteString, forType: .fileURL)
                        if entry.secret { item.setString("1", forType: ClipboardPasteboard.concealed) }
                        item.setString(entry.id.uuidString, forType: .init("app.ddots.clipboard-entry")); writers = [item]
                    }
                    else {
                        let item = NSPasteboardItem()
                        if entry.kind == .text {
                            item.setString(entry.text ?? "", forType: .string)
                            if !plain, let rtf = entry.rtf { item.setData(rtf, forType: .rtf) }
                        } else { item.setData(data, forType: .init(entry.dataType ?? "public.png")) }
                        if entry.secret { item.setString("1", forType: ClipboardPasteboard.concealed) }
                        writers = [item]
                    }
                    completion(writers)
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.notice = "보관한 데이터를 읽지 못했어요"; completion([]) } }
        }
    }
    func previewURLs(_ entry: ClipboardEntry, completion: @escaping ([URL], [URL]) -> Void) {
        queue.async { [self] in
            do {
                var urls: [URL] = [], owned: [URL] = []
                if entry.kind == .files { urls = entry.files.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
                else if let id = entry.dataID {
                    let data = try store.data(id)
                    let url = try store.export(data, extension: entry.exportExtension)
                    urls = [url]; owned = [url]
                }
                DispatchQueue.main.async { completion(urls, owned) }
            } catch { DispatchQueue.main.async { completion([], []) } }
        }
    }
    func thumbnail(_ entry: ClipboardEntry, reveal: Bool = false, completion: @escaping (NSImage?, String?) -> Void) {
        guard !entry.secret || reveal else { completion(nil, nil); return }
        queue.async { [self] in
            let bytes = entry.dataID.flatMap { try? store.data($0) }
            Task.detached(priority: .utility) {
                var image: NSImage?, duration: String?
                if entry.kind == .image, let bytes { image = Self.smallImage(bytes) }
                else if entry.kind == .video, let bytes { (image, duration) = await ClipboardVideo.thumbnail(data: bytes, type: entry.dataType ?? "public.mpeg-4") }
                else if let movie = entry.files.first(where: { ClipboardEntry.videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                    (image, duration) = await ClipboardVideo.thumbnail(file: URL(fileURLWithPath: movie))
                } else if let path = entry.files.first, ClipboardEntry.imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
                          let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ClipboardOCR.maximumBytes,
                          let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) { image = Self.smallImage(data) }
                let result = image, time = duration
                DispatchQueue.main.async {
                    completion(result, time)
                }
            }
        }
    }
    private static func smallImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
    func makeClearAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "클립보드 보관함을 비울까요?"
        alert.informativeText = "보관함 기록과 보관 데이터만 삭제합니다. 원본 파일과 시스템 클립보드는 유지합니다. 되돌릴 수 없습니다."
        alert.addButton(withTitle: "비우기"); alert.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        let options = NSPopUpButton(frame: CGRect(x: 0, y: 30, width: 280, height: 26))
        options.addItems(withTitles: [tabs.current.kind == .custom ? "현재 탭에서 빼기만" : "현재 탭의 항목", "보관함 전체"])
        let pins = NSButton(checkboxWithTitle: "고정 포함", target: nil, action: nil)
        pins.frame = CGRect(x: 0, y: 0, width: 280, height: 26)
        let accessory = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 60)); accessory.addSubview(options); accessory.addSubview(pins)
        alert.accessoryView = accessory
        return alert
    }
    func confirmClear() {
        let alert = makeClearAlert()
        guard let accessory = alert.accessoryView,
              let options = accessory.subviews.compactMap({ $0 as? NSPopUpButton }).first,
              let pins = accessory.subviews.compactMap({ $0 as? NSButton }).first(where: { !($0 is NSPopUpButton) }) else { return }
        if alert.runModal() == .alertFirstButtonReturn {
            if options.indexOfSelectedItem == 0 { clearTab(tabs.current.id, includingPins: pins.state == .on) }
            else { clear(includingPins: pins.state == .on) }
        }
    }
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
    }
    func prepareClose(_ run: ClosingRun) {
        paused = true; maintenance?.invalidate(); maintenance = nil
        // Finish queued captures before the app's existing bounded shutdown replies.
        run.add(on: queue) { [self] in do { try purgeUndoOnQueue() } catch { fail() }; failed = true }
    }
}
