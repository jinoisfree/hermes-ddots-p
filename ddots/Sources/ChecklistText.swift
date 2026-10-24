import SwiftUI
import CryptoKit

/// Check marks are the reader's own state; toggling one never edits or sends an agent's message.
final class MessageChecklist: ObservableObject {
    static let shared = MessageChecklist(persist: !CommandLine.arguments.contains("--ui-smoke"))
    private(set) var revision: UInt64 = 0
    private let persist: Bool
    private let preference = "messageChecklist.v1"
    @Published private var values: [String: [String: Bool]]
    init(persist: Bool) {
        self.persist = persist
        values = persist ? (UserDefaults.standard.dictionary(forKey: preference) as? [String: [String: Bool]] ?? [:]) : [:]
    }
    static func key(_ identity: String, text: String) -> String {
        SHA256.hash(data: Data((identity + "\n" + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func checked(_ key: String, offset: Int, original: Bool) -> Bool { values[key]?[String(offset)] ?? original }
    func toggle(_ key: String, offset: Int, original: Bool) {
        revision &+= 1
        values[key, default: [:]][String(offset)] = !checked(key, offset: offset, original: original)
        if persist { UserDefaults.standard.set(values, forKey: preference) }
    }
}

struct ChecklistText: View {
    let text: AttributedString
    let identity: String
    let revision: String
    @ObservedObject private var checks = MessageChecklist.shared
    @Environment(\.openURL) private var openURL
    init(_ text: AttributedString, identity: String, revision: String) { self.text = text; self.identity = identity; self.revision = revision }
    var body: some View {
        if text.characters.contains(where: { $0 == "☐" || $0 == "☑" }) { checklist }
        else { LinkText(text) }
    }
    @ViewBuilder private var checklist: some View {
        let plain = String(text.characters)
        let key = MessageChecklist.key(identity, text: revision)
        let originals = Dictionary(uniqueKeysWithValues: plain.enumerated().compactMap { offset, character -> (Int, Bool)? in
            guard character == "☐" || character == "☑" else { return nil }
            return (offset, character == "☑")
        })
        LinkText(styled(key, originals: originals))
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "ddots-check", let offset = Int(url.lastPathComponent), let original = originals[offset] {
                    checks.toggle(key, offset: offset, original: original)
                } else { openURL(url) }
                return .handled
            })
            .help(originals.isEmpty ? "" : "체크박스를 누르면 내 확인 상태를 저장합니다.")
    }
    private func styled(_ key: String, originals: [Int: Bool]) -> AttributedString {
        guard !originals.isEmpty else { return text }
        var result = text
        for (offset, original) in originals.sorted(by: { $0.key > $1.key }) {
            let start = result.characters.index(result.startIndex, offsetBy: offset), end = result.characters.index(after: start)
            var mark = AttributedString(checks.checked(key, offset: offset, original: original) ? "☑" : "☐")
            mark.mergeAttributes(result[start..<end].runs.first!.attributes)
            mark.link = URL(string: "ddots-check://toggle/\(offset)")
            result.replaceSubrange(start..<end, with: mark)
        }
        return result
    }
}
