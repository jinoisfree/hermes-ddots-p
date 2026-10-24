import Foundation

/// One message of the ddots record, as one line of text. Slack forgets after a year; this is what is kept.
struct DdotsLine: Codable, Equatable {
    struct File: Codable, Equatable {
        var name: String
        var size = 0
        var type = ""
        /// Where the file itself was put, from the record's own folder. Empty when it was too large to keep.
        var path = ""
    }
    struct Mark: Codable, Equatable { var color: String; var text: String }
    /// Slack's stamp for the message. With the character it names the message for good.
    var ts: String
    /// The stamp of the thread's first message; a first message carries its own.
    var thread: String
    /// The character whose conversation this is.
    var profile: String
    /// Who wrote it, as it was shown. Empty for the user.
    var name: String
    var mine: Bool
    var at: Double
    var text: String
    var files: [File] = []
    var marks: [Mark] = []
    /// True for a message said in the channel all characters share, not in the character's own conversation.
    var hub: Bool?
    var room: String?

    var key: String { profile + ":" + ts }
    /// What the message said, for telling a changed message from one already written down.
    var content: String {
        ([text] + files.map { $0.name + "/" + String($0.size) } + marks.map { $0.color + "/" + $0.text }).joined(separator: "\u{1}")
    }
}

/// The record on disk: a folder per character, a file per month, a line per message, only ever added to.
/// A message that changed is written again and the later line stands. Nothing here is a database,
/// so a folder that iCloud carries between Macs cannot be left half-written in a way that breaks it.
struct DdotsArchive {
    static let folder = "ddots"
    static let records = "기록"
    static let files = "파일"
    static let cast = "캐릭터.json"
    var root: URL
    var retention: SlackRetention?

