import Foundation

enum ClipboardTabKind: String, Codable, CaseIterable {
    case all, text, secrets, media, files, custom
    var title: String {
        switch self { case .all: return "전체보기"; case .text: return "글자만"; case .secrets: return "암호만"; case .media: return "사진·영상만"; case .files: return "파일만"; case .custom: return "마음대로" }
    }
}
struct ClipboardTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: ClipboardTabKind
    func contains(_ entry: ClipboardEntry) -> Bool {
        switch kind {
        case .all: return true
        case .text: return entry.kind == .text && !entry.secret
        case .secrets: return entry.secret
        case .media: return entry.kind == .image || entry.kind == .video || entry.isMediaFile
        case .files: return entry.kind == .files
        case .custom: return entry.memberships.contains(id)
        }
    }
}
enum ClipboardTabError: Error { case invalidName, lastTab, missingTab }
struct ClipboardTabs: Codable {
    private(set) var items: [ClipboardTab] = [ClipboardTab(name: "전체", kind: .all), ClipboardTab(name: "글자", kind: .text), ClipboardTab(name: "비밀번호", kind: .secrets), ClipboardTab(name: "사진·영상", kind: .media)]
    var selected: UUID?
    var current: ClipboardTab { items.first { $0.id == selected } ?? items[0] }
    private func validated(_ name: String, except id: UUID? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !items.contains(where: { $0.id != id && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) else { throw ClipboardTabError.invalidName }
        return trimmed
    }
    @discardableResult mutating func add(name: String, kind: ClipboardTabKind) throws -> UUID {
        let tab = ClipboardTab(name: try validated(name), kind: kind); items.append(tab); selected = tab.id; return tab.id
    }
    mutating func rename(_ id: UUID, name: String) throws {
        let valid = try validated(name, except: id)
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw ClipboardTabError.missingTab }
        items[i].name = valid
    }
    mutating func changeKind(_ id: UUID, kind: ClipboardTabKind) throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw ClipboardTabError.missingTab }
        items[i].kind = kind
    }
    mutating func remove(_ id: UUID) throws {
        guard items.count > 1 else { throw ClipboardTabError.lastTab }
        items.removeAll { $0.id == id }
        if selected == id { selected = items[0].id }
    }
    mutating func move(_ id: UUID, before target: UUID) {
        guard id != target, let i = items.firstIndex(where: { $0.id == id }), items.contains(where: { $0.id == target }) else { return }
        let item = items.remove(at: i)
        items.insert(item, at: items.firstIndex(where: { $0.id == target })!)
    }
}
