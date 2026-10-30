import AppKit
import Security
import UniformTypeIdentifiers

/// The Slack user token lives only in the login keychain, never in settings or logs.
///
/// The item is read and written through `/usr/bin/security`, not by this app. A keychain item is tied to the code
/// that made it, and a locally signed app is a different piece of code after every build, so an item the app made
/// itself made macOS ask for the login password again each time. The system tool is the same code on every build.
enum SlackToken {
    private static let account = "user-token"
    private static var service: String { AppIdentity.bundleID + ".slack-token" }
    private static func security(_ arguments: [String], input: String? = nil) -> String? {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security"); process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
    private static func read() -> String? {
        security(["find-generic-password", "-s", service, "-a", account, "-w"]).flatMap(SlackAPI.validToken)
    }
    /// Items the app made itself in earlier builds under its current identifier.
    private static func legacyQuery(_ identifier: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: identifier + ".slack", kSecAttrAccount as String: account]
    }
    private static func legacyRead(_ identifier: String) -> String? {
        var request = legacyQuery(identifier); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8).flatMap(SlackAPI.validToken)
    }
    static func load() -> String? {
        if let token = read() { return token }
        // An older item moves over the first time it is asked for; macOS asks about that one read, for the last time.
        let identifiers = [AppIdentity.bundleID]
        for identifier in identifiers {
            guard let token = legacyRead(identifier) else { continue }
            if save(token) { identifiers.forEach { SecItemDelete(legacyQuery($0) as CFDictionary) } }
            return token
        }
        return nil
    }
    static func save(_ token: String) -> Bool {
        guard let token = SlackAPI.validToken(token) else { return false }
        // The command goes in on standard input, so the token never shows in the process list.
        _ = security(["-i"], input: "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -w \"\(token)\"\n")
        return read() == token
    }
    static func delete() {
        _ = security(["delete-generic-password", "-s", service, "-a", account])
        SecItemDelete(legacyQuery(AppIdentity.bundleID) as CFDictionary)
    }
}

