import Foundation

/// Keeping and reading the ddots record: every message and file of the characters' conversations, written to the
/// shared folder by one Mac and read by all, so the room still has its past after Slack has let it go.
extension SlackController {
    /// A room is read through again this long after the last time, to catch a reply under a thread too old to be on screen.
    static let rescanAfter: TimeInterval = 24 * 3600
    /// Slack's clock and this Mac's need not agree to the second.
    static let scanMargin: Double = 120
    /// After a line could not be written the record is left alone this long, then tried again.
    static let recordRetry: TimeInterval = 60

    /// The Mac that has Hermes keeps the record, unless the setting says otherwise.
    static func recordKeptHere() -> Bool {
        if let chosen = UserDefaults.standard.object(forKey: "ddotsWriter") as? Bool { return chosen }
        return HermesLocator.shared.locate() != nil
    }

    /// Finds the record and reads what is already in it. `keeps` is given by UI checks, which use a folder of their own.
    func openRecord(root: URL? = nil, keeps: Bool? = nil) {
        guard !closing, Ddots.enabled else { return }
        archive = DdotsArchive(root: root ?? DdotsArchive.standard(), retention: retention)
        keepsRecord = keeps ?? Self.recordKeptHere()
        if persists { recordThrough = UserDefaults.standard.dictionary(forKey: "ddotsThrough") as? [String: Double] ?? [:] }
        loadKept(initial: true)
    }

    /// True when these rooms go further back in the record than in Slack.
    func readsRecord(_ rooms: [String]) -> Bool {
        archive != nil && !keptMonths.isEmpty && rooms.contains { model.ddotsRooms.contains($0) }
    }

    /// Reads months of the record off the main thread: first the two newest, after that one older month each time it
    /// is asked. The Mac that keeps the record reads an older month back only when a line of it is to be written.
    func loadKept(initial: Bool) {
        guard !closing, let archive, !loadingKept else { return }
        loadingKept = true
        let have = keptMonths, keeps = keepsRecord
        fileQueue.async { [weak self] in
            let all = archive.months()
            let show = initial ? DdotsArchive.atStart(all) : all.filter { month in have.first.map { month < $0 } ?? true }.suffix(1).map { $0 }
            var lines: [String: [DdotsLine]] = [:]
            for month in show { lines[month] = archive.read(month: month) }
            let members = archive.readCast()
            DispatchQueue.main.async {
                guard let self, !self.closing, self.archive?.root == archive.root else { return }
                self.loadingKept = false
                if initial {
                    self.recordWriter = DdotsWriter(lines.values.flatMap { $0 }, unread: keeps ? Set(all).subtracting(show) : [])
                    self.recordWaiting = []; self.readingBack = false; self.keptFloor = show.first
                    self.recordBacklog = DdotsBacklog(); self.recordWriting = false; self.recordHeldUntil = .distantPast; self.recordNotice = nil
                    self.fetches = DdotsFetches()
                    self.kept = [:]; self.keptMonths = []
                    if self.characters.isEmpty { self.castFallback = members.map { ChatCharacter(id: $0.profile, name: $0.name) } }
                    self.castWritten = members
                }
                if !initial { self.recordWriter?.learn(lines.values.flatMap { $0 }, months: Set(show)) }
                let added = show.filter { !self.keptMonths.contains($0) }
                for month in added { for line in lines[month] ?? [] { self.kept[line.profile, default: []].append(line) } }
                self.keptMonths = (self.keptMonths + added).sorted()
                self.keptEarlier = self.keptMonths.first.map { first in all.contains { $0 < first } } ?? false
                self.keptRevision += 1
                self.publish()
            }
        }
    }

    /// Months read further back are let go once the room is shown from its newest again; asked for once more, they are
    /// read from the file anew. Not while a month is on its way or a search is showing what it found.
    func letGoOlderMonths() {
        guard !loadingKept, find.target == nil, !model.findOpen, let newest = DdotsArchive.newest(kept, months: keptMonths, from: keptFloor) else { return }
        kept = newest.kept; keptMonths = newest.months; keptEarlier = true; keptRevision += 1; keptThreads = [:]
    }

    /// The record's threads for the rooms on screen. Grouping them is redone only when the record or the room changed.
    func keptThreads(for rooms: [String]) -> [SlackThread] {
        guard let archive, !kept.isEmpty else { return [] }
        var result: [SlackThread] = []
        // What was said in the channel is shown with the channel, the rest with the character's own conversation.
        let hub = model.ddotsHub.flatMap { rooms.contains($0) ? $0 : nil }
        for member in model.ddotsMembers {
            for (slot, room, shared) in [(member.profile, member.room, false), (member.profile + ":hub", hub ?? "", true)] where rooms.contains(room) {
                if let ready = keptThreads[slot], ready.revision == keptRevision, ready.room == room { result += ready.threads; continue }
                let threads = DdotsLine.threads((kept[member.profile] ?? []).filter { ($0.hub ?? false) == shared }, room: room, archive: archive)
                keptThreads[slot] = (keptRevision, room, threads)
                result += threads
            }
        }
        return result
    }

