import Foundation

/// Shared by the reading and file queues. Changing the choice waits for a disk write already in progress.
final class SlackRetention {
    static let key = "slackUnkept"
    /// Full-list wire snapshots expire at the bot and must never become a local record.
    static func memoryOnly(_ text: String) -> Bool {
        text.range(of: "^전체 목록 [0-9]+/[0-9]+ · 총 [0-9]+건(?:\\n|$)", options: .regularExpression) != nil
    }
    private let lock = NSRecursiveLock()
    private var rooms = Set<String>()
    private var hidden = Set<String>()
    private var profiles: [String: String] = [:]
    private var hub: String?

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    func update(_ rooms: Set<String>, hidden: Set<String>) { locked { self.rooms = rooms; self.hidden = hidden } }
    func map(profiles: [String: String], hub: String?) { locked { self.profiles = profiles; self.hub = hub } }
    func excludes(_ room: String) -> Bool { locked { rooms.contains(room) } }
    var cacheExcluded: Set<String> { locked { rooms.union(hidden) } }
    func excludes(_ line: DdotsLine) -> Bool {
        locked {
            if let room = line.room { return rooms.contains(room) }
            let room = (line.hub ?? false) ? hub : profiles[line.profile]
            return room.map { rooms.contains($0) } ?? false
        }
    }
    func filtered(_ values: [String: Double]) -> [String: Double] {
        locked { values.filter { key, _ in !cacheExcluded.contains(where: { key == $0 || key.hasPrefix($0 + ":") || key.hasPrefix("slack:" + $0 + ":") }) } }
    }
}

/// Only opened attachments live here; incoming previews remain in memory. Never in the shared store.
/// Its lock guards only whether it is closed, never a disk operation, so closing does not wait on a write or a removal.
final class SlackTemporaryFiles {
    let root: URL
    private let state = NSLock()
    private var closed = false
    /// A slow disk for the checks: called on the working thread as a write ("write") or a removal ("remove") begins.
    var stall: ((String) -> Void)?
    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-private-files")) { self.root = root }
    var isClosed: Bool { state.lock(); defer { state.unlock() }; return closed }
    func clear() throws {
        stall?("remove")
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    /// As the app closes nothing new is saved. Removing what is here is left to the caller, away from the main thread.
    func close() { state.lock(); closed = true; state.unlock() }
    /// A save that was under way when closing began takes its copy away again and reports a failure;
    /// one cut short by the app ending is removed by the next start.
    func save(_ data: Data, name: String) throws -> URL {
        guard !isClosed else { throw CocoaError(.fileWriteNoPermission) }
        let folder = root.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent(SlackFileStore.safe(name))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            var base = root, flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try base.setResourceValues(flags)
            stall?("write")
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
        guard !isClosed else {
            try? FileManager.default.removeItem(at: folder)
            // Only an empty folder goes; a copy that is someone else's to remove stays for them.
            rmdir(root.path)
            throw CocoaError(.fileWriteNoPermission)
        }
        return file
    }
}

/// The work done as the app closes runs away from the main thread. `finish` is called once on the main thread:
/// when every step is done, or at the limit with steps still running, whichever comes first.
/// It is reached through the main run loop, not the main queue: closing is often asked for from a block on the main
/// queue, and AppKit waits for the answer inside that block, where the main queue runs nothing else.
final class ClosingRun {
    private let group = DispatchGroup()
    private var answered = false
    private let limit: TimeInterval
    private let finish: (_ late: Bool) -> Void
    init(limit: TimeInterval, finish: @escaping (_ late: Bool) -> Void) { self.limit = limit; self.finish = finish }
    func add(on queue: DispatchQueue, _ work: @escaping () -> Void) {
        group.enter()
        queue.async { [group] in work(); group.leave() }
    }
    func start() {
        group.notify(queue: .global(qos: .userInitiated)) { [self] in
            RunLoop.main.perform(inModes: [.common]) { self.answer(late: false) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        RunLoop.main.add(Timer(timeInterval: limit, repeats: false) { [self] _ in answer(late: true) }, forMode: .common)
    }
    private func answer(late: Bool) {
        guard !answered else { return }
        answered = true
        finish(late)
    }
}