/// Owns the Slack side of the chat window: polling, sending, unread counts and what the view shows.
final class SlackController {
    private struct Echo { var room: String; var thread: String?; var message: ChatMessage }
    let model = SlackModel()
    let find = SlackFind()
    let queue = DispatchQueue(label: AppIdentity.bundleID + ".slack", qos: .utility)
    /// Files travel on their own queue so a large one never holds up the conversation.
    let fileQueue = DispatchQueue(label: AppIdentity.bundleID + ".slack.files", qos: .utility)
    private(set) var bridge: SlackBridge?
    private(set) var api: SlackAPI?
    private(set) var snapshot = SlackBridge.Snapshot() {
        didSet { if snapshot.threads != oldValue.threads { find.liveRevision += 1 } }
    }
    let retention = SlackRetention()
    let temporaryFiles = SlackTemporaryFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent(CommandLine.arguments.contains("--ui-smoke") ? "ddots-private-smoke-" + UUID().uuidString : "ddots-private-files"))
    /// The room mapping the retention rules were last given. The closing check sets it stale to see a late reading's publish held back.
    var retentionMapping = ""
    var store = SlackFileStore(root: SlackFileStore.standard())
    var wantedThumbs = Set<String>()
    /// Threads the user marked read with their bell, with how far each had got at the time.
    var dismissed: [String: Double] = [:]
    var confirmed: [String: Double] = [:]
    /// True while the file chooser is up, so the conversation is not folded behind it.
    var picking = false
    var onPicked: (() -> Void)?
    /// Shows a saved file beside the conversation. False when it is a kind only its own app can open.
    var onShowFile: ((URL) -> Bool)?
    var onShowTemporaryFile: ((URL) -> Bool)?
    var lastSaved: URL?
    private var receiptWorker = ShrimpReceipts()
    private var receiptBusy = false
    private var removedUploadIDs = Set<String>()
    private(set) var syncing = false
    /// What the diagnostics file last held. Touched on the Slack queue only.
    private var diagnostics = ""
    private var diagnosticsGate = SlackDiagnosticsGate()
    private var echoes: [Echo] = []
    var updateHasTransfers: Bool { !echoes.isEmpty || !model.busyFiles.isEmpty }
    var updateHasDrafts: Bool {
        !model.currentDraft.isEmpty || !model.drafts.saved.isEmpty || !model.drafts.failures.isEmpty
    }
    private var wanted = Set<String>()
    private(set) var limits: [String: Int] = [:]
    var lastRead: [String: Double] = [:]
    private(set) var localRead: [String: Double] = [:]
    private(set) var localThreads: [String: Double] = [:]
    private var ownRead: [String: Double] = [:]
    private var remoteQuiet: [String: Double] = [:]
    private var readRooms = Set<String>()
    private var readThreads = Set<String>()
    var sendNotice: String?
    private var shownRoom: String?
    /// The room that has been brought to its newest line since it finished loading, and whether its replies were in by then.
    private var landed: (room: String?, whole: Bool) = (nil, false)
    private var shownSince = Date.distantPast
    /// How often the user had scrolled by hand when the room was shown; once they have, it is not moved for them.
    private var shownScrolls = 0
    /// Replies that arrive this soon after a room is shown still move it to its newest line; later the reader is left alone.
    static let settleWindow: TimeInterval = 6
    /// The newest line a character wrote in ddots, to notice the next one.
    private var ddotsNewest: Date?
    /// Off in smoke runs, which neither touch the real settings nor send anything.
    var persists = true
    // Screen choices shared with this account's other Macs. See `SlackSettingsSync.swift`.
    var settings: SettingsStore?
    var syncObserved: [String: String] = [:]
    var syncExplicit: [String: SyncEntry] = [:]
    var syncedThreadRead: [String: Double] = [:]
    var syncObservedAt = Date.distantPast
    /// Sends shared choices to the Mac that keeps them: entries, Slack user, and whether they make this Mac the standard.
    var syncSend: (([String: SyncEntry], String, Bool) -> Void)?
    var characters: [ChatCharacter] = []
    /// The characters as Hermes names them, or as the record's keeper wrote them down when this Mac has no Hermes to ask.
    var cast: [ChatCharacter] {
        let configured = DdotsConfig.shared.members.map { ChatCharacter(id: HermesRouting.str($0["profile"]), name: HermesRouting.str($0["displayName"])) }
        return configured.isEmpty ? (characters.isEmpty ? castFallback : characters) : ChatCharacter.ordered(configured)
    }

    // The ddots record. See `DdotsRecord.swift`.
    /// Where the record is kept; nil when nothing is kept or read.
    var archive: DdotsArchive?
    /// True on the one Mac that writes the record. The others only read it, so iCloud never has two versions to choose between.
    var keepsRecord = false
    /// What is already written, once that has been read back. Nothing is written before then.
    var recordWriter: DdotsWriter?
    var recordMemo = DdotsRecordMemo()
    /// Lines of months the writer has not read back yet; they are written once those months are read.
    var recordWaiting: [DdotsRecordMemo.Candidate] = []
    var readingBack = false
    /// Lines still to be written, among them any a write failed on; they are tried again once `recordHeldUntil` has passed.
    var recordBacklog = DdotsBacklog()
    var recordWriting = false
    var recordHeldUntil = Date.distantPast
    /// What the room says while the record cannot be written.
    var recordNotice: String?
    /// The record's files that are still to be fetched.
    var fetches = DdotsFetches()
    /// How far each character's record is known to be whole, and when its room was last read through.
    var recordThrough: [String: Double] = [:]
    var recordScanned: [String: Date] = [:]
    /// Lines read from the record for showing, by character, with the months they cover.
    var kept: [String: [DdotsLine]] = [:]
    var keptMonths: [String] = []
    /// The first month read at start; months before it are let go again on leaving the room.
    var keptFloor: String?
    var keptEarlier = false
    var keptRevision = 0
    var keptThreads: [String: (revision: Int, room: String, threads: [SlackThread])] = [:]
    var loadingKept = false
    var castFallback: [ChatCharacter] = []
    var castWritten: [DdotsArchive.Member] = []
    /// From this Mac's Hermes record; empty when Hermes runs elsewhere.
    var activity = SlackActivity() { didSet { if activity != oldValue { publish() } } }
    var recordWindow = DdotsThreadWindow()
    var recordWindowThreads: [SlackThread] = []
    var recordReveal: String?
    var chatOpen = false {
        didSet {
            guard chatOpen != oldValue else { return }
            if chatOpen { recordWindow.reset() }
            // Folding the window puts the next new post back on the usual character.
            if !chatOpen { model.findHighlight = nil; if model.findOpen { model.closeFind() }; model.ddotsTarget = Ddots.defaultTarget; model.ddotsPicked = false }
            letGoOlderMonths()
            publish()
            if chatOpen { enterConversation() }
        }
    }
    var onChange: (() -> Void)?
    var onEnterIMessage: (() -> Void)?
    /// Reuse room entry so delayed replies and a subsequent manual scroll keep their usual precedence.
    private func enterConversation() {
        guard chatOpen else { return }
        if model.source == .slack {
            guard find.target == nil, linkTarget == nil, let room = model.selected else { return }
            model.choose(room)
        } else { onEnterIMessage?() }
    }
    private(set) var incoming: [ChatMessage] = []
    /// Same room/thread watermarks as the badge. Scanning cursors (ddotsThrough) are not read receipts.
    var readNudgeIDs: Set<String> {
        let candidates = Set(incoming.map(\.id))
        let reads = snapshot.threadRead.merging(syncedThreadRead, uniquingKeysWith: max)
        var result = Set<String>()
        for (room, threads) in snapshot.threads {
            for thread in threads {
                for message in thread.messages where candidates.contains(message.id) {
                    let remote = message.id == thread.root.id ? (snapshot.roomRead[room] ?? 0)
                        : max(reads[thread.id] ?? 0, message.slackBroadcast ? (snapshot.roomRead[room] ?? 0) : 0)
                    if message.date.timeIntervalSince1970 <= max(lastRead[room] ?? 0, remote) { result.insert(message.id) }
                }
            }
        }
        return result
    }

    var unreadTotal: Int { model.unreadTotal }

    init() {
        model.privateFiles = temporaryFiles
        if !CommandLine.arguments.contains("--ui-smoke") { ownRead = UserDefaults.standard.dictionary(forKey: "slackOwnRead") as? [String: Double] ?? [:] }
        model.onFind = { [weak self] in self?.changeFind() }
        model.onFindOpen = { [weak self] in self?.openFind() }
        model.onFindSubmit = { [weak self] in self?.submitFind() }
        model.onFindReveal = { [weak self] group, message in self?.revealFind(group, message: message) }

        model.onNeedThread = { [weak self] id in
            guard let self, self.model.isDdots, self.recordWindowThreads.contains(where: { $0.id == id }) else { return }
            self.recordReveal = id; self.publish()
        }
        model.onSelect = { [weak self] room in
            guard let self else { return }
            if self.persists { UserDefaults.standard.set(room, forKey: "slackRoom") }
            self.publish(); self.tick()
        }
        // Clicking the room already shown starts its entry over: a later reply may move the view there once more.
        model.onEnterAgain = { [weak self] in
            guard let self else { return }
            self.recordWindow.reset(); self.letGoOlderMonths(); self.publish()
            self.shownSince = Date(); self.shownScrolls = self.model.userScrolls; self.landed.whole = false
        }
        model.onSource = { [weak self] source in
            guard let self else { return }
            self.recordWindow.reset(); self.letGoOlderMonths()
            if self.persists { UserDefaults.standard.set(source.rawValue, forKey: "chatSource") }
            self.publish(); self.enterConversation(); self.tick()
        }
        // Reading a transcript for its summary must not mark unread messages as read.
        model.onLoadSummary = { [weak self] thread in
            guard let self, !thread.loaded else { return }
            self.wanted.insert(thread.room + ":" + thread.ts); self.tick()
        }
        model.onOpen = { [weak self] thread in
            guard let self else { return }
            self.markRead(thread)
            guard !thread.loaded else { return }
            self.wanted.insert(thread.room + ":" + thread.ts); self.tick()
        }
        model.onOlder = { [weak self] in
            guard let self, !self.shownRooms.isEmpty else { return }
            // A character's room goes further back in the record than Slack does.
            if self.readsRecord(self.shownRooms) {
                if self.model.isDdots {
                    guard !self.loadingKept else { return }
                    if let id = self.model.visibleThreads.first { self.model.holdThreadPage(id) }
                    let needsMonth = self.recordWindow.older(loadedCount: self.recordWindowThreads.count, hasEarlier: self.keptEarlier)
                    if needsMonth { self.loadKept(initial: false) } else { self.publish() }
                } else { self.loadKept(initial: false) }
                return
            }
            for room in self.shownRooms { self.limits[room] = min(200, (self.limits[room] ?? SlackBridge.pageSize) + SlackBridge.pageSize) }
            self.model.loading = true; self.tick()
        }

        model.onSend = { [weak self] text, room, thread, files in
            if files.isEmpty { self?.send(text, room: room, thread: thread) } else { self?.sendFiles(text, room: room, thread: thread, files: files) }
        }
        model.onPageSend = { [weak self] command, thread, completion in
            guard let self else { completion(); return }
            self.sendPage(command, thread: thread, completion: completion)
        }
        model.onRead = { [weak self] thread in self?.markRead(thread) }
        model.onRefuse = { [weak self] reason in self?.sendNotice = reason; self?.publish() }
        model.onFailureSettled = { [weak self] in
            guard let self, self.sendNotice != nil else { return }
            self.sendNotice = nil; self.publish()
        }
        model.onThumb = { [weak self] file in self?.loadThumb(file) }
        model.onFile = { [weak self] file, message in self?.open(file, in: message) }
        model.onAttach = { [weak self] in self?.pickFiles() }
        model.onLayout = { [weak self] in self?.onChange?() }
        model.onMute = { [weak self] in
            guard let self else { return }
            if self.persists {
                UserDefaults.standard.set(Array(self.model.muted).sorted(), forKey: "slackMuted")
                UserDefaults.standard.set(self.model.chatMuted, forKey: "chatMuted")
            }
            self.publish()
        }
        model.onHidden = { [weak self] in
            guard let self else { return }
            if self.persists { UserDefaults.standard.set(Array(self.model.hidden).sorted(), forKey: "slackHidden") }
            self.changeRetention()
            self.publish(); self.tick()
        }
        model.onUnkept = { [weak self] in self?.changeRetention(); self?.publish() }
        model.onCreateRoom = { [weak self] in self?.createRoom() }
        model.onInvite = { [weak self] room in self?.invite(room) }
        model.onInviteAgents = { [weak self] room in self?.invite(room, agentsOnly: true) }
        model.onArchive = { [weak self] room in self?.archive(room) }
        model.onUnarchive = { [weak self] room in self?.unarchive(room) }
        model.onDeleteRoom = { [weak self] room in self?.deleteRoom(room) }
        model.onRename = { [weak self] room in self?.rename(room) }
        model.onDeleteSection = { [weak self] zone in
            guard let self, self.model.sections.count > 1, let first = self.model.sections.first(where: { $0 != zone }) else { return }
            let name = self.model.groupName(zone), count = self.model.groups[zone]?.count ?? 0
            let moved = count > 0 ? " 안에 있는 채널 \(count)개는 ‘\(self.model.groupName(first))’로 옮겨져요." : ""
            guard SlackRoomDialogs.confirm("‘\(name)’ 섹션을 삭제할까요?", "섹션만 없어지고 슬랙 채널은 그대로예요." + moved, button: "삭제") else { return }
            if self.persists { SlackRoomPictures.remove(Ddots.sectionPicture(zone)); self.syncPicture(Ddots.sectionPicture(zone)) }
            self.model.roomPictures[Ddots.sectionPicture(zone)] = nil
            self.model.removeSection(zone)
        }
        model.onGroupRename = { [weak self] zone in
            guard let self, let name = SlackRoomDialogs.renameGroup(self.model.groupName(zone)) else { return }
            self.model.groupNames[zone] = name
            self.model.onZones?()
        }
        model.onPicture = { [weak self] room in self?.choosePicture(room) }
        model.onClearPicture = { [weak self] room in
            guard let self, self.persists else { return }
            SlackRoomPictures.remove(room); self.model.roomPictures[room] = nil; self.syncPicture(room)
        }
        model.onDelete = { [weak self] thread in
            guard let self, !self.closing, let bridge = self.bridge, self.persists else { return }
            self.sendNotice = nil
            self.markRead(thread)
            self.askedDelete.insert(thread.id)
            self.queue.async { bridge.delete(room: thread.room, ts: thread.ts, singleOnly: thread.replyCount == 0) }
            self.publish(); self.tick()
        }
        model.onBell = { [weak self] thread in
            guard let self else { return }
            if (self.dismissed[thread.id] ?? -.infinity) >= thread.latest { self.dismissed[thread.id] = nil; self.syncUndismiss(thread.id) } else { self.dismissed[thread.id] = thread.latest; self.markRead(thread) }
            // Only the most recent marks are kept.
            if self.dismissed.count > 300 { self.dismissed = Dictionary(uniqueKeysWithValues: self.dismissed.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
            if self.persists { UserDefaults.standard.set(self.retention.filtered(self.dismissed), forKey: "slackDismissed") }
            self.publish()
        }
        model.onConfirm = { [weak self] thread in
            guard let self, let request = SlackNotice.pendingApproval(thread, confirmed: Set(self.confirmed.keys)) else { return }
            self.markRead(thread)
            self.confirmed[request.id] = Date().timeIntervalSince1970
            if self.confirmed.count > 300 { self.confirmed = Dictionary(uniqueKeysWithValues: self.confirmed.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
            if self.persists { UserDefaults.standard.set(self.retention.filtered(self.confirmed), forKey: "slackConfirmed") }
            self.publish()
        }
        model.onSeen = { [weak self] thread in
            guard let self, self.model.notices.contains(where: { $0.id == SlackNotice.alertID && $0.threads.contains(thread.id) }) else { return }
            // Opening a notification is reading it; its bell can still put it back. Questions wait for an answer.
            self.dismissed[thread.id] = thread.latest; self.markRead(thread)
            if self.dismissed.count > 300 { self.dismissed = Dictionary(uniqueKeysWithValues: self.dismissed.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
            if self.persists { UserDefaults.standard.set(self.retention.filtered(self.dismissed), forKey: "slackDismissed") }
            self.publish()
        }
        model.onReadAll = { [weak self] in self?.readAll() }
        model.onPins = { [weak self] in
            guard let self else { return }
            if self.persists { UserDefaults.standard.set(self.model.pins, forKey: "slackPins") }
            self.publish()
        }
        model.onQuery = { [weak self] in self?.publish() }
        model.onZones = { [weak self] in
            guard let self else { return }
            if self.persists {
                UserDefaults.standard.set(self.model.sections, forKey: "slackSections")
                UserDefaults.standard.set(self.model.zoneOf, forKey: "slackZones")
                UserDefaults.standard.set(self.model.groupsOpen.sorted(), forKey: "slackGroupsOpen")
                UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: self.model.groupNames.map { (String($0.key), $0.value) }), forKey: "slackGroupNames")
            }
            self.publish()
        }
        model.onStack = { [weak self] in
            guard let self else { return }
            if self.persists { UserDefaults.standard.set(self.model.stackOpen, forKey: "slackStackOpen") }
            self.publish()
        }
        model.onReveal = { [weak self] id in
            guard let self else { return }
            self.reveal(id, query: self.model.query)
        }
        model.onSidebar = { [weak self] width in if self?.persists == true { UserDefaults.standard.set(Double(width), forKey: "slackSidebarWidth") } }
    }

    func changeRetention() {
        // It waits on both queues; closing must not, and the next start applies the choice again.
        guard !closing else { return }
        retention.update(model.unkept, hidden: model.hidden)
        if persists {
            if !model.unkept.isEmpty { URLCache.shared.removeAllCachedResponses() }
            UserDefaults.standard.set(Array(model.unkept).sorted(), forKey: SlackRetention.key)
            var through = UserDefaults.standard.dictionary(forKey: "ddotsThrough") as? [String: Double] ?? [:]
            for member in model.ddotsMembers where retention.excludes(member.room) { through[member.profile] = nil }
            if let hub = model.ddotsHub, retention.excludes(hub) { through[Ddots.room] = nil }
            UserDefaults.standard.set(through, forKey: "ddotsThrough")
            for key in ["slackLastRead", "slackOwnRead", "slackDismissed", "slackConfirmed", "slackDeletedThreads"] {
                let values = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
                UserDefaults.standard.set(retention.filtered(values), forKey: key)
            }
        }
        let excluded = model.unkept, rooms = snapshot.rooms, archive = self.archive ?? (persists ? DdotsArchive(root: DdotsArchive.standard(), retention: retention) : nil), store = self.store
        if let bridge { queue.sync { bridge.removeUnkeptCache() } }
        else if persists {
            retention.locked {
                if var cache = SlackCache.read(Self.cacheURL) {
                    for room in retention.cacheExcluded { cache.drop(room) }
                    if let data = cache.fitted(), SlackCache.write(data, to: Self.cacheURL) { return }
                    SlackCache.delete(Self.cacheURL)
                }
            }
        }
        // Writes and downloads already queued finish before existing copies are removed.
        var failed = false
        fileQueue.sync {
            guard !excluded.isEmpty else { return }
            do {
                try archive?.removeUnkept()
                for room in rooms where excluded.contains(room.id) {
                    let folder = store.root.appendingPathComponent(SlackFileStore.safe(room.name))
                    if FileManager.default.fileExists(atPath: folder.path) {
                        guard rooms.filter({ SlackFileStore.safe($0.name) == SlackFileStore.safe(room.name) }).count == 1 else { failed = true; continue }
                        try FileManager.default.removeItem(at: folder)
                    }
                }
            } catch { failed = true }
        }
        if failed { sendNotice = "이전에 보관한 파일 일부를 지우지 못했어요. 공유 폴더의 기록과 파일을 확인해 주세요." }
        if persists, !retention.cacheExcluded.isEmpty {
            let folder = Self.cacheURL.deletingLastPathComponent()
            queue.sync { try? FileManager.default.removeItem(at: folder.appendingPathComponent("slack-diagnostics.txt")); diagnostics = "" }
        }
    }

    func showTemporary(_ url: URL) {
        guard !closing else { return }
        lastSaved = url
        // The pane uses a separate, nonpersistent store for confidential attachments.
        if onShowTemporaryFile?(url) != true, persists { NSWorkspace.shared.open(url) }
    }

    private func openTemporary(_ file: ChatFile) {
        guard !closing, let url = URL(string: file.url), file.size <= SlackFileStore.largest, !model.busyFiles.contains(file.id) else { return }
        let api = self.api, temporaryFiles = self.temporaryFiles
        model.busyFiles.insert(file.id)
        fileQueue.async { [weak self] in
            var data: Data?
            if url.isFileURL { data = try? Data(contentsOf: url) }
            else if case .success(let fetched)? = api?.raw(url, nil) { data = fetched }
            let saved = data.flatMap { try? temporaryFiles.save($0, name: file.name) }
            DispatchQueue.main.async {
                guard let self, !self.closing else { return }
                self.model.busyFiles.remove(file.id)
                if let saved { self.showTemporary(saved) } else { self.sendNotice = "임시 파일을 열지 못했어요." }
            }
        }
    }

    var connected: Bool { bridge != nil }
    func restore() {
        let defaults = UserDefaults.standard
        lastRead = defaults.dictionary(forKey: "slackLastRead") as? [String: Double] ?? [:]
        model.selected = defaults.string(forKey: "slackRoom")
        model.hidden = Set(defaults.stringArray(forKey: "slackHidden") ?? [])
        model.unkept = Set(defaults.stringArray(forKey: SlackRetention.key) ?? [])
        retention.update(model.unkept, hidden: model.hidden)
        try? temporaryFiles.clear()
        confirmed = defaults.dictionary(forKey: "slackConfirmed") as? [String: Double] ?? [:]
        dismissed = defaults.dictionary(forKey: "slackDismissed") as? [String: Double] ?? [:]
        model.muted = Set(defaults.stringArray(forKey: "slackMuted") ?? []); model.chatMuted = defaults.bool(forKey: "chatMuted")
        if let pins = defaults.stringArray(forKey: "slackPins"), pins.count == SlackRoomOrder.slots { model.pins = pins }
        if let width = defaults.object(forKey: "slackSidebarWidth") as? Double { model.sidebarWidth = SlackSidebar.snapped(CGFloat(width)) }
        model.stackOpen = defaults.bool(forKey: "slackStackOpen")
        if let sections = defaults.array(forKey: "slackSections") as? [Int], !sections.isEmpty, !sections.contains(Ddots.directZone) { model.sections = sections }
        let known = Set(model.sections + [Ddots.directZone])
        model.zoneOf = (defaults.dictionary(forKey: "slackZones") as? [String: Int] ?? [:]).filter { model.sections.contains($0.value) }
        model.groupsOpen = Set((defaults.array(forKey: "slackGroupsOpen") as? [Int] ?? []).filter { model.sections.contains($0) })
        for (key, name) in defaults.dictionary(forKey: "slackGroupNames") as? [String: String] ?? [:] { if let zone = Int(key), known.contains(zone) { model.groupNames[zone] = name } }
        model.roomPictures = SlackRoomPictures.load()
        // Reading the keychain can stop to ask the user (a locked keychain, a new build), so it never happens
        // on the main thread: the pet stays responsive and the Slack side simply connects once the answer comes.
        fileQueue.async { [weak self] in
            guard let token = SlackToken.load() else { return }
            DispatchQueue.main.async {
                guard let self, self.bridge == nil else { return }
                self.start(SlackAPI.live(token: token))
            }
        }
        // The side last shown comes back. With ddots on that is Slack once it connects (`start`); until then, and on
        // a Mac that never connects Slack, the iMessage side stays within reach.
        model.source = IMessageFeature.enabled ? (defaults.string(forKey: "chatSource").flatMap(ChatSource.init(rawValue:)) ?? (Ddots.enabled ? .slack : .imessage)) : .slack
        // The first time ddots is there it is the room shown; after that the saved choice stands.
        if Ddots.enabled, !defaults.bool(forKey: "ddotsShown") { model.selected = Ddots.room; defaults.set(true, forKey: "ddotsShown") }
        openRecord()
        changeRetention()
    }
    /// What was read from Slack is kept here between runs, on this Mac only.
    static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder).appendingPathComponent(SlackCache.fileName)
    }
    /// A cache of the checks' own, in a scratch folder, so the closing flush can be checked without the real one.
    var scratchCache: URL?
    var cacheFile: URL? { persists ? Self.cacheURL : scratchCache }
    func start(_ api: SlackAPI) {
        guard !closing else { return }
        let bridge = SlackBridge(api: api, cache: cacheFile, retention: retention)
        receiptWorker = ShrimpReceipts(); receiptBusy = false; removedUploadIDs = []
        self.bridge = bridge; self.api = api; localRead = [:]; localThreads = [:]; remoteQuiet = [:]; snapshot = .init(); echoes = []; sendNotice = nil; wantedThumbs = []
        model.changeConnection()
        model.connected = true; model.loading = true
        if Ddots.enabled, persists { model.source = .slack }
        publish()
        guard persists else { tick(); return }
        // What the last run kept is shown before Slack has answered anything. The first reading waits behind it on the queue.
        let cast = cast
        syncing = true
        queue.async { [weak self] in
            let kept = bridge.restore(characters: cast)
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncing = false
                guard !self.closing, self.bridge === bridge else { return }
                if let kept { self.snapshot = kept; self.publish() }
                self.tick()
            }
        }
    }
    /// Threads deleted from Slack through this window, by id with when. One of them that the record or a
    /// late listing still holds is not shown again.
    var deletedThreads: [String: Double] = UserDefaults.standard.dictionary(forKey: "slackDeletedThreads") as? [String: Double] ?? [:]
    /// Deletions asked for that the reading has not taken up yet; they show as under way from the press.
    private var askedDelete = Set<String>()
    /// How a deleting ended: done, and the thread stays away; or stopped, and the reason is said.
    private func settle(_ result: SlackBridge.Snapshot) {
        askedDelete.subtract(result.removing.keys); askedDelete.subtract(result.removed.keys)
        guard !result.removed.isEmpty else { return }
        for (id, reason) in result.removed {
            if let reason { sendNotice = reason; continue }
            deletedThreads[id] = Date().timeIntervalSince1970
            model.release(thread: id)
        }
        if deletedThreads.count > 500 { deletedThreads = Dictionary(uniqueKeysWithValues: deletedThreads.sorted { $0.value > $1.value }.prefix(400).map { ($0.key, $0.value) }) }
        if persists { UserDefaults.standard.set(retention.filtered(deletedThreads), forKey: "slackDeletedThreads") }
        publish()
    }
    /// A thread a link pointed at that is not among the ones shown yet, with when to stop waiting for it.
    private var linkTarget: (id: String, url: URL?, until: Date)?
    /// Threads asked for through a link, as `room:ts` with when; they are read like the ones Hermes worked in lately.
    private var followed: [String: Double] = [:]
    /// What is done with a link that could not be followed here after all.
    var onUnfollowed: ((URL) -> Void)?
    static let followWait: TimeInterval = 15
    /// A link to a thread of this workspace is followed inside the window: its room is shown and the thread brought
    /// into view. One older than the room's listing is read first. False for any other address.
    func follow(_ url: URL) -> Bool {
        guard bridge != nil, model.source == .slack, let place = SlackCopy.place(of: url, workspace: snapshot.workspace),
              snapshot.rooms.contains(where: { $0.id == place.room }) else { return false }
        return follow(room: place.room, ts: place.ts, url: url)
    }
    @discardableResult func follow(room: String, ts: String, url: URL?) -> Bool {
        let shownAs = Ddots.enabled && room == model.ddotsHub ? Ddots.room : room
        guard shownAs == Ddots.room || !model.hidden.contains(room) else { return false }
        model.select(shownAs)
        let id = "slack:\(room):\(ts)"
        model.onNeedThread?(id)
        if model.threads.contains(where: { $0.id == id && $0.loaded && (find.target == nil || $0.messages.contains { $0.id == find.target?.message }) }) { linkTarget = nil; model.go(to: id); return true }
        linkTarget = (id, url, Date().addingTimeInterval(Self.followWait))
        followed[room + ":" + ts] = Date().timeIntervalSince1970
        if followed.count > 50 { followed = Dictionary(uniqueKeysWithValues: followed.sorted { $0.value > $1.value }.prefix(30).map { ($0.key, $0.value) }) }
        tick()
        return true
    }
    /// Called as what is shown changes: the thread a link asked for is gone to once it is there.
    private func arrive() {
        guard let wanted = linkTarget else { return }
        if model.threads.contains(where: { $0.id == wanted.id }) { linkTarget = nil; model.go(to: wanted.id) }
        else if Date() > wanted.until { linkTarget = nil; if let url = wanted.url { onUnfollowed?(url) } }
    }
    /// True once the app has begun closing. Read on the main thread only: no new reading, send or file request starts,
    /// and an answer that arrives later is dropped before it reaches the model, the record or the retention rules.
    private(set) var closing = false
    /// A slow cache write for the closing check, called on the Slack queue as the closing flush begins.
    var closingStall: ((String) -> Void)?
    /// Called as the app closes. Nothing new is saved privately from here; private copies are removed and what was
    /// read is kept, each away from the main thread. `run` stops waiting for them at its limit, and the next start
    /// clears whatever private copies are left.
    func prepareClose(_ run: ClosingRun) {
        closing = true
        find.localWork?.cancel(); find.localWork = nil
        find.remoteWork?.cancel(); find.remoteWork = nil
        let temporaryFiles = self.temporaryFiles
        temporaryFiles.close()
        run.add(on: .global(qos: .userInitiated)) { try? temporaryFiles.clear() }
        guard let bridge, cacheFile != nil else { return }
        let stall = closingStall
        run.add(on: queue) { stall?("flush"); bridge.flush() }
    }
    /// The token is kept only after Slack accepts it.
    func connect(token: String, completion: @escaping (String?) -> Void) {
        guard !closing else { return }
        let api = SlackAPI.live(token: token)
        queue.async {
            let result = api.call("auth.test")
            let saved: Bool
            if case .success = result { saved = SlackToken.save(token) } else { saved = false }
            DispatchQueue.main.async {
                guard !self.closing else { return }
                if case .failure(let failure) = result { completion(SlackAPI.message(failure)); return }
                guard saved else { completion("키체인에 저장하지 못했어요."); return }
                self.start(api); completion(nil)
            }
        }
    }
    func disconnect() {
        guard !closing else { return }
        model.findHighlight = nil
        if model.findOpen { model.closeFind() }
        SlackToken.delete()
        // Queued behind any reading under way, so nothing is written back after it.
        if persists { let kept = Self.cacheURL; queue.async { SlackCache.delete(kept) } }
        bridge = nil; api = nil; snapshot = .init(); echoes = []; wanted = []; limits = [:]; sendNotice = nil
        model.thumbs = [:]; model.failedThumbs = []; wantedThumbs = []
        model.changeConnection()
        model.connected = false
        publish()
    }

    func tick() {
        syncSettings()
        guard !closing, let bridge, !syncing else { return }
        syncing = true
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder)
        let writes = persists
        var request = SlackBridge.Request(active: model.selected, open: chatOpen && model.source == .slack,
                                          watch: chatOpen && model.isDdots ? model.ddotsShown : [], scan: roomsToScan(), wanted: wanted, limits: limits,
                                          recent: Dictionary(activity.recent.map { ($0.room + ":" + $0.thread, $0.at) } + followed.map { ($0.key, $0.value) }, uniquingKeysWith: max),
                                          // A character's conversation is read for ddots even when it was taken off the Slack list.
                                          skipped: Ddots.enabled ? model.hidden.subtracting(model.ddotsRooms) : model.hidden, characters: cast)
        request.readRooms = readRooms; request.readThreads = readThreads
        request.localRead = localRead; request.localThreads = localThreads; request.writesRead = persists
        let reading = request
        let oldPresentation = publishCache, excluded = incomingExclusions
        queue.async { [weak self] in
            let result = bridge.sync(reading)
            var presentation = oldPresentation
            presentation.prepare(result.threads, excluding: excluded)
            // Structure only, built and written on the Slack queue.
            if writes, let self, let room = reading.active, self.diagnosticsGate.shouldBuild(room: room, now: ProcessInfo.processInfo.systemUptime) {
                let text = bridge.diagnostics(room: room)
                // Written when it changes, not on every pass.
                if text != self.diagnostics, (try? text.write(to: folder.appendingPathComponent("slack-diagnostics.txt"), atomically: true, encoding: .utf8)) != nil { self.diagnostics = text }
            }
            let read = bridge.takeScanned()
            DispatchQueue.main.async {
                // Rebuilding the list mid-swipe drops frames; the pass lands once the trackpad is still.
                // Syncing stays set meanwhile, so no further pass piles up behind it.
                self?.whenStill(since: ProcessInfo.processInfo.systemUptime) { [weak self] in
                    guard let self else { return }
                    self.syncing = false
                    guard !self.closing, self.bridge === bridge else { return }
                    StallTrace.shared.measure("slack.settle") { self.settle(result) }
                    self.publishCache = presentation
                    self.acceptSnapshot(result)
                    StallTrace.shared.measure("slack.arrive") { self.arrive() }
                    StallTrace.shared.measure("slack.absorb") { self.absorb(scanned: read.messages, through: read.through) }
                }
            }
        }
    }

    /// Runs `work` once no scroll input arrived for a moment, or after two seconds of continuous scrolling at the latest.
    private func whenStill(since: TimeInterval, _ work: @escaping () -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !closing, now - model.scrollInputAt < SlackModel.scrollQuiet, now - since < 2 else { work(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + SlackModel.scrollQuiet) { [weak self] in self?.whenStill(since: since, work) }
    }

    private func sendPage(_ command: String, thread: SlackThread, completion: @escaping () -> Void) {
        guard !closing, let bridge, persists || smokeSends else { completion(); return }
        let bot = model.vault.bot
        queue.async { [weak self] in
            let sent = bridge.beginPage(room: thread.room, thread: thread.ts, bot: bot, command: command)
            DispatchQueue.main.async {
                guard let self, !self.closing, self.bridge === bridge, sent else { completion(); return }
                self.observePage(bridge, attempt: 0, completion: completion)
            }
        }
    }
    private func observePage(_ bridge: SlackBridge, attempt: Int, completion: @escaping () -> Void) {
        let delays: [Double] = [0.4, 0.6, 1, 2] // cumulative: 0.4, 1, 2, 4 seconds
        // Recheck on the main thread when the delay ends; closing is owned by that thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self, !self.closing, self.bridge === bridge else { completion(); return }
            self.queue.async { [weak self] in
                let done = bridge.observePage()
                let result = bridge.current
                DispatchQueue.main.async {
                    guard let self, !self.closing, self.bridge === bridge else { completion(); return }
                    self.snapshot = result; self.publish()
                    if done || attempt == 3 { completion() }
                    else { self.observePage(bridge, attempt: attempt + 1, completion: completion) }
                }
            }
        }
    }

    /// What a send was, captured as it leaves, so a failure is put back where it was going and nowhere else.
    private func sending(_ text: String, room: String, thread: SlackThread?, files: [URL], pick: String?) -> SlackFailedSend {
        SlackFailedSend(workspace: model.workspace, shown: model.selected ?? "", room: room, thread: thread?.id, text: text, files: files, pick: pick, reason: "")
    }
    /// A send that failed waits in the room it was sent from, whatever is being written now. One whose connection
    /// was replaced meanwhile is kept with its own workspace and changes nothing that is shown.
    private func failed(_ attempt: SlackFailedSend, reason: String, current: Bool) {
        var failure = attempt; failure.reason = reason
        model.recordFailure(failure)
        guard current else { return }
        sendNotice = reason + " · 보내지 못한 글은 " + (model.selected == failure.shown ? "입력창 위" : "보낸 방의 입력창 위") + " ‘되살리기’로 다시 쓸 수 있어요."
    }
    /// True while sends go out in a UI check, through a made-up workspace; nothing reaches Slack.
    var smokeSends = false
    private func send(_ text: String, room: String, thread: SlackThread?) {
        guard !closing, let bridge, persists || smokeSends else { return }
        model.pageHold = nil
        // Work out optional channel mentions while the draft and pressed face still stand.
        let post = thread == nil ? model.relayedPost(text) ?? model.hubPost(text) : nil
        let pick = thread == nil && model.ddotsPicked ? model.ddotsTarget : nil
        let revision = thread == nil ? model.beginPost() : model.composeRevision
        let attempt = sending(text, room: room, thread: thread, files: [], pick: pick)
        let echo = Echo(room: room, thread: thread?.ts, message: ChatMessage(id: "slack-pending:\(UUID().uuidString)", fromUser: true, speaker: "", body: post?.shown ?? text, date: Date(), pending: true, profile: ""))
        echoes.append(echo); sendNotice = nil; model.replyTo = nil
        if model.isDdots { model.petWave += 1 }
        publish(); model.requestScroll(thread == nil || model.isDdots ? "slack-bottom" : echo.message.id)
        model.didPublishEcho()
        let outgoing = post?.sent ?? SlackMention.outgoing(text, members: model.members[room] ?? [])
        queue.async { [weak self] in
            let failure = bridge.post(room: room, thread: thread?.ts, text: outgoing)
            let result = bridge.current
            let postedTS = bridge.postedRootTS
            DispatchQueue.main.async {
                guard let self, !self.closing else { return }
                guard self.bridge === bridge else { if let failure { self.failed(attempt, reason: failure, current: false) }; return }
                self.echoes.removeAll { $0.message.id == echo.message.id }
                if let failure {
                    // What is being written now is left alone; the failed message waits where it was going.
                    self.failed(attempt, reason: failure, current: true)
                } else {
                    self.snapshot = result
                    self.didSend(to: thread)
                    if thread == nil { self.model.followPost(room: room, ts: postedTS, revision: revision) }
                }
                self.publish()
            }
        }
    }

    // MARK: Rooms made, filled and put away. Each asks first, then goes to Slack on its queue, never from a UI check.

    /// Asks Slack for the workspace's people on the queue and hands them to `then` on the main thread, with why when they could not be read.
    private func withPeople(_ bridge: SlackBridge, then: @escaping ([SlackBridge.Person], String?) -> Void) {
        queue.async { [weak self] in
            let people = bridge.people()
            DispatchQueue.main.async {
                guard let self, !self.closing, self.bridge === bridge else { return }
                switch people {
                case .success(let list): then(list, nil)
                case .failure(let failure): then([], SlackAPI.message(failure))
                }
            }
        }
    }
    /// Runs one change on the queue, then takes what Slack now holds and says what went wrong, if anything.
    private func change(_ bridge: SlackBridge, title: String, _ work: @escaping () -> String?, done: @escaping () -> Void = {}) {
        queue.async { [weak self] in
            let problem = work()
            let result = bridge.current
            DispatchQueue.main.async {
                guard let self, !self.closing, self.bridge === bridge else { return }
                self.snapshot = result
                done()
                self.publish(); self.tick()
                if let problem { SlackRoomDialogs.tell(title, problem) }
            }
        }
    }

    func createRoom() {
        guard !closing, let bridge, persists else { return }
        withPeople(bridge) { [weak self] people, reason in
            guard let self, let choice = SlackRoomDialogs.create(people: people, unreadable: reason) else { return }
            var made: SlackRoom?
            self.change(bridge, title: "방을 만들지 못했어요", {
                let result = bridge.createRoom(name: choice.name, isPrivate: choice.isPrivate, inviting: choice.users)
                made = result.room
                return result.problem
            }, done: { [weak self] in
                guard let self, let room = made else { return }
                if self.model.hidden.contains(room.id) { self.model.restore(room.id) }
                self.publish()
                self.model.choose(room.id)
            })
        }
    }

    func invite(_ room: String, agentsOnly: Bool = false) {
        guard !closing, let bridge, persists, let place = snapshot.rooms.first(where: { $0.id == room && !$0.direct }) else { return }
        withPeople(bridge) { [weak self] people, reason in
            guard let self else { return }
            let inside = Set((self.snapshot.members[room] ?? []).map(\.user))
            guard let users = SlackRoomDialogs.invite(room: place.name, people: people, unreadable: reason, agentsOnly: agentsOnly, inside: inside),
                  !self.closing, self.bridge === bridge else { return }
            self.change(bridge, title: "초대하지 못했어요") { bridge.invite(room: room, users: users) }
        }
    }

    func archive(_ room: String) {
        guard !closing, let bridge, persists, let name = snapshot.rooms.first(where: { $0.id == room })?.name else { return }
        guard SlackRoomDialogs.confirm("#\(name) 방을 보관할까요?", "슬랙에서 이 방을 보관해요. 글은 그대로 남고, 방 목록 아래 ‘방 추가’의 ‘보관된 방’에서 다시 꺼낼 수 있어요.", button: "보관") else { return }
        change(bridge, title: "보관하지 못했어요", { bridge.archive(room: room) }, done: { [weak self] in
            guard let self, self.model.pins.contains(room) else { return }
            self.model.pin(room, slot: nil)
        })
    }

    func unarchive(_ room: String) {
        guard !closing, let bridge, persists else { return }
        change(bridge, title: "보관을 해제하지 못했어요", { bridge.unarchive(room: room) }, done: { [weak self] in
            guard let self, self.snapshot.rooms.contains(where: { $0.id == room }) else { return }
            if self.model.hidden.contains(room) { self.model.restore(room) }
            self.publish()
            self.model.choose(room)
        })
    }

    func rename(_ room: String) {
        guard !closing, let bridge, persists, let old = snapshot.rooms.first(where: { $0.id == room })?.name,
              let name = SlackRoomDialogs.rename(old), name != old else { return }
        change(bridge, title: "이름을 바꾸지 못했어요", { bridge.rename(room: room, to: name) }, done: { [weak self] in
            // A picture that came with the old name stays with the room.
            guard let self, self.model.roomPictures[room] == nil, let picture = Ddots.roomPictures[old],
                  self.snapshot.rooms.contains(where: { $0.id == room && $0.name != old }), let kept = SlackRoomPictures.save(picture, room: room) else { return }
            self.model.roomPictures[room] = kept
        })
    }

    /// A picture from the Mac for a channel's tab, kept on this Mac only.
    func choosePicture(_ room: String) {
        guard !closing, persists, let url = SlackRoomDialogs.pickPicture() else { return }
        guard let image = NSImage(contentsOf: url), let kept = SlackRoomPictures.save(image, room: room) else {
            SlackRoomDialogs.tell("사진을 넣지 못했어요", "이미지 파일을 읽을 수 없어요."); return
        }
        model.roomPictures[room] = kept
        syncPicture(room)
    }

    /// Slack lets only its own app, and only an admin there, delete a channel; this opens the room in Slack for that.
    func deleteRoom(_ room: String) {
        guard !closing, let name = snapshot.rooms.first(where: { $0.id == room })?.name else { return }
        guard SlackRoomDialogs.confirm("#\(name) 방을 삭제할까요?",
                                       "슬랙은 앱에서 채널을 지우는 것을 허용하지 않아요. 슬랙에서 이 방을 열어 드릴게요. 방 이름을 누르고 ‘설정’ → ‘이 채널 삭제’를 고르세요.\n\n삭제하면 글이 모두 사라지고 되돌릴 수 없어요. 워크스페이스 관리자만 지울 수 있어요. 글을 남기려면 ‘보관’을 쓰세요.",
                                       button: "슬랙에서 열기"),
              let url = SlackRoomDialogs.address(workspace: snapshot.workspace, room: room) else { return }
        NSWorkspace.shared.open(url)
    }

    /// A line of a room as read, for UI checks.
    func snapshotLine(in room: String) -> String? { snapshot.threads[room]?.last?.root.id }
    func addEcho(room: String, thread: String?, message: ChatMessage) { echoes.append(Echo(room: room, thread: thread, message: message)) }
    func removeEcho(_ id: String) { echoes.removeAll { $0.message.id == id } }
    /// Feed a synthetic reply through the same publication path without sending anything.
    func smokeReply(_ message: ChatMessage, to thread: SlackThread) {
        guard !persists, CommandLine.arguments.contains("--ui-smoke-ddots"),
              let index = snapshot.threads[thread.room]?.firstIndex(where: { $0.id == thread.id }) else { return }
        snapshot.threads[thread.room]![index].replies.append(message)
        snapshot.threads[thread.room]![index].replyCount += 1
        snapshot.threads[thread.room]![index].latest = message.date.timeIntervalSince1970
        snapshot.threads[thread.room]![index].latestFromUser = message.fromUser
        publish()
    }


    /// The conversations on screen: the chosen room, or for ddots its channel, else every character's direct conversation.
    private var shownRooms: [String] {
        model.selected == Ddots.room ? model.ddotsShown : (model.selected.map { [$0] } ?? [])
    }
    private var shownThreads: [SlackThread] { Ddots.merged(snapshot.threads, rooms: shownRooms) }

    func didSend(to thread: SlackThread?) {
        if let thread { markRead(thread) }
    }

    private func markRead(_ thread: SlackThread) {
        guard !thread.ts.isEmpty else { return }
        let key = thread.room + ":" + thread.ts
        localThreads[key] = max(localThreads[key] ?? 0, thread.latest)
        // Only channel-flow messages in this thread advance the room receipt.
        let flow = [thread.root] + thread.replies.filter(\.slackBroadcast)
        localRead[thread.room] = max(localRead[thread.room] ?? 0, flow.map { $0.date.timeIntervalSince1970 }.max() ?? 0)
    }

    /// Marks every notification in the room read, as pressing each bell would.
    func readAll() {
        let ids = Set(model.notices.filter { $0.id == SlackNotice.alertID }.flatMap(\.threads))
        for thread in shownThreads where ids.contains(thread.id) { dismissed[thread.id] = thread.latest; markRead(thread) }
        if persists { UserDefaults.standard.set(retention.filtered(dismissed), forKey: "slackDismissed") }
        publish()
    }

    /// Opens the thread a pet bubble was about.
    func reveal(_ messageID: String, query: String = "") {
        for (room, threads) in snapshot.threads {
            guard let thread = threads.first(where: { $0.messages.contains { $0.id == messageID } }) else { continue }
            markRead(thread)
            // What a character said in its own conversation is read in ddots, where everyone's is.
            model.source = .slack; model.show(room: model.ddotsShown.contains(room) ? Ddots.room : room)
            model.open.insert(thread.id); model.focusThread = thread.id
            let term = SlackSearch.normalized(query)
            model.findHighlight = term.isEmpty ? nil : (thread.id, term)
            recordReveal = thread.id
            publish(); model.requestScroll(messageID)
            return
        }
    }

    private func cleanupUploadedOriginals() {
        guard !closing, !receiptBusy, let api, let bridge else { return }
        let enabled = UserDefaults.standard.object(forKey: ShrimpReceipts.setting) == nil || UserDefaults.standard.bool(forKey: ShrimpReceipts.setting)
        guard enabled else { return }
        let threads = snapshot.threads.values.flatMap { $0 }, me = snapshot.me
        let bot = model.vault.bot, worker = receiptWorker
        receiptBusy = true
        fileQueue.async { [weak self] in
            let stillEnabled = UserDefaults.standard.object(forKey: ShrimpReceipts.setting) == nil || UserDefaults.standard.bool(forKey: ShrimpReceipts.setting)
            let outcome = worker.process(threads: threads, me: me, bot: bot, api: api, enabled: stillEnabled)
            DispatchQueue.main.async {
                guard let self, !self.closing, self.bridge === bridge else { return }
                self.receiptBusy = false
                guard !outcome.deleted.isEmpty || outcome.notice != nil else { return }
                self.removedUploadIDs.formUnion(outcome.deleted)
                for id in outcome.deleted { self.model.thumbs[id] = nil; self.wantedThumbs.remove(id) }
                if let notice = outcome.notice { self.sendNotice = notice }
                self.publish()
            }
        }
    }

    private var publishCache = SlackPublishCache()
    private var roomNoticeCache: [String: (signature: Int, notice: SlackModel.RoomNotice)] = [:]
    private var unreadCache = SlackUnreadCache()
    private var noticeMemo = SlackNoticeMemo()
    private var incomingExclusions: Set<String> {
        model.muted.union(model.hidden).union(model.muted.contains(Ddots.room) ? Set(model.ddotsShown) : [])
    }
    private(set) var publishCount = 0
    private(set) var publishSections: [String: Double] = [:]
    @discardableResult
    func acceptSnapshot(_ result: SlackBridge.Snapshot, prepared: SlackPublishCache? = nil) -> Bool {
        guard !closing, result != snapshot else { return false }
        StallTrace.shared.changed(result.changedFields(from: snapshot))
        if let prepared { publishCache = prepared }
        snapshot = result
        publish()
        return true
    }

    func publish() {
        DdotsConfig.shared.refresh(force: false)
        // Once closing has begun what is shown stays as it is, and nothing it would set off (saving, retention) starts.
        guard !closing else { return }
        publishCount += 1
        let publishStart = StallTrace.now
        var sectionStart = publishStart
        var sections: [String: Double] = [:]
        func section(_ name: String) {
            let end = StallTrace.now
            sections[name] = (end-sectionStart)*1000
            StallTrace.shared.record("publish." + name, since: sectionStart)
            StallTrace.shared.detail("publish." + name, milliseconds: (end-sectionStart)*1000)
            sectionStart = end
        }
        defer {
            sections["total"] = (StallTrace.now-publishStart)*1000
            publishSections = sections
            StallTrace.shared.record("slack.publish", since: publishStart)
        }
        // Apply memory-only deletion tombstones even if a later poll still has old file metadata.
        if !removedUploadIDs.isEmpty {
            func scrub(_ message: ChatMessage) -> ChatMessage {
                var message = message
                for i in message.files.indices where removedUploadIDs.contains(message.files[i].id) {
                    message.files[i].deleted = true; message.files[i].url = ""; message.files[i].thumb = ""
                }
                return message
            }
            for room in Array(snapshot.threads.keys) {
                snapshot.threads[room] = snapshot.threads[room]?.map { thread in
                    var thread = thread; thread.root = scrub(thread.root); thread.replies = thread.replies.map(scrub); return thread
                }
            }
        }
        cleanupUploadedOriginals()
        // Where the reader is before anything changes. The view is put back there afterwards unless this pass
        // itself asks for a place, so lines that fill in above never slide what is being read off the screen.
        section("cleanup")
        let place = model.place()
        var grew = false
        let ddots = Ddots.enabled ? Ddots.members(Ddots.rooms(snapshot.rooms, members: snapshot.members), characters: cast) : []
        if model.ddotsMembers != ddots { model.ddotsMembers = ddots }
        // The channel is part of ddots, not a room of its own in the list.
        let hub = ddots.isEmpty ? nil : Ddots.hub(snapshot.rooms)
        if model.ddotsHub != hub { model.ddotsHub = hub }
        // The channel is no tab of its own, so a hiding or muting left on it from when it was could never be taken off again.
        if let hub, model.hidden.contains(hub) || model.muted.contains(hub) {
            model.hidden.remove(hub); model.muted.remove(hub)
            if persists {
                UserDefaults.standard.set(Array(model.hidden).sorted(), forKey: "slackHidden")
                UserDefaults.standard.set(Array(model.muted).sorted(), forKey: "slackMuted")
            }
        }
        retention.update(model.unkept, hidden: model.hidden)
        let together = model.ddotsShown
        if model.workspace != snapshot.workspace { model.workspace = snapshot.workspace }
        section("membership")
        publishCache.prepare(snapshot.threads, excluding: incomingExclusions)
        var latest = publishCache.latest
        // ddots goes by the newest line in any of its characters' conversations.
        latest[Ddots.room] = together.compactMap { latest[$0] }.max { $0.date < $1.date }
        if model.latest != latest { model.latest = latest }
        section("latest")
        let listed = snapshot.rooms.filter { !model.hidden.contains($0.id) && $0.id != hub }
        // With ddots on, direct conversations go behind one tab, so the list is ddots, the channels, then that tab.
        let stacked = Ddots.enabled ? Ddots.stacked(listed, pins: model.pins, members: snapshot.members) : []
        if model.stacked != stacked { model.stacked = stacked }
        let behind = Set(stacked.map(\.id))
        // The rooms in each section trade places among themselves as messages come; a room changes section only when dragged.
        let free = listed.filter { !behind.contains($0.id) }
        // Like the direct conversations' tab, the sections come with ddots; without it every room is in the one list.
        // A section of two rooms or more folds behind its tab; one room is shown as itself; an empty one keeps its tab to drop into.
        var rooms: [SlackRoom] = [], groups: [Int: [SlackRoom]] = [:], rowZones: [String: Int] = [:]
        func addSection(_ zone: Int, tab: SlackRoom, inside: [SlackRoom], open: Bool) {
            let shown = inside.count == 1 ? inside : [tab] + (open ? inside : [])
            rooms += shown
            for room in shown { rowZones[room.id] = zone }
        }
        if Ddots.enabled {
            for zone in model.sections {
                let inside = SlackRoomOrder.sorted(free.filter { model.section(of: $0.id) == zone }, pins: model.pins, latest: latest.mapValues(\.date))
                groups[zone] = inside
                addSection(zone, tab: SlackRoom(id: Ddots.group(zone), name: model.groupName(zone)), inside: inside, open: model.groupsOpen.contains(zone))
            }
            // The direct conversations are the last section, under the channels.
            if !stacked.isEmpty { addSection(Ddots.directZone, tab: SlackRoom(id: Ddots.stack, name: model.groupName(Ddots.directZone), direct: true), inside: stacked, open: model.stackOpen) }
        } else {
            rooms = SlackRoomOrder.sorted(free, pins: model.pins, latest: latest.mapValues(\.date))
        }
        if model.groups != groups { model.groups = groups }
        // ddots keeps the first place, above every pinned room.
        if !ddots.isEmpty { rooms.insert(SlackRoom(id: Ddots.room, name: Ddots.roomName), at: 0); rowZones[Ddots.room] = 0 }
        if model.rowZones != rowZones { model.rowZones = rowZones }
        let hiddenRooms = snapshot.rooms.filter { model.hidden.contains($0.id) && $0.id != hub }
        if model.hiddenRooms != hiddenRooms { model.hiddenRooms = hiddenRooms }
        if model.archivedRooms != snapshot.archived { model.archivedRooms = snapshot.archived }
        if model.rooms != rooms { model.rooms = rooms }
        section("roomOrder")
        let hits = SlackSearch.hits(model.query, in: snapshot.threads)
        if model.hits != hits { model.hits = hits }
        section("search")
        // ddots appears once the characters' names are known; until then the choice of it is kept.
        let waiting = Ddots.enabled && model.selected == Ddots.room && cast.isEmpty
        // A room folded away behind the stack is still a room that can be shown; the stack itself is not.
        let choosable = rooms.filter { !Ddots.isTab($0.id) } + (model.stackOpen || stacked.count < 2 ? [] : stacked)
            + model.sections.filter { !model.groupsOpen.contains($0) && (groups[$0]?.count ?? 0) >= 2 }.flatMap { groups[$0] ?? [] }
        if !choosable.isEmpty, !waiting, !choosable.contains(where: { $0.id == model.selected }) { model.show(room: choosable.first?.id) }
        let onScreen = shownRooms
        let shown = Ddots.merged(snapshot.threads, rooms: onScreen)
        let confirmed = Set(self.confirmed.keys)
        var notices = noticeMemo.items(shown, dismissed: dismissed, confirmed: confirmed)
        let now = Date().timeIntervalSince1970
        var changedRead = false
        // A room seen for the first time starts as read, so connecting does not flood the badge.
        for room in snapshot.threads.keys where lastRead[room] == nil { lastRead[room] = now; changedRead = true }
        if chatOpen, model.source == .slack {
            for thread in shown where thread.latest > (lastRead[thread.room] ?? 0) { markRead(thread) }
            for room in onScreen { if let newest = snapshot.threads[room]?.map(\.latest).max(), newest > (lastRead[room] ?? 0) { lastRead[room] = newest; changedRead = true } }
        }
        if changedRead && persists { UserDefaults.standard.set(retention.filtered(lastRead), forKey: "slackLastRead") }
        readRooms = []; readThreads = []
        // Threads read on another Mac of this account count as read here too.
        let threadRead = syncedThreadRead.isEmpty ? snapshot.threadRead : snapshot.threadRead.merging(syncedThreadRead, uniquingKeysWith: max)
        var unread: [String: Int] = [:]
        for (room, threads) in snapshot.threads where !model.hidden.contains(room) || together.contains(room) {
            var count = 0
            for thread in threads {
                let fresh = unreadCache.count(thread, lastRead: lastRead[room] ?? now, roomRead: snapshot.roomRead[room] ?? 0, threadRead: threadRead)
                count += fresh
                if fresh > 0 {
                    readRooms.insert(room)
                    if thread.replyCount > 0 { readThreads.insert(room + ":" + thread.ts) }
                }
            }
            if count > 0 { unread[room] = count }
        }
        // Shown on the ddots tab; the pet's badge counts each character's room once and leaves this sum out.
        let waitingThere = together.reduce(0) { $0 + (unread[$1] ?? 0) }
        if waitingThere > 0 { unread[Ddots.room] = waitingThere }
        unreadCache.retain(Set(snapshot.threads.values.flatMap { $0.map(\.id) }))
        if model.unread != unread { model.unread = unread }

        section("unread")
        var threads = shown
        for echo in echoes where onScreen.contains(echo.room) {
            if let thread = echo.thread, let index = threads.firstIndex(where: { $0.ts == thread && $0.room == echo.room }) {
                threads[index].replies.append(echo.message); threads[index].replyCount += 1
                if model.isDdots { threads[index].latest = max(threads[index].latest, echo.message.date.timeIntervalSince1970) }
            } else if echo.thread == nil {
                threads.append(SlackThread(id: echo.message.id, room: echo.room, ts: "", root: echo.message, replies: [], replyCount: 0, loaded: true, latest: now, latestFromUser: true))
            }
        }
        var ownChanged = false
        for (key, stamp) in snapshot.ownRead where stamp > (ownRead[key] ?? 0) { ownRead[key] = stamp; ownChanged = true }
        if ownRead.count > 300 {
            ownRead = Dictionary(uniqueKeysWithValues: ownRead.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }); ownChanged = true
        }
        if ownChanged && persists { UserDefaults.standard.set(retention.filtered(ownRead), forKey: "slackOwnRead") }
        let remotelyRead = SlackUnread.quiet(shown, notices: notices, roomRead: snapshot.roomRead, threadRead: snapshot.threadRead, threadUnfollowed: snapshot.threadUnfollowed, remoteQuiet: remoteQuiet, ownRead: ownRead)
        if !remotelyRead.isEmpty {
            for thread in remotelyRead { remoteQuiet[thread.id] = thread.latest; dismissed[thread.id] = thread.latest }
            if dismissed.count > 300 { dismissed = Dictionary(uniqueKeysWithValues: dismissed.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
            if persists { UserDefaults.standard.set(retention.filtered(dismissed), forKey: "slackDismissed") }
            notices = noticeMemo.items(shown, dismissed: dismissed, confirmed: confirmed)
        }
        let pollingBells = Set(notices.filter(SlackNotice.hasBell).flatMap(\.threads))
        for thread in shown where pollingBells.contains(thread.id) {
            readRooms.insert(thread.room)
            if thread.replyCount > 0 { readThreads.insert(thread.room + ":" + thread.ts) }
        }
        var roomNotices: [String: SlackModel.RoomNotice] = [:]
        func roomNotice(_ items: [SlackNoticeItem]) -> SlackModel.RoomNotice {
            SlackModel.RoomNotice(alerts: items.first { $0.id == SlackNotice.alertID }?.threads.count ?? 0,
                                  questions: items.filter { $0.id.hasPrefix(SlackNotice.questionID + ":") }.reduce(0) { $0 + $1.threads.count })
        }
        // The tab on screen reuses its own notice; the others are read from what the last pass brought.
        // Every pass reaches here, about once a second; working out a room's notices again only when its threads,
        // the read marks or the hour changed keeps that pass from walking every room's every message (140ms on 1.6.79).
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        var seen = Set<String>()
        for tab in model.rooms.map(\.id) + model.stacked.map(\.id) + model.grouped.map(\.id) + (Ddots.enabled ? [Ddots.room] : []) where !Ddots.isTab(tab) && roomNotices[tab] == nil {
            seen.insert(tab)
            let notice: SlackModel.RoomNotice
            if tab == model.selected { notice = roomNotice(notices) }
            else {
                let threads = tab == Ddots.room ? Ddots.merged(snapshot.threads, rooms: model.ddotsShown) : snapshot.threads[tab] ?? []
                var hasher = Hasher()
                hasher.combine(hour); hasher.combine(dismissed.count); hasher.combine(confirmed.count); hasher.combine(threads.count)
                for thread in threads {
                    hasher.combine(thread.id); hasher.combine(thread.latest); hasher.combine(thread.replyCount)
                    hasher.combine(thread.loaded); hasher.combine(thread.latestFromUser); hasher.combine((dismissed[thread.id] ?? 0))
                }
                let signature = hasher.finalize()
                if let cached = roomNoticeCache[tab], cached.signature == signature { notice = cached.notice }
                else {
                    notice = roomNotice(SlackNotice.items(threads, dismissed: dismissed, confirmed: confirmed))
                    roomNoticeCache[tab] = (signature, notice)
                }
            }
            if notice != SlackModel.RoomNotice() { roomNotices[tab] = notice }
        }
        roomNoticeCache = roomNoticeCache.filter { seen.contains($0.key) }
        // Folded, the DM tab speaks for the conversations behind it.
        let folded = model.stacked.compactMap { roomNotices[$0.id] }
        if !folded.isEmpty { roomNotices[Ddots.stack] = SlackModel.RoomNotice(alerts: folded.reduce(0) { $0 + $1.alerts }, questions: folded.reduce(0) { $0 + $1.questions }) }
        // So does each group's tab for the rooms in it.
        for zone in model.sections {
            let inside = (model.groups[zone] ?? []).compactMap { roomNotices[$0.id] }
            if !inside.isEmpty { roomNotices[Ddots.group(zone)] = SlackModel.RoomNotice(alerts: inside.reduce(0) { $0 + $1.alerts }, questions: inside.reduce(0) { $0 + $1.questions }) }
        }
        if model.roomNotices != roomNotices { SlackModel.animated { model.roomNotices = roomNotices } }
        if model.confirmed != confirmed { model.confirmed = confirmed }
        if model.notices != notices { SlackModel.animated { model.notices = notices } }
        var bells: [String: Bool] = [:]
        // A thread marked read keeps a quiet bell until something newer happens, unless its status settled it.
        for thread in shown where (dismissed[thread.id] ?? -.infinity) >= thread.latest && SlackNotice.hermesState(thread) != .working && !noticeMemo.isSettled(thread, confirmed: confirmed) { bells[thread.id] = false }
        for item in notices where SlackNotice.hasBell(item) { for id in item.threads { bells[id] = true } }
        if model.bells != bells { SlackModel.animated { model.bells = bells } }
        section("notices")
        // What the record keeps from before Slack's own reach goes ahead of what Slack shows.
        // Leaving a room lets go of what "이전 글 보기" read further back in it; Slack's next reading of it is the usual size.
        if shownRoom != model.selected { letGoOlderMonths(); limits = limits.filter { onScreen.contains($0.key) } }
        threads = Ddots.joined(live: threads, kept: keptThreads(for: onScreen))
        if !deletedThreads.isEmpty { threads.removeAll { deletedThreads[$0.id] != nil } }
        var removing = snapshot.removing
        for id in askedDelete where removing[id] == nil { removing[id] = SlackBridge.Removal(done: 0, total: 0) }
        if model.removing != removing { model.removing = removing }
        if model.isDdots { threads = Ddots.byActivity(threads) }
        if shownRoom != model.selected { recordWindow.reset() }
        recordWindowThreads = model.isDdots ? threads : []
        model.approvalThreads = model.isDdots && readsRecord(onScreen) ? threads : nil
        if model.isDdots && readsRecord(onScreen) {
            let ids = recordWindow.visibleIDs(threads.map(\.id), revealing: recordReveal ?? find.target?.thread ?? linkTarget?.id)
            threads = Array(threads.suffix(ids.count))
        }
        recordReveal = nil
        let previous = Dictionary(model.threads.map { ($0.id, $0.latest) }, uniquingKeysWith: { first, _ in first })
        let following = Set([model.picked, model.replyTo, model.target?.id].compactMap { $0 }).union(model.open)
        let active = model.isDdots && shownRoom == model.selected ? threads.last(where: { !$0.ts.isEmpty }).flatMap { thread in
            previous[thread.id].flatMap { thread.latest > $0 ? thread.id : nil }
        } : nil
        let first = model.threads.isEmpty && !threads.isEmpty
        if model.threads != threads {
            // Older lines came in ahead of ones already shown: from the record, or a thread Slack listed late.
            let had = Set(model.threads.map(\.id))
            if let last = threads.lastIndex(where: { had.contains($0.id) && !$0.ts.isEmpty }) {
                grew = threads[..<last].contains { !had.contains($0.id) && !$0.ts.isEmpty }
            }
            model.threads = threads
        }
        if shownRoom != model.selected { shownSince = Date(); shownScrolls = model.userScrolls }
        if shownRoom != model.selected || first { shownRoom = model.selected; model.scrollToEntry() }
        // A room Slack refuses has nothing to wait for; it shows what it has, with the reason above it.
        let loaded = !onScreen.isEmpty && onScreen.allSatisfy { snapshot.threads[$0] != nil || snapshot.problems[$0] != nil }
        // ddots fills in one character at a time, so it goes to the newest line once more when the last of them is in.
        // Replies make the threads taller after that, so it goes there again when they are in, if that is soon.
        // A thread the user has opened by then is where they are reading, and the room is not taken from under it.
        let whole = loaded && threads.allSatisfy(\.loaded)
        // Only while nothing else has asked for a place since entering: a click, a search or a link keeps its own.
        if loaded, model.userScrolls == shownScrolls, model.entryHolds, find.target == nil, linkTarget == nil,
           landed.room != model.selected || (whole && !landed.whole && model.open.isEmpty && Date().timeIntervalSince(shownSince) < Self.settleWindow) {
            model.scrollToEntry()
        }
        if loaded { landed = (model.selected, landed.room == model.selected ? landed.whole || whole : whole) }
        let loading = (connected && !loaded) || (loadingKept && readsRecord(onScreen))
        if model.loading != loading { model.loading = loading }
        let more = readsRecord(onScreen) ? (keptEarlier || (model.isDdots && recordWindowThreads.count > threads.count)) : onScreen.contains { snapshot.more[$0] ?? false }
        if model.hasOlder != more { model.hasOlder = more }
        var notice = DdotsConfig.shared.status.isEmpty ? sendNotice : DdotsConfig.shared.status
        if notice == nil, case .failed(let reason) = snapshot.status { notice = reason }
        if notice == nil { notice = onScreen.compactMap { snapshot.problems[$0] }.first }
        if notice == nil, onScreen.contains(where: { model.ddotsRooms.contains($0) }) { notice = recordNotice }
        if model.notice != notice { model.notice = notice }
        // Rooms whose member list could not be read fall back to whoever has spoken there.
        section("threads")
        var members = snapshot.members
        for (room, threads) in snapshot.threads where members[room] == nil {
            var seen = Set<String>()
            members[room] = SlackMember.ordered(threads.flatMap(\.messages).filter { !$0.fromUser }.map { SlackMember(profile: $0.profile, name: $0.speaker) }.filter { seen.insert($0.id).inserted })
        }
        // The stack shows the face of whoever each conversation behind it is with.
        if !stacked.isEmpty { members[Ddots.stack] = stacked.compactMap { members[$0.id]?.first } }
        // A group without a picture of its own shows a face from each room in it.
        for zone in model.sections {
            var seen = Set<String>()
            members[Ddots.group(zone)] = (model.groups[zone] ?? []).compactMap { members[$0.id]?.first }.filter { seen.insert($0.id).inserted }
        }
        // The ddots tab shows its characters' faces the way a room shows its members'.
        // One face stands for the room: the character new posts go to by default.
        if !ddots.isEmpty {
            let face = ddots.first { $0.profile == Ddots.defaultTarget } ?? ddots[0]
            members[Ddots.room] = [SlackMember(profile: face.profile, name: face.name)]
        }
        if model.members != members { model.members = members }
        section("members")
        var typing: [String: [TypingIndicator]] = [:]
        for writer in activity.writers {
            guard let thread = snapshot.threads[writer.room]?.first(where: { $0.ts == writer.thread }) else { continue }
            // The lease outlives the reply by a moment; once the answer is in the thread the dots go away.
            if thread.messages.contains(where: { !$0.fromUser && $0.profile == writer.profile && $0.date.timeIntervalSince1970 >= writer.since }) { continue }
            typing[thread.id, default: []].append(TypingIndicator(id: "slack-typing:" + writer.profile + ":" + thread.id, speaker: writer.name, profile: writer.profile))
        }
        if model.typing != typing { model.typing = typing }
        section("typing")
        // A muted room raises no bubble over the pet.
        // Muting ddots quiets its characters' rooms too.
        let said = together.flatMap { snapshot.threads[$0] ?? [] }.flatMap(\.messages).filter { !$0.fromUser && !SlackText.isThinking($0.body) }.map(\.date).max()
        // The pet hops when a character's answer lands, not for what was already there when the rooms were first read.
        if let said, let before = ddotsNewest, said > before { model.petHop += 1 }
        if let said { ddotsNewest = max(said, ddotsNewest ?? said) }
        incoming = publishCache.incoming
        section("incoming")
        let mapping = model.ddotsMembers.map { $0.profile + ":" + $0.room }.sorted().joined(separator: "|") + (model.ddotsHub ?? "")
        if mapping != retentionMapping {
            retentionMapping = mapping
            retention.map(profiles: Dictionary(model.ddotsMembers.map { ($0.profile, $0.room) }, uniquingKeysWith: { first, _ in first }), hub: model.ddotsHub)
            changeRetention()
        }
        record()
        section("record")
        // Following the newest line keeps following; a reader further up stays put while older lines fill in above.
        if model.pageHold != nil { model.restorePage() }
        else if let place, model.scrollRevision == place.revision {
            if let active, place.fromBottom <= SlackModel.followDistance || following.contains(active) {
                model.requestScroll("slack-bottom")
            } else if place.fromBottom <= SlackModel.followDistance || grew { model.keep(place) }
        }
        arriveFind()
        refreshFind()
        section("scrollFind")
        onChange?()
        section("onChange")
    }
}