    /// The characters' rooms that are due to be read through, each from where its record is known to be whole.
    func roomsToScan() -> [String: Double] {
        guard keepsRecord, recordWriter != nil else { return [:] }
        var due: [String: Double] = [:]
        for member in model.ddotsMembers where recordScanned[member.profile].map({ Date().timeIntervalSince($0) > Self.rescanAfter }) ?? true {
            due[member.room] = max(0, (recordThrough[member.profile] ?? 0) - Self.scanMargin)
        }
        if let hub = model.ddotsHub, recordScanned[Ddots.room].map({ Date().timeIntervalSince($0) > Self.rescanAfter }) ?? true {
            due[hub] = max(0, (recordThrough[Ddots.room] ?? 0) - Self.scanMargin)
        }
        return due.filter { !retention.excludes($0.key) }
    }

    /// Takes what a scan found and notes the rooms it has read through.
    func absorb(scanned: [String: [ChatMessage]], through: [String: Double]) {
        guard !closing else { return }
        if !scanned.isEmpty { record(scanned: scanned) }
        guard !through.isEmpty else { return }
        for member in model.ddotsMembers { if !retention.excludes(member.room), let began = through[member.room] { recordThrough[member.profile] = began; recordScanned[member.profile] = Date() } }
        if let hub = model.ddotsHub, !retention.excludes(hub), let began = through[hub] { recordThrough[Ddots.room] = began; recordScanned[Ddots.room] = Date() }
        saveThrough()
    }

    /// How far the record is whole is noted for the next start only once everything read up to there is written,
    /// so a start after a failed write reads those rooms through again.
    private func saveThrough() {
        guard !closing, persists, recordBacklog.isEmpty, !recordWriting, recordWaiting.isEmpty else { return }
        var values = recordThrough
        for member in model.ddotsMembers where retention.excludes(member.room) { values[member.profile] = nil }
        if let hub = model.ddotsHub, retention.excludes(hub) { values[Ddots.room] = nil }
        if UserDefaults.standard.dictionary(forKey: "ddotsThrough") as? [String: Double] != values { UserDefaults.standard.set(values, forKey: "ddotsThrough") }
    }

    /// Writes down whatever of the characters' conversations is not written yet, and fetches the files that came with it.
    func record(scanned: [String: [ChatMessage]] = [:]) {
        guard !closing, keepsRecord, let archive, var writer = recordWriter, !model.ddotsMembers.isEmpty else { return }
        let members = model.ddotsMembers
        let names = Dictionary(members.map { ($0.profile, $0.name) }, uniquingKeysWith: { first, _ in first })
        let rooms = Set(members.map(\.room) + [model.ddotsHub].compactMap { $0 })
        let input = DdotsRecordMemo.Input(threads: snapshot.threads.filter { rooms.contains($0.key) },
            scanned: scanned.filter { rooms.contains($0.key) }, members: members, hub: model.ddotsHub,
            excluded: Set(rooms.filter { retention.excludes($0) }))
        // A line of a month not read back yet waits for it, newest version only, so it is told new or not against the file.
        var seen = Set<String>(), said: [DdotsRecordMemo.Candidate] = [], waiting: [DdotsRecordMemo.Candidate] = []
        for candidate in (recordWaiting + recordMemo.candidates(input)).reversed() where seen.insert(candidate.line.key).inserted {
            if writer.waits(candidate.line) { waiting.insert(candidate, at: 0) } else { said.insert(candidate, at: 0) }
        }
        recordWaiting = waiting
        if !waiting.isEmpty { readBack(Set(waiting.map { DdotsArchive.month(Date(timeIntervalSince1970: $0.line.at)) }), from: archive) }
        let fresh = writer.fresh(said.map(\.line))
        recordWriter = writer
        writeCast(members)
        // The Mac that writes the record shows from it without reading its own lines back.
        var shelved = false
        for line in fresh {
            let month = DdotsArchive.month(Date(timeIntervalSince1970: line.at))
            // A month not read yet is read whole from its file when it is asked for.
            guard DdotsArchive.shows(month, read: keptMonths) else { keptEarlier = true; continue }
            if let index = kept[line.profile]?.firstIndex(where: { $0.ts == line.ts }) { kept[line.profile]?[index] = line } else { kept[line.profile, default: []].append(line) }
            if !keptMonths.contains(month) { keptMonths = (keptMonths + [month]).sorted() }
            shelved = true
        }
        if shelved { keptRevision += 1 }
        recordBacklog.add(fresh)
        write(to: archive, names: names)
        // A file is asked for until it is in its place, not only in the pass that writes its line.
        for candidate in said {
            let message = candidate.message, line = candidate.line
            for (file, place) in zip(message.files, line.files) where fetches.isNew(place.path) {
                guard let from = URL(string: file.url) else { continue }
                let old = DdotsArchive.filePath(name: names[line.profile] ?? line.profile, file: file.name, id: "", date: message.date)
                fetches.want(.init(path: place.path, from: from, old: old, room: line.room))
            }
        }
        fetch(into: archive)
    }