    /// Inside the shared folder in this Mac's iCloud Drive, beside what the Slack side keeps there.
    static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        SlackFileStore.standard(home: home).appendingPathComponent(folder)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = format; return formatter
    }
    private static let monthFormat = formatter("yyyy-MM")
    private static let stampFormat = formatter("yyyy-MM-dd HHmm")
    static func month(_ date: Date) -> String { monthFormat.string(from: date) }
    /// The month before, as the files are named.
    static func previous(_ month: String) -> String? {
        guard let date = monthFormat.date(from: month), let earlier = Calendar.current.date(byAdding: .month, value: -1, to: date) else { return nil }
        return monthFormat.string(from: earlier)
    }

    func recordURL(name: String, month: String) -> URL {
        root.appendingPathComponent(Self.records).appendingPathComponent(SlackFileStore.safe(name)).appendingPathComponent(month + ".jsonl")
    }
    /// A file always lands on the same path for the same message, so it is fetched once however often it is seen.
    /// Slack's ID for the file is part of its name, so two files of one name sent in the same minute are both kept.
    /// With no ID the path is the one files had before names carried it.
    static func filePath(name: String, file: String, id: String, date: Date) -> String {
        [files, SlackFileStore.safe(name), stampFormat.string(from: date) + " " + SlackFileStore.named(file, id: id)].joined(separator: "/")
    }
    func fileURL(_ path: String) -> URL { root.appendingPathComponent(path) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }()

    /// The lines a call to `append` could not write, with the first reason. Every other line of that call is written.
    struct Unwritten: Error, Equatable { var lines: [DdotsLine]; var reason: String }

    /// Adds the lines to the month each belongs to. `names` gives each character's folder.
    /// A month's file is only ever added to: one that is there but cannot be opened is left as it is and its lines
    /// are handed back in `Unwritten`, never written anew over what the file holds.
    func append(_ lines: [DdotsLine], names: [String: String]) throws {
        if let retention { try retention.locked { try appendAllowed(lines.filter { !retention.excludes($0) }, names: names) } }
        else { try appendAllowed(lines, names: names) }
    }
    private func appendAllowed(_ lines: [DdotsLine], names: [String: String]) throws {
        var batches: [URL: [DdotsLine]] = [:]
        for line in lines where !SlackRetention.memoryOnly(line.text) {
            let file = recordURL(name: names[line.profile] ?? line.profile, month: Self.month(Date(timeIntervalSince1970: line.at)))
            batches[file, default: []].append(line)
        }
        var lost: [DdotsLine] = [], reason = ""
        for (file, batch) in batches {
            do { try add(batch, to: file) } catch {
                lost += batch
                if reason.isEmpty { reason = error.localizedDescription }
            }
        }
        if !lost.isEmpty { throw Unwritten(lines: lost, reason: reason) }
    }
    private func add(_ batch: [DdotsLine], to file: URL) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = Data()
        for line in batch.sorted(by: { $0.at < $1.at }) { text.append(try Self.encoder.encode(line)); text.append(0x0A) }
        // iCloud Drive used to stand a file it had put away as a hidden one beside where it was.
        let away = folder.appendingPathComponent("." + file.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: away.path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: "iCloud가 아직 내려받지 않은 기록 파일이에요."])
        }
        guard FileManager.default.fileExists(atPath: file.path) else { try text.write(to: file, options: .atomic); return }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A line cut short by a crash would swallow the next one written after it.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { text.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: text)
    }

    /// The months read when the app starts: the two newest are shown. The Mac that keeps the record reads every other
    /// month as well, because a quiet conversation's newest lines in Slack can be months old, and a line it did not
    /// know was written would be written again on every start.
    /// How many of the newest months are read at start, and kept in memory once the room is shown from its newest again.
    static let monthsShown = 2
    static func atStart(_ all: [String]) -> [String] { Array(all.suffix(monthsShown)) }
    /// The record's lines from `floor` on: the first month read at start, or else the newest two. A month that began
    /// since start is added, never put in the place of one shown at start. Nil when nothing is held from before it.
    static func newest(_ kept: [String: [DdotsLine]], months: [String], from floor: String? = nil) -> (kept: [String: [DdotsLine]], months: [String])? {
        let sorted = months.sorted()
        guard let first = floor ?? sorted.suffix(monthsShown).first, sorted.contains(where: { $0 < first }) else { return nil }
        return (kept.mapValues { $0.filter { month(Date(timeIntervalSince1970: $0.at)) >= first } }.filter { !$0.value.isEmpty }, sorted.filter { $0 >= first })
    }
    /// True when a line of this month belongs with what is shown: its month is one already read, or newer than all of them.
    /// A month further back is read whole from its file when it is asked for; one line of it must not pass for all of it.
    static func shows(_ month: String, read: [String]) -> Bool { read.first.map { month >= $0 } ?? true }

    /// What listing the record found: its months, whether iCloud holds some back, and how many folders could not be listed.
    /// A record that is not there at all is an empty list, not a failure.
    struct MonthList: Equatable {
        var months: [String] = []
        var away = false
        /// The record's own folder, or characters' folders, that are there but could not be listed.
        var unlisted = 0
    }
    func listMonths() -> MonthList {
        let base = root.appendingPathComponent(Self.records), manager = FileManager.default
        var result = MonthList()
        let folders: [URL]
        do { folders = try manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) } catch {
            if manager.fileExists(atPath: base.path) { result.unlisted += 1 }
            return result
        }
        var found = Set<String>()
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let files: [URL]
            do { files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) } catch { result.unlisted += 1; continue }
            for file in files {
                if file.pathExtension == "jsonl" { found.insert(file.deletingPathExtension().lastPathComponent) }
                else if file.lastPathComponent.hasPrefix("."), file.lastPathComponent.hasSuffix(".jsonl.icloud") { result.away = true }
            }
        }
        result.months = found.sorted()
        return result
    }
    /// The months that hold anything, oldest first, whoever's folder they are in.
    func months() -> [String] { listMonths().months }

    /// Old iCloud placeholders are not opened; their absence is reported in whole-record searches.
    func hasUndownloadedMonths() -> Bool { listMonths().away }

    /// Everything written for a month. A line that cannot be read is passed over; of two lines for one message the later stands.
    func read(month: String) -> [DdotsLine] { scan(month: month).lines }

    /// One month as read, with what could not be read. A character with nothing that month is not a gap.
    struct MonthRead: Equatable {
        var lines: [DdotsLine] = []
        /// Files that are there but could not be opened.
        var unreadable = 0
        /// Files iCloud has not brought down to this Mac yet.
        var away = 0
        /// Lines that are not a message as written, cut short or garbled.
        var damaged = 0
    }
    func scan(month: String) -> MonthRead {
        let base = root.appendingPathComponent(Self.records), manager = FileManager.default
        var result = MonthRead()
        let folders: [URL]
        do { folders = try manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) } catch {
            if manager.fileExists(atPath: base.path) { result.unreadable += 1 }
            return result
        }
        var latest: [String: DdotsLine] = [:], order: [String] = []
        for folder in folders {
            let file = folder.appendingPathComponent(month + ".jsonl")
            if manager.fileExists(atPath: folder.appendingPathComponent("." + month + ".jsonl.icloud").path) { result.away += 1; continue }
            guard manager.fileExists(atPath: file.path) else { continue }
            if (try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .notDownloaded { result.away += 1; continue }
            guard let data = try? Data(contentsOf: file) else { result.unreadable += 1; continue }
            for raw in data.split(separator: 0x0A) {
                guard let line = try? JSONDecoder().decode(DdotsLine.self, from: Data(raw)) else {
                    if !raw.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { result.damaged += 1 }
                    continue
                }
                if latest[line.key] == nil { order.append(line.key) }
                latest[line.key] = line
            }
        }
        result.lines = order.compactMap { latest[$0] }.sorted { ($0.at, $0.key) < ($1.at, $1.key) }
        return result
    }

    func removeUnkept() throws {
        guard let retention else { return }
        try retention.locked {
            let base = root.appendingPathComponent(Self.records)
            guard FileManager.default.fileExists(atPath: base.path) else { return }
            let folders = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            var removed = Set<String>(), kept = Set<String>()
            var rewrites: [(URL, Data)] = []
            func paths(_ line: DdotsLine) -> Set<String> {
                var result = Set(line.files.map(\.path))
                for file in line.files {
                    let parts = file.path.split(separator: "/")
                    if parts.count == 3 {
                        result.insert(Self.filePath(name: String(parts[1]), file: file.name, id: "", date: Date(timeIntervalSince1970: line.at)))
                    }
                }
                return result
            }
            for folder in folders {
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    if file.lastPathComponent.hasSuffix(".jsonl.icloud") { throw CocoaError(.fileReadUnknown) }
                    guard file.pathExtension == "jsonl" else { continue }
                    let data = try Data(contentsOf: file)
                    var output = Data(), changed = false
                    for raw in data.split(separator: 0x0A) {
                        let line = try JSONDecoder().decode(DdotsLine.self, from: Data(raw))
                        if retention.excludes(line) { removed.formUnion(paths(line)); changed = true }
                        else { output.append(raw); output.append(0x0A); kept.formUnion(paths(line)) }
                    }
                    if changed { rewrites.append((file, output)) }
                }
            }
            for path in removed.subtracting(kept) where !path.isEmpty {
                let url = fileURL(path).standardizedFileURL
                guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: url.path) else { continue }
                try FileManager.default.removeItem(at: url)
            }
            for (file, output) in rewrites { try output.write(to: file, options: .atomic) }
        }
    }

    /// Who is in ddots, written by the Mac that keeps the record so another Mac can show the room without Hermes beside it.
    struct Member: Codable, Equatable { var profile: String; var name: String; var user: String }
    func writeCast(_ members: [Member]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder.encode(members).write(to: root.appendingPathComponent(Self.cast), options: .atomic)
    }
    func readCast() -> [Member] {
        (try? Data(contentsOf: root.appendingPathComponent(Self.cast))).flatMap { try? JSONDecoder().decode([Member].self, from: $0) } ?? []
    }
}