// MARK: Files
extension SlackController {
    func roomName(of message: ChatMessage) -> String {
        snapshot.rooms.first { message.id.hasPrefix("slack:\($0.id):") }?.name ?? model.room?.name ?? "Slack"
    }

    /// Pictures are fetched once and kept in memory only.
    func loadThumb(_ file: ChatFile) {
        guard !closing, !file.isDeleted, file.isImage, model.thumbs[file.id] == nil, wantedThumbs.insert(file.id).inserted,
              let url = URL(string: file.thumb.isEmpty ? file.url : file.thumb) else { return }
        let api = self.api
        fileQueue.async { [weak self] in
            var data: Data?
            if url.isFileURL { data = try? Data(contentsOf: url) }
            else if case .success(let fetched)? = api?.raw(url, nil) { data = fetched }
            guard let image = data.flatMap(NSImage.init(data:)) else {
                DispatchQueue.main.async { if self?.closing == false { self?.model.failedThumbs.insert(file.id) } }
                return
            }
            DispatchQueue.main.async {
                guard let self, !self.closing else { return }
                if self.model.thumbs.count >= 200 { self.model.thumbs = [:]; self.wantedThumbs = [file.id] }
                self.model.thumbs[file.id] = image
            }
        }
    }

    /// Saves the file into the room's folder in the shared store, then opens it. A file saved before is just opened.
    func open(_ file: ChatFile, in message: ChatMessage) {
        guard !closing, !file.isDeleted else { return }
        let roomID = message.id.split(separator: ":", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
        if retention.excludes(roomID) { openTemporary(file); return }
        if let local = URL(string: file.url), local.isFileURL { show(local); return }
        let room = roomName(of: message)
        // A file from a character's conversation has its place in the ddots record, the same place it is fetched to on its own.
        let inHub = model.ddotsHub.flatMap { hub in message.id.hasPrefix("slack:\(hub):") ? snapshot.threads[hub]?.first { $0.ts == message.sessionID } : nil }
        let owner = model.ddotsMembers.first { message.id.hasPrefix("slack:\($0.room):") } ?? inHub.flatMap(model.ddotsOwner)
        func inRecord(id: String) -> URL? {
            guard let owner, let archive else { return nil }
            return archive.fileURL(DdotsArchive.filePath(name: owner.name, file: file.name, id: id, date: message.date))
        }
        // Only the Mac that keeps the record puts files into it; another Mac opens what is there and saves the rest beside it.
        let recorded = keepsRecord ? inRecord(id: file.id) : nil
        let target = recorded ?? store.destination(room: room, name: file.name, date: message.date, id: file.id)
        // A file saved before names carried Slack's ID is opened from where it was put then.
        let places = [target, inRecord(id: file.id), inRecord(id: ""), store.destination(room: room, name: file.name, date: message.date)].compactMap { $0 }
        if let there = places.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { show(there); return }
        guard let url = URL(string: file.url), let api, !model.busyFiles.contains(file.id) else { return }
        if file.size > SlackFileStore.largest { sendNotice = "200MB보다 큰 파일은 슬랙에서 직접 받아 주세요."; publish(); return }
        model.busyFiles.insert(file.id); sendNotice = nil
        let store = self.store, retention = self.retention, temporaryFiles = self.temporaryFiles
        fileQueue.async { [weak self] in
            var saved: URL?, problem: String?
            switch api.raw(url, nil) {
            case .failure(let failure): problem = SlackAPI.message(failure)
            case .success(let data):
                do {
                    try retention.locked {
                    if retention.excludes(roomID) { saved = try temporaryFiles.save(data, name: file.name) }
                    else if let recorded {
                        try FileManager.default.createDirectory(at: recorded.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: recorded, options: .atomic); saved = recorded
                    } else { saved = try store.save(data, room: room, name: file.name, date: message.date, id: file.id) }
                    }
                } catch { problem = "파일을 저장하지 못했어요. \(error.localizedDescription)" }
            }
            DispatchQueue.main.async {
                guard let self, !self.closing else { return }
                self.model.busyFiles.remove(file.id)
                if let saved {
                    if saved.path.hasPrefix(temporaryFiles.root.path + "/") { self.showTemporary(saved) } else { self.show(saved) }
                } else { self.sendNotice = problem }
                self.publish()
            }
        }
    }
    private func show(_ url: URL) {
        guard !closing else { return }
        lastSaved = url
        if persists, onShowFile?(url) != true { NSWorkspace.shared.open(url) }
    }

    func pickFiles() {
        guard !closing else { return }
        let panel = NSOpenPanel()
        // The conversation floats above ordinary windows, so the chooser has to float above it.
        panel.level = .modalPanel
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "보낼 사진이나 파일을 고르세요."; panel.prompt = "첨부"
        if FileManager.default.fileExists(atPath: store.root.path) { panel.directoryURL = store.root }
        picking = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.picking = false
            guard !self.closing else { return }
            if response == .OK { self.model.attach(panel.urls) }
            self.onPicked?()
        }
    }

