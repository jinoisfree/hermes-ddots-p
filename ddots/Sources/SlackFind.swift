import AppKit

/// Search work has its own queue and generation, independent of the conversation's reply budget.
final class SlackFind {
    // Network responses must not hold up local matching while a new query is being typed.
    let queue = DispatchQueue(label: AppIdentity.bundleID + ".slack.search", qos: .utility, attributes: .concurrent)
    struct Input: Equatable {
        var generation: UUID
        var live: Int
        var recorded: Int
        var remote: Int
        var hidden: Set<String>
    }
    var input: Input?
    var liveRevision = 0
    var recordedRevision = 0
    var remoteRevision = 0
    var matching = false
    var generation = UUID()
    var session = UUID()
    var localWork: DispatchWorkItem?
    var remoteWork: DispatchWorkItem?
    var recorded: [SlackThread] = [] { didSet { if recorded != oldValue { recordedRevision += 1 } } }
    var remote: [SlackThread] = [] { didSet { if remote != oldValue { remoteRevision += 1 } } }
    var lines: [DdotsLine] = []
    /// The months read so far, oldest first. Months are read newest first, so every month after the first of these is read too.
    var months: [String] = []
    /// Every month the record holds, and those still to be read, newest first.
    var known: [String] = []
    var pending: [String] = []
    /// What could not be read, so the results can say they may be missing something.
    var unreadable = 0, damaged = 0, away = false, unlisted = 0
    var loadingArchive = false
    var loadingRemote = false
    var target: (thread: String, message: String, until: Date)?
    /// A wait before each batch, so UI checks can see results arrive a batch at a time. Zero outside them.
    static var pause: TimeInterval = 0
}

