import Foundation
import CryptoKit

enum ClipboardKind: String, Codable { case text, files, image, video }

/// Paths in `files` always refer to user originals. They are never owned by the shelf.
struct ClipboardEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipboardKind
    var text: String?
    var rtf: Data?
    var files: [String] = []
    var dataID: UUID?
    var dataType: String?
    var byteCount = 0
    var digest: String
    var copiedAt: Date
    var source: String
    var secret = false
    var pinned = false
    var pinOrder: Int?
    var recognizedText: String?
    var memberships: Set<UUID> = []

    var exportExtension: String {
        if kind == .video { return dataType == "com.apple.quicktime-movie" ? "mov" : "mp4" }
        return dataType == "public.tiff" ? "tiff" : "png"
    }
    var protected: Bool { pinned || !memberships.isEmpty }
    var isMediaFile: Bool { files.contains { Self.mediaExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) } }
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "webp", "bmp"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
    static let mediaExtensions = imageExtensions.union(videoExtensions)
    var title: String {
        if secret { return "비밀" }
        switch kind {
        case .text: return String((text ?? "").split(separator: "\n", omittingEmptySubsequences: false).first ?? "글자").prefix(100).description
        case .files: return files.count > 1 ? "\(URL(fileURLWithPath: files[0]).lastPathComponent) 외 \(files.count - 1)개" : files.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "파일"
        case .image: return "이미지"
        case .video: return "동영상"
        }
    }
    var preview: String { secret ? "••••••" : (text.map { String($0.prefix(400)) } ?? title) }
    func matchesRecognizedText(_ query: String) -> Bool {
        !secret && !query.isEmpty && recognizedText?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = secret ? [source] : [source, text ?? "", files.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " "), recognizedText ?? ""]
        return fields.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

struct ClipboardInput {
    var kind: ClipboardKind
    var text: String?
    var rtf: Data?
    var files: [String] = []
    var data: Data?
    var dataType: String?
    var source: String
    var secret = false