    static func localFile(_ url: URL) -> ChatFile {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
        return ChatFile(id: "local:" + url.path, name: url.lastPathComponent, mimetype: type, size: size, url: url.absoluteString, thumb: url.absoluteString)
    }

    func sendFiles(_ text: String, room: String, thread: SlackThread?, files: [URL]) {
        guard !closing, let bridge, persists || smokeSends else { return }
        model.pageHold = nil
        let post = thread == nil ? model.hubPost(text) : nil
        let pick = thread == nil && model.ddotsPicked ? model.ddotsTarget : nil
        let revision = thread == nil ? model.beginPost() : model.composeRevision
        let attempt = sending(text, room: room, thread: thread, files: files, pick: pick)
        var message = ChatMessage(id: "slack-pending:\(UUID().uuidString)", fromUser: true, speaker: "", body: post?.shown ?? text, date: Date(), pending: true, profile: "")
        message.files = files.map(Self.localFile)
        let echo = message.id
        addEcho(room: room, thread: thread?.ts, message: message)
        model.replyTo = nil; sendNotice = nil
        publish(); model.requestScroll(thread == nil || model.isDdots ? "slack-bottom" : echo)
        model.didPublishEcho()
        let outgoing = post?.sent ?? SlackMention.outgoing(text, members: model.members[room] ?? [])
        let store = self.store, name = snapshot.rooms.first { $0.id == room }?.name ?? "Slack"
        let recordsRoom = keepsRecord && model.ddotsRooms.contains(room)
        let retention = self.retention
        queue.async { [weak self] in
            // Every file's size is checked before any is read; then they are read and sent one at a time.
            let failure: String?
            switch SlackOutgoingFile.prepare(files) {
            case .failure(let problem): failure = problem.message
            case .success(let payload): failure = bridge.upload(room: room, thread: thread?.ts, text: outgoing, files: payload)
            }
            let uploadedIDs = failure == nil ? bridge.uploadedFileIDs : []
            // What was sent is kept beside what was received. In a character's conversation the record fetches it like any other file.
            retention.locked {
                if failure == nil, !recordsRoom, !retention.excludes(room) { for url in files { _ = try? store.keep(copyOf: url, room: name, date: message.date) } }
            }
            DispatchQueue.main.async {
                guard let self, !self.closing else { return }
                guard self.bridge === bridge else { if let failure { self.failed(attempt, reason: failure, current: false) }; return }
                self.removeEcho(echo)
                if let failure {
                    self.failed(attempt, reason: failure, current: true)
                } else {
                    self.didSend(to: thread)
                    if thread == nil { self.model.followPost(room: room, ts: nil, files: uploadedIDs, revision: revision) }
                }
                self.publish(); self.tick()
            }
        }
    }
}