/// Remembers what the record already holds, so each message is written once and again only when it changed.
/// Only a mark of what each message said is held, not its words. At start only the newest months are read back;
/// a line of an older month the record holds waits until that month is read, so nothing is written twice.
struct DdotsWriter {
    private var known: [String: Int] = [:]
    /// Months the record holds whose lines are not remembered yet.
    private(set) var unread: Set<String> = []
    init(_ written: [DdotsLine] = [], unread: Set<String> = []) {
        for line in written { known[line.key] = line.content.hashValue }
        self.unread = unread
    }
    /// True when the line's month is in the record but not read back yet.
    func waits(_ line: DdotsLine) -> Bool { unread.contains(DdotsArchive.month(Date(timeIntervalSince1970: line.at))) }
    /// Takes in months read back from the record. What was written since start stays as it is: it is newer.
    mutating func learn(_ written: [DdotsLine], months: Set<String>) {
        for line in written where known[line.key] == nil { known[line.key] = line.content.hashValue }
        unread.subtract(months)
    }
    /// The lines that are new or changed; they count as written from here on.
    mutating func fresh(_ lines: [DdotsLine]) -> [DdotsLine] {
        var result: [DdotsLine] = []
        for line in lines where known[line.key] != line.content.hashValue { known[line.key] = line.content.hashValue; result.append(line) }
        return result
    }
}

