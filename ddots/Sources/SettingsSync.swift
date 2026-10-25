import Darwin
import Foundation

/// One shared screen choice: its value (nil once it was taken away), when it was made, and on which Mac.
struct SyncEntry: Codable, Equatable {
    var v: String?
    var at: Double
    var by: String
}

/// Screen choices kept alike on every Mac signed in to the same Slack account: what was read, the sections and their
/// order, bells, mutes and pictures. A read only moves forward, so the later read wins; every other choice is the one
/// made last. The Mac that shares Hermes keeps the original; the others keep a copy and trade changes over the relay.
enum SettingsSync {
    static let readPrefix = "r:"
    /// Choices whose absence on a Mac means they were taken away there.
    static let removable = ["zone:", "open:", "name:", "hidden:", "muted:", "unkept:"]
    /// What "make this Mac's screen the standard" puts over every other Mac's.
    static let layout = removable + ["picture:"]
    static let layoutWhole: Set<String> = ["sections", "pins", "chatMuted", "stackOpen"]
    /// Long lists keep only their newest entries.
    static let caps: [(prefix: String, keep: Int)] = [("r:thread:", 3000), ("dismissed:", 400), ("r:confirmed:", 400), ("r:deleted:", 600)]

    static func isLayout(_ key: String) -> Bool { layoutWhole.contains(key) || layout.contains(where: key.hasPrefix) }
    static func readValue(_ entry: SyncEntry) -> Double { entry.v.flatMap(Double.init) ?? 0 }
    static func wins(_ new: SyncEntry, over old: SyncEntry?, key: String) -> Bool {
        guard let old else { return true }
        if key.hasPrefix(readPrefix) { return readValue(new) > readValue(old) }
        return (new.at, new.by) > (old.at, old.by)
    }
    /// Keys are short and made of what Slack ids and our own names use; anything else is not ours.
    static func valid(_ key: String) -> Bool { (1...200).contains(key.utf8.count) && !key.contains("\n") }
    static func validUser(_ id: String) -> Bool { (1...40).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    /// Merges entries in; returns those that took effect.
    @discardableResult static func merge(_ incoming: [String: SyncEntry], into doc: inout [String: SyncEntry]) -> [String: SyncEntry] {
        var changed: [String: SyncEntry] = [:]
        for (key, entry) in incoming where valid(key) && wins(entry, over: doc[key], key: key) { doc[key] = entry; changed[key] = entry }
        return changed
    }
    /// Layout entries `incoming` leaves out are taken away, so the Mac that sent them becomes the standard.
    static func replacing(_ incoming: [String: SyncEntry], in doc: [String: SyncEntry], at: Double, by: String) -> [String: SyncEntry] {
        var result = incoming
        for (key, entry) in doc where entry.v != nil && incoming[key] == nil && layout.contains(where: key.hasPrefix) {
            result[key] = SyncEntry(v: nil, at: at, by: by)
        }
        return result
    }
    static func prune(_ doc: inout [String: SyncEntry]) {
        for cap in caps {
            let keys = doc.keys.filter { $0.hasPrefix(cap.prefix) }
            guard keys.count > cap.keep else { continue }
            func rank(_ key: String) -> Double { key.hasPrefix(readPrefix) ? readValue(doc[key]!) : doc[key]!.at }
            for key in keys.sorted(by: { (rank($0), $0) > (rank($1), $1) }).dropFirst(cap.keep) { doc[key] = nil }
        }
    }
    /// What changed on this Mac since `before`, stamped with `at`.
    static func changes(from before: [String: String], to after: [String: String], at: Double, by: String) -> [String: SyncEntry] {
        var result: [String: SyncEntry] = [:]
        for (key, value) in after where before[key] != value { result[key] = SyncEntry(v: value, at: at, by: by) }
        for key in before.keys where after[key] == nil && removable.contains(where: key.hasPrefix) { result[key] = SyncEntry(v: nil, at: at, by: by) }
        return result
    }
    /// Entries of `doc` that differ from `seen`.
    static func difference(_ doc: [String: SyncEntry], from seen: [String: SyncEntry]) -> [String: SyncEntry] {
        doc.filter { seen[$0.key] != $0.value }
    }
    /// Entries split so that no relay line grows past `limit` bytes.
    static func chunks(_ entries: [String: SyncEntry], limit: Int = 512 * 1024) -> [[String: SyncEntry]] {
        var result: [[String: SyncEntry]] = [], current: [String: SyncEntry] = [:], size = 0
        for key in entries.keys.sorted() {
            let entry = entries[key]!, cost = key.utf8.count + (entry.v?.utf8.count ?? 0) + 80
            if !current.isEmpty, size + cost > limit { result.append(current); current = [:]; size = 0 }
            current[key] = entry; size += cost
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// The shared choices of one Slack account in one file. Both the pet and the relay of the sharing Mac write it, each
/// under the file lock and each reading it again first, so neither undoes the other.
final class SettingsStore {
    struct File: Codable { var user: String; var entries: [String: SyncEntry] }
    let user: String
    let url: URL
    private(set) var entries: [String: SyncEntry] = [:]
    private var seenStamp: [Double] = []

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder).appendingPathComponent("sync", isDirectory: true)
    }
    init?(user: String, folder: URL = SettingsStore.folder) {
        guard SettingsSync.validUser(user) else { return nil }
        self.user = user; url = folder.appendingPathComponent(user + ".json")
    }

    private func stamp() -> [Double] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return [] }
        return [(attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, Double((attributes[.size] as? Int) ?? 0)]
    }
    private func readFile() -> [String: SyncEntry] {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data), file.user == user else { return [:] }
        return file.entries
    }
    private func locked<T>(_ work: () -> T) -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return work()
    }
    /// What changed in the file since it was last read here.
    func refresh() -> [String: SyncEntry] {
        let now = stamp()
        guard now != seenStamp else { return [:] }
        let fresh = locked { (readFile(), stamp()) }
        seenStamp = fresh.1
        let changed = SettingsSync.difference(fresh.0, from: entries)
        entries = fresh.0
        return changed
    }
    /// Writes entries in and gives back everything that now differs from what was held here, other writers' changes included.
    @discardableResult func merge(_ incoming: [String: SyncEntry], replacing: Bool = false, at: Double = Date().timeIntervalSince1970, by: String = "") -> [String: SyncEntry] {
        let result: ([String: SyncEntry], [Double]) = locked {
            var doc = readFile()
            let wanted = replacing ? SettingsSync.replacing(incoming, in: doc, at: at, by: by) : incoming
            let took = SettingsSync.merge(wanted, into: &doc)
            if !took.isEmpty {
                SettingsSync.prune(&doc)
                if let data = try? JSONEncoder().encode(File(user: user, entries: doc)) {
                    let fresh = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString)
                    if FileManager.default.createFile(atPath: fresh.path, contents: data, attributes: [.posixPermissions: 0o600]), rename(fresh.path, url.path) != 0 {
                        try? FileManager.default.removeItem(at: fresh)
                    }
                }
            }
            return (doc, stamp())
        }
        seenStamp = result.1
        let changed = SettingsSync.difference(result.0, from: entries)
        entries = result.0
        return changed
    }
}