extension SlackController {
    func changeFind() {
        guard !closing else { return }
        find.generation = UUID(); find.input = nil; find.matching = false
        find.localWork?.cancel(); find.remoteWork?.cancel()
        find.remote = []; find.loadingRemote = false
        model.findNotice = nil; model.findGroups = []; model.findSelection = 0
        guard model.findOpen else {
            find.session = UUID(); find.recorded = []; find.lines = []; find.months = []; find.known = []; find.pending = []; find.loadingArchive = false
            find.unreadable = 0; find.damaged = 0; find.away = false; find.unlisted = 0
            model.findGaps = []; model.findProgress = nil; model.findBusy = false
            return
        }
        let generation = find.generation
        let local = DispatchWorkItem { [weak self] in
            guard let self, self.find.generation == generation else { return }; self.refreshFind()
        }
        find.localWork = local; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: local)
        guard !SlackSearch.normalized(model.findQuery).isEmpty else { model.findBusy = false; return }
        model.findBusy = true
        let remote = DispatchWorkItem { [weak self] in self?.searchServer(generation: generation) }
        find.remoteWork = remote; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: remote)
    }
    /// How many months of the record are read at a time. What each batch finds is shown before the next is read.
    static let findBatch = 2
    func openFind() {
        guard !closing else { return }
        find.session = UUID()
        changeFind()
        guard let archive else { return }
        let session = find.session
        find.loadingArchive = true
        fileQueue.async { [weak self] in
            let list = archive.listMonths()
            DispatchQueue.main.async {
                guard let self, !self.closing, self.model.findOpen, self.find.session == session else { return }
                self.find.known = list.months; self.find.pending = list.months.reversed(); self.find.away = list.away; self.find.unlisted = list.unlisted
                self.readFind(archive, session: session)
            }
        }
    }
    /// Reads the next few months, newest first, and shows what they hold. Closing the search, opening it again or
    /// another record stops the reading: a batch already on its way is dropped and no further one is asked for.
    private func readFind(_ archive: DdotsArchive, session: UUID) {
        guard !closing, model.findOpen, find.session == session, self.archive?.root == archive.root else { return }
        showFindGaps()
        guard !find.pending.isEmpty else { find.loadingArchive = false; showFindGaps(); refreshFind(); return }
        let batch = Array(find.pending.prefix(Self.findBatch)), members = model.ddotsMembers, hub = model.ddotsHub
        find.pending.removeFirst(batch.count)
        fileQueue.async { [weak self] in
            if SlackFind.pause > 0 { Thread.sleep(forTimeInterval: SlackFind.pause) }
            let reads = batch.map { archive.scan(month: $0) }
            let lines = reads.flatMap(\.lines)
            let recorded = SlackSearch.recorded(lines, members: members, hub: hub, archive: archive)
            DispatchQueue.main.async {
                guard let self, !self.closing, self.model.findOpen, self.find.session == session, self.archive?.root == archive.root else { return }
                self.find.lines += lines; self.find.months = (self.find.months + batch).sorted()
                self.find.unreadable += reads.reduce(0) { $0 + $1.unreadable }
                self.find.damaged += reads.reduce(0) { $0 + $1.damaged }
                if reads.contains(where: { $0.away > 0 }) { self.find.away = true }
                if !recorded.isEmpty { self.find.recorded += recorded }
                self.refreshFind()
                self.readFind(archive, session: session)
            }
        }
    }
    /// What the results lack, said plainly, and how far the record has been read.
    private func showFindGaps() {
        var gaps: [String] = []
        if find.away { gaps.append("일부 기록은 iCloud에서 내려받지 않아 검색에서 빠졌어요") }
        if find.unlisted > 0 { gaps.append("기록 폴더 \(find.unlisted)개의 목록을 읽지 못해 그 안의 기록이 검색에서 빠졌을 수 있어요") }
        if find.unreadable > 0 { gaps.append("기록 파일 \(find.unreadable)개를 읽지 못해 검색 결과가 빠졌을 수 있어요") }
        if find.damaged > 0 { gaps.append("손상된 기록 \(find.damaged)줄은 건너뛰고 나머지를 찾았어요") }
        if model.findGaps != gaps { model.findGaps = gaps }
        let progress = find.loadingArchive && !find.known.isEmpty ? "기록 \(find.months.count)/\(find.known.count)개월 읽음" : nil
        if model.findProgress != progress { model.findProgress = progress }
    }
    func refreshFind() {
        guard !closing, model.findOpen else { return }
        let query = model.findQuery
        defer { model.findBusy = !SlackSearch.normalized(query).isEmpty && (find.loadingArchive || find.loadingRemote || find.matching) }
        let input = SlackFind.Input(generation: find.generation, live: find.liveRevision, recorded: find.recordedRevision,
                                    remote: find.remoteRevision, hidden: model.hidden)
        guard find.input != input else { return }
        find.input = input
        guard !SlackSearch.normalized(query).isEmpty else { find.matching = false; model.findGroups = []; return }
        let sources = [Array(snapshot.threads.values).flatMap { $0 }, find.recorded, find.remote]
        find.matching = true
        find.queue.async { [weak self] in
            let groups = SlackSearch.groups(query, sources: sources, hidden: input.hidden)
            DispatchQueue.main.async {
                guard let self, !self.closing, self.model.findOpen, self.find.generation == input.generation, self.find.input == input else { return }
                self.find.matching = false
                if self.model.findGroups != groups { self.model.findGroups = groups }
                self.model.findSelection = min(self.model.findSelection, max(0, groups.count - 1))
                self.refreshFind()
            }
        }
    }
    func submitFind() {
        guard !closing else { return }
        find.remoteWork?.cancel()
        searchServer(generation: find.generation)
    }
    private func searchServer(generation: UUID) {
        guard !closing else { return }
        guard model.findOpen, find.generation == generation, !find.loadingRemote,
              !SlackSearch.normalized(model.findQuery).isEmpty, let api else { refreshFind(); return }
        find.loadingRemote = true; model.findBusy = true
        let query = model.findQuery, snapshot = self.snapshot, hidden = model.hidden, characters = cast
        find.queue.async { [weak self] in
            let result = SlackSearch.remote(query, api: api, workspace: snapshot.workspace, rooms: Set(snapshot.rooms.map(\.id)), hidden: hidden,
                                            me: snapshot.me, users: snapshot.users, characters: characters)
            DispatchQueue.main.async {
                guard let self, !self.closing, self.model.findOpen, self.find.generation == generation else { return }
                self.find.loadingRemote = false
                switch result {
                case .success(let threads): self.find.remote = threads
                case .failure(let error): self.model.findNotice = SlackSearch.failure(error)
                }
                self.refreshFind()
            }
        }
    }
    func revealFind(_ group: SlackSearch.Group, message: ChatMessage) {
        guard !closing else { return }
        // Whole months already read by search become visible together, so paging cannot mistake a partial month for a whole one.
        if let month = find.months.first(where: { $0 == DdotsArchive.month(min(group.root.date, message.date)) }), !keptMonths.contains(month) {
            let added = Set(find.months.filter { $0 >= month && !keptMonths.contains($0) })
            for line in find.lines where added.contains(DdotsArchive.month(Date(timeIntervalSince1970: line.at))) { kept[line.profile, default: []].append(line) }
            keptMonths = (keptMonths + Array(added)).sorted(); keptRevision += 1
            keptEarlier = find.known.contains { $0 < (keptMonths.first ?? "") }
        }
        let term = model.findQuery
        model.closeFind()
        // Set before the room changes, so the month just added is not let go on the way there.
        find.target = (group.id, message.id, Date().addingTimeInterval(Self.followWait))
        model.select(model.ddotsShown.contains(group.room) ? Ddots.room : group.room)
        model.findHighlight = (group.id, term)
        publish()
        if find.target != nil { follow(room: group.room, ts: group.ts, url: nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followWait) { [weak self] in self?.arriveFind() }
    }
    func arriveFind() {
        guard !closing, let target = find.target else { return }
        if let thread = model.threads.first(where: { $0.id == target.thread }), thread.messages.contains(where: { $0.id == target.message }) {
            find.target = nil; model.go(to: target.thread)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closing else { return }
                self.model.requestScroll(target.message); self.model.flash = target.message
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in if self?.closing == false, self?.model.flash == target.message { self?.model.flash = nil } }
            }
        } else if Date() >= target.until {
            find.target = nil; sendNotice = "그 스레드를 불러오지 못했어요"; model.notice = sendNotice
        }
    }
}

extension SlackModel {
    func findTerm(_ message: ChatMessage) -> String? {
        guard let highlight = findHighlight, message.id.hasPrefix("slack:") else { return nil }
        let parts = message.id.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, "slack:" + parts[1] + ":" + message.sessionID == highlight.thread else { return nil }
        return highlight.term
    }
    func openFind() { findHighlight = nil; if findOpen { findFocus += 1; return }; findOpen = true; findFocus += 1; onFindOpen?() }
    func closeFind() { findOpen = false; onFind?() }
    func moveFind(_ delta: Int) { findSelection = min(max(0, findSelection + delta), max(0, findGroups.count - 1)) }
    func chooseFind() {
        guard findGroups.indices.contains(findSelection), let message = findGroups[findSelection].matches.first else { onFindSubmit?(); return }
        onFindReveal?(findGroups[findSelection], message)
    }
    func handleFindKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), ["f", "ㄹ"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { openFind(); return true }
        guard findOpen else { return false }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        switch event.keyCode {
        case 53: closeFind()
        case 125: moveFind(1)
        case 126: moveFind(-1)
        case 36: chooseFind()
        default: return false
        }
        return true
    }
}