/// Lines waiting to be written, oldest first and one for each message: a later version takes the earlier one's place,
/// so a line that is written late never stands over a newer one.
struct DdotsBacklog {
    private(set) var lines: [DdotsLine] = []
    var isEmpty: Bool { lines.isEmpty }
    /// Newer lines, behind what is waiting.
    mutating func add(_ fresh: [DdotsLine]) {
        guard !fresh.isEmpty else { return }
        let keys = Set(fresh.map(\.key))
        lines = lines.filter { !keys.contains($0.key) } + fresh
    }
    /// Lines that could not be written, ahead of what has come in since; one a newer version waits for is dropped.
    mutating func putBack(_ lost: [DdotsLine]) {
        let keys = Set(lines.map(\.key))
        lines = lost.filter { !keys.contains($0.key) } + lines
    }
    mutating func take() -> [DdotsLine] { defer { lines = [] }; return lines }
}

/// Which of the record's files still have to be fetched. A file is fetched once; one that could not be fetched is
/// tried again later, at longer and longer waits, without its message having to be seen again.
struct DdotsFetches {
    struct Item: Equatable {
        var path: String
        var from: URL
        /// Where the file would be had it been kept before names carried Slack's ID.
        var old: String
        var room: String? = nil
    }
    static let firstWait: TimeInterval = 600, longestWait: TimeInterval = 6 * 3600
    private var have = Set<String>(), busy = Set<String>()
    private var wanted: [String: Item] = [:]
    private var failed: [String: (tries: Int, next: Date)] = [:]
    /// True for a file that is neither in its place nor asked for yet.
    func isNew(_ path: String) -> Bool { !path.isEmpty && !have.contains(path) && wanted[path] == nil }
    mutating func want(_ item: Item) { if isNew(item.path) { wanted[item.path] = item } }
    /// The files to fetch now. They count as on their way until `finish` says how each went.
    mutating func due(now: Date) -> [Item] {
        let ready = wanted.values.filter { !busy.contains($0.path) && (failed[$0.path]?.next ?? .distantPast) <= now }.sorted { $0.path < $1.path }
        busy.formUnion(ready.map(\.path))
        return ready
    }
    /// `saved` is true when the file is in its place, fetched just now or found already there.
    mutating func finish(_ path: String, saved: Bool, now: Date) {
        busy.remove(path)
        if saved { have.insert(path); wanted[path] = nil; failed[path] = nil; return }
        let tries = (failed[path]?.tries ?? 0) + 1
        failed[path] = (tries, now.addingTimeInterval(min(Self.longestWait, Self.firstWait * pow(2, Double(tries - 1)))))
    }
}

extension DdotsLine {
    /// A message as the conversation shows it, written down. Nothing is made of a "생각 중" line or of one still being sent.
    init?(_ message: ChatMessage, profile: String, names: [String: String], hub: Bool = false) {
        let parts = message.id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "slack", !message.pending, message.fromUser || !SlackText.isThinking(message.body) else { return nil }
        room = parts[1]
        ts = parts[2]; thread = message.sessionID.isEmpty ? parts[2] : message.sessionID
        self.profile = profile; name = message.fromUser ? "" : message.speaker; mine = message.fromUser
        at = message.date.timeIntervalSince1970; text = message.body
        let folder = names[profile] ?? profile
        files = message.files.map { file in
            File(name: file.name, size: file.size, type: file.mimetype,
                 path: file.size > SlackFileStore.largest ? "" : DdotsArchive.filePath(name: folder, file: file.name, id: file.id, date: message.date))
        }
        marks = message.marks.map { Mark(color: $0.color, text: $0.text) }
        if hub { self.hub = true }
    }