    /// Reads months of the record back for the writer only, then takes up the lines that waited for them.
    private func readBack(_ months: Set<String>, from archive: DdotsArchive) {
        guard !readingBack else { return }
        readingBack = true
        fileQueue.async { [weak self] in
            let lines = months.flatMap { archive.read(month: $0) }
            DispatchQueue.main.async {
                guard let self, !self.closing, self.archive?.root == archive.root, self.readingBack else { return }
                self.readingBack = false
                self.recordWriter?.learn(lines, months: months)
                self.record()
            }
        }
    }

    /// Writes what is waiting, one batch at a time. What cannot be written waits and is tried again after a while;
    /// the room says so meanwhile.
    private func write(to archive: DdotsArchive, names: [String: String]) {
        guard !closing, !recordBacklog.isEmpty, !recordWriting, Date() >= recordHeldUntil else { return }
        let lines = recordBacklog.take()
        recordWriting = true
        fileQueue.async { [weak self] in
            var lost: [DdotsLine] = [], reason = ""
            do { try archive.append(lines, names: names) }
            catch let failure as DdotsArchive.Unwritten { lost = failure.lines; reason = failure.reason }
            catch { lost = lines; reason = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self, !self.closing, self.archive?.root == archive.root else { return }
                self.recordWriting = false
                let said = self.recordNotice
                if lost.isEmpty {
                    self.recordNotice = nil
                    self.saveThrough()
                } else {
                    self.recordBacklog.putBack(lost)
                    self.recordHeldUntil = Date().addingTimeInterval(Self.recordRetry)
                    self.recordNotice = "ddots 기록을 쓰지 못했어요. 잠시 뒤 다시 적어요. (\(reason))"
                    // Nothing else may happen in the room by then, so the next try is set going from here.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordRetry + 1) { [weak self] in self?.publish() }
                }
                // Lines that came in meanwhile are written by the pass this starts.
                if said != self.recordNotice || !self.recordBacklog.isEmpty { self.publish() }
            }
        }
    }

    /// Fetches the record's files that are due. One that is already there, under its name of now or of before, is not fetched.
    private func fetch(into archive: DdotsArchive) {
        guard !closing else { return }
        let due = fetches.due(now: Date())
        guard !due.isEmpty else { return }
        let api = self.api, retention = self.retention
        fileQueue.async { [weak self] in
            var saved: [String: Bool] = [:]
            for item in due {
                if let room = item.room, retention.excludes(room) { continue }
                let place = archive.fileURL(item.path)
                var there = FileManager.default.fileExists(atPath: place.path) || FileManager.default.fileExists(atPath: archive.fileURL(item.old).path)
                if !there {
                    var data: Data?
                    if item.from.isFileURL { data = try? Data(contentsOf: item.from) }
                    else if case .success(let fetched)? = api?.raw(item.from, nil) { data = fetched }
                    if let data {
                        retention.locked {
                        guard item.room.map({ !retention.excludes($0) }) ?? true else { return }
                        try? FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
                        there = (try? data.write(to: place, options: .atomic)) != nil
                        }
                    }
                }
                saved[item.path] = there
            }
            DispatchQueue.main.async {
                guard let self, !self.closing, self.archive?.root == archive.root else { return }
                for (path, there) in saved { self.fetches.finish(path, saved: there, now: Date()) }
            }
        }
    }

    /// Compatibility cast for older readers; ddots-config.json owns the current organization.
    private func writeCast(_ members: [DdotsMember]) {
        guard !closing, let archive else { return }
        let cast = members.map { DdotsArchive.Member(profile: $0.profile, name: $0.name, user: snapshot.members[$0.room]?.first?.user ?? "") }
        guard cast != castWritten else { return }
        castWritten = cast
        fileQueue.async { try? archive.writeCast(cast) }
    }
}