    var byteCount: Int { (text?.utf8.count ?? 0) + (rtf?.count ?? 0) + (data?.count ?? 0) }
    var digest: String {
        var hash = SHA256()
        // Length framing keeps adjacent fields unambiguous.
        for value in [Data(kind.rawValue.utf8), Data((text ?? "").utf8), rtf ?? Data(), Data(files.joined(separator: "\0").utf8), data ?? Data()] {
            var count = UInt64(value.count).bigEndian
            hash.update(data: withUnsafeBytes(of: &count) { Data($0) }); hash.update(data: value)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardLimits {
    var days: Int = 1
    var count: Int = 100
    var textBytes: Int = 10 * 1024 * 1024
    var dataBytes: Int = 500 * 1024 * 1024
    var totalBytes: Int = 2 * 1024 * 1024 * 1024
}

enum ClipboardHistoryError: Error { case tooLarge }

struct ClipboardHistory {
    private(set) var entries: [ClipboardEntry] = []
    var limits = ClipboardLimits()
    init(entries: [ClipboardEntry] = [], limits: ClipboardLimits = ClipboardLimits()) {
        self.entries = entries; self.limits = limits
    }

    static func ordered(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.filter(\.pinned).sorted { ($0.pinOrder ?? Int.max) < ($1.pinOrder ?? Int.max) } + entries.filter { !$0.pinned }
    }
    /// Returns the surviving entry and removed entries; the disk owner disposes only of owned blobs.
    mutating func insert(_ input: ClipboardInput, now: Date = Date(), deduplicating: Bool = true) throws -> (ClipboardEntry, [ClipboardEntry]) {
        let cap = input.kind == .text ? limits.textBytes : limits.dataBytes
        guard input.kind == .files || input.byteCount <= cap else { throw ClipboardHistoryError.tooLarge }
        let digest = input.digest
        if deduplicating, let index = entries.firstIndex(where: { $0.digest == digest }) {
            var entry = entries.remove(at: index)
            entry.copiedAt = now
            // Once a value was concealed, later copies cannot accidentally expose it.
            entry.secret = entry.secret || input.secret
            entry.source = input.source
            entries.insert(entry, at: 0)
            return (entry, prune(now: now))
        }
        let entry = ClipboardEntry(kind: input.kind, text: input.text, rtf: input.rtf, files: input.files,
                                   dataID: input.data == nil ? nil : UUID(), dataType: input.dataType,
                                   byteCount: input.byteCount, digest: digest, copiedAt: now, source: input.source,
                                   secret: input.secret || entries.contains { $0.digest == digest && $0.secret })
        entries.insert(entry, at: 0)
        return (entry, prune(now: now))
    }
    @discardableResult mutating func prune(now: Date = Date()) -> [ClipboardEntry] {
        var removed: [ClipboardEntry] = []
        if limits.days > 0 {
            let cutoff = now.addingTimeInterval(-Double(limits.days) * 86400)
            removed += remove { !$0.protected && $0.copiedAt < cutoff }
        }
        while entries.filter({ !$0.protected }).count > limits.count || entries.reduce(0, { $0 + $1.byteCount }) > limits.totalBytes {
            guard let index = entries.indices.reversed().first(where: { !entries[$0].protected }) else { break }
            removed.append(entries.remove(at: index))
        }
        return removed
    }
    @discardableResult mutating func remove(where predicate: (ClipboardEntry) -> Bool) -> [ClipboardEntry] {
        let removed = entries.filter(predicate); entries.removeAll(where: predicate); return removed
    }
    @discardableResult mutating func restore(_ entry: ClipboardEntry, at index: Int, preservingIDs: Set<UUID> = []) -> [ClipboardEntry] {
        // A copy made during the undo window must merge, retaining the concealed/pinned/tab metadata.
        let duplicates = remove { $0.id == entry.id || ($0.digest == entry.digest && !preservingIDs.contains($0.id)) }
        var restored = entry
        for duplicate in duplicates {
            restored.secret = restored.secret || duplicate.secret
            restored.pinned = restored.pinned || duplicate.pinned
            restored.memberships.formUnion(duplicate.memberships)
        }
        if restored.secret { restored.recognizedText = nil }
        entries.insert(restored, at: min(index, entries.count))
        return duplicates.filter { $0.dataID == nil || $0.dataID != restored.dataID }
    }
    mutating func update(_ id: UUID, _ change: (inout ClipboardEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }
}

/// Metadata stays in memory only; owned encrypted blobs live in trash until this window closes.
struct ClipboardUndo {
    struct Item { var entry: ClipboardEntry; var index: Int; var group: UUID? = nil }
    private(set) var items: [Item] = []
    var reservedBytes: Int { items.reduce(0) { $0 + $1.entry.byteCount } }
    private var lastDeletion: Date?
    private var closedAt: Date?
    mutating func append(_ entry: ClipboardEntry, index: Int, now: Date, group: UUID? = nil) -> Item? {
        lastDeletion = now
        items.append(Item(entry: entry, index: index, group: group))
        return items.count > 10 ? items.removeFirst() : nil
    }
    mutating func closed(now: Date) { closedAt = now }
    func expired(now: Date) -> Bool {
        guard let lastDeletion else { return false }
        return now >= max(lastDeletion.addingTimeInterval(30), (closedAt ?? lastDeletion).addingTimeInterval(10))
    }
    mutating func pop() -> Item? { items.popLast() }
    mutating func popGroup() -> [Item] {
        guard let last = items.popLast() else { return [] }
        var group = [last]
        if let id = last.group { while items.last?.group == id { group.append(items.removeLast()) } }
        return group.sorted { $0.index < $1.index }
    }
    mutating func clear() { items.removeAll(); lastDeletion = nil; closedAt = nil }
}
