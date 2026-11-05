import Foundation

/// When the list's layout checker may look, confirm and write. Plain numbers and files: nothing here touches a view.
enum ThreadLayoutDiagnosticsPolicy {
    /// The checker looks at most this often (seconds) after the list has been laid out.
    static let checkInterval: TimeInterval = 2
    /// A violation counts once the next look, at least this long after the first, still finds it.
    static let confirmDelay: TimeInterval = 0.3
    /// One automatic record per this many seconds.
    static let recordInterval: TimeInterval = 600
    /// Automatic records kept in the folder; older ones go first.
    static let automaticKept = 20
    static let setting = "threadLayoutDiagnostics"
    static let prefix = "thread-layout-"

    /// A check's own switch, so a check never writes the owner's preferences.
    static var forced: Bool?
    /// On unless the setting says no (`defaults write <bundle id> threadLayoutDiagnostics -bool false`, or `-threadLayoutDiagnostics NO` on the command line).
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        if let forced { return forced }
        return defaults.object(forKey: setting) == nil ? true : defaults.bool(forKey: setting)
    }

    static func fileName(_ date: Date, manual: Bool) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyyMMdd-HHmmss"
        return prefix + format.string(from: date) + (manual ? "-manual.json" : "-auto.json")
    }

    private static func automaticFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix("-auto.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The time an earlier automatic record was written, read from the newest file's name so it holds across restarts.
    static func lastAutomatic(in folder: URL) -> Date? {
        guard let name = automaticFiles(in: folder).last?.lastPathComponent else { return nil }
        let stamp = String(name.dropFirst(prefix.count).dropLast("-auto.json".count))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyyMMdd-HHmmss"
        return format.date(from: stamp)
    }

    static func mayRecordAutomatically(in folder: URL, now: Date) -> Bool {
        guard let last = lastAutomatic(in: folder) else { return true }
        return now.timeIntervalSince(last) >= recordInterval || now < last
    }

    /// Deletes the oldest automatic records beyond `automaticKept`. Records the owner asked for are never removed.
    static func pruneAutomatic(in folder: URL) {
        let files = automaticFiles(in: folder)
        for file in files.dropLast(automaticKept) { try? FileManager.default.removeItem(at: file) }
    }

    /// Violations seen at one look, and whether the next look found any of them again.
    struct Confirmation {
        private var seen: (keys: Set<String>, at: TimeInterval)?
        /// The violations that stayed since an earlier look, empty when none did. A look with none clears the memory.
        mutating func look(_ keys: Set<String>, at now: TimeInterval) -> Set<String> {
            guard !keys.isEmpty else { seen = nil; return [] }
            if let earlier = seen, now - earlier.at > confirmDelay {
                let stayed = earlier.keys.intersection(keys)
                if !stayed.isEmpty { seen = nil; return stayed }
            }
            if seen == nil || now - seen!.at > confirmDelay { seen = (keys, now) }
            return []
        }
        var waiting: Bool { seen != nil }
    }
}