    /// The line as a message of the room that reaches this character now. A file that was kept opens from where it is.
    func message(room: String, archive: DdotsArchive) -> ChatMessage {
        var result = ChatMessage(id: "slack:\(room):\(ts)", fromUser: mine, speaker: name, body: text, date: Date(timeIntervalSince1970: at),
                                 sessionID: thread, profile: mine ? "" : profile)
        result.marks = marks.map { ChatMark(color: $0.color, text: $0.text) }
        result.files = files.enumerated().map { index, file in
            let local = file.path.isEmpty ? "" : archive.fileURL(file.path).absoluteString
            return ChatFile(id: "ddots:\(key):\(index)", name: file.name, mimetype: file.type, size: file.size, url: local, thumb: local)
        }
        return result
    }

    /// Lines of one character grouped into the threads they were said in, oldest first.
    static func threads(_ lines: [DdotsLine], room: String, archive: DdotsArchive) -> [SlackThread] {
        var groups: [String: [DdotsLine]] = [:], order: [String] = []
        for line in lines {
            if groups[line.thread] == nil { order.append(line.thread) }
            groups[line.thread, default: []].append(line)
        }
        return order.compactMap { stamp -> SlackThread? in
            let said = (groups[stamp] ?? []).sorted { $0.at < $1.at }
            // The first message may have been said before the record began; then the earliest line kept stands in for it.
            guard let first = said.first(where: { $0.ts == stamp }) ?? said.first, let last = said.last else { return nil }
            let replies = said.filter { $0.ts != first.ts }.map { $0.message(room: room, archive: archive) }
            return SlackThread(id: "slack:\(room):\(stamp)", room: room, ts: stamp, root: first.message(room: room, archive: archive), replies: replies,
                               replyCount: replies.count, loaded: true, latest: last.at, latestFromUser: last.mine)
        }.sorted { ($0.root.date, $0.id) < ($1.root.date, $1.id) }
    }
}

/// Cache only the pure message-to-record conversion, never the writer or retry decisions.
struct DdotsRecordMemo {
    struct Input: Equatable {
        var threads: [String: [SlackThread]]
        var scanned: [String: [ChatMessage]]
        var members: [DdotsMember]
        var hub: String?
        var excluded: Set<String>
        var timeZone = TimeZone.current.identifier
    }
    struct Candidate: Equatable { var message: ChatMessage; var line: DdotsLine }
    private var previous: Input?
    private var value: [Candidate] = []
    private(set) var evaluations = 0
    mutating func candidates(_ input: Input) -> [Candidate] {
        if previous == input { return value }
        let result = Self.convert(input); evaluations += 1
        let count = input.threads.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.replies.count + 1 } }
            + input.scanned.values.reduce(0) { $0 + $1.count }
        if count <= 8192 { previous = input; value = result }
        else { previous = nil; value = [] }
        return result
    }
    static func convert(_ input: Input) -> [Candidate] {
        let names = Dictionary(input.members.map { ($0.profile, $0.name) }, uniquingKeysWith: { first, _ in first })
        var result: [Candidate] = []
        for member in input.members where !input.excluded.contains(member.room) {
            for message in (input.threads[member.room] ?? []).flatMap(\.messages) + (input.scanned[member.room] ?? []) {
                if let line = DdotsLine(message, profile: member.profile, names: names) { result.append(Candidate(message: message, line: line)) }
            }
        }
        if let hub = input.hub, !input.excluded.contains(hub) {
            let messages = (input.threads[hub] ?? []).flatMap(\.messages) + (input.scanned[hub] ?? [])
            let owners = Ddots.owners(messages)
            for message in messages {
                guard let profile = owners[message.sessionID], names[profile] != nil else { continue }
                if let line = DdotsLine(message, profile: profile, names: names, hub: true) { result.append(Candidate(message: message, line: line)) }
            }
        }
        return result
    }
}
