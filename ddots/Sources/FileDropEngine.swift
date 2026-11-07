import Foundation

struct FileDropAnswer: Codable {
    var suggestions: [FileDropSuggestion]
    var summary: String = ""
    var confidence: Double = 1
    var works: [String] = []
    var outcomes: [String: String]? = nil
    /// Whether the Mac mini still left content unread after its own reader ran; nil from an older relay.
    var partial: Bool? = nil
}

enum FileDropRules {
    static let catalog: [String: String] = ["reveal": "Finder에서 보기", "copy_text": "글자 복사", "summarize": "세 줄 요약", "extract_todos": "할 일 뽑아 정리", "add_schedule": "날짜를 일정에", "attach_work": "업무에 붙이기", "file_away": "업무 폴더에 정리", "compare": "비교해서 정리", "explain": "무슨 내용인지 설명", "custom_instruction": "내 지시"]
    static let app: Set<String> = ["reveal", "copy_text"]
    static func rules(_ s: FileDropSignals, cast: FileDropCast) -> [FileDropSuggestion] {
        let owner = cast.candidates.contains(s.profile) ? s.profile : cast.profile(role: FileDropSignals.role(s.hint))
        var ids = ["summarize", s.names.count > 1 ? "compare" : "extract_todos", "explain"]
        if s.content.range(of: #"\d{1,2}월\s*\d{1,2}일|\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { ids[1] = "add_schedule" }
        var result = ids.map { FileDropSuggestion(id: $0, label: catalog[$0]!, profile: app.contains($0) ? "app" : owner) }
        if let custom = s.custom.first { result[0] = .init(id: "custom_instruction", label: shortLabel(custom), profile: owner, instruction: custom) }
        result.sort { s.habits[$0.id, default: 0] > s.habits[$1.id, default: 0] }
        return result
    }
    static func merge(_ incoming: [FileDropSuggestion], signals: FileDropSignals, fallback: [FileDropSuggestion], profiles: Set<String>) -> [FileDropSuggestion] {
        var result: [FileDropSuggestion] = []
        for var item in incoming + fallback {
            guard catalog[item.id] != nil, !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.contains(where: { $0.id == item.id && $0.profile == item.profile }), item.confidence.isFinite,
                  (app.contains(item.id) ? item.profile == "app" : profiles.contains(item.profile)),
                  item.id != "reveal" || !signals.kinds.allSatisfy({ ["text", "link"].contains($0) }),
                  item.id != "attach_work" || signals.works.contains(where: { !$0.isEmpty && item.label.contains($0) && shortLabel(item.label).contains($0) }),
                  item.id != "custom_instruction" || signals.custom.contains(item.instruction ?? item.label) else { continue }
            item.instruction = item.id == "custom_instruction" ? (item.instruction ?? item.label) : nil
            item.label = shortLabel(item.label); result.append(item)
            if result.count == 3 { break }
        }
        return result
    }
    /// Retain complete words (including punctuation boundaries); never cut a long token.
    static func shortLabel(_ input: String) -> String {
        let label = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count > 24 else { return label }
        let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+|[^\s]"#)
        var end = label.startIndex
        for match in pattern.matches(in: label, range: NSRange(label.startIndex..., in: label)) {
            guard let range = Range(match.range, in: label), label.distance(from: label.startIndex, to: range.upperBound) <= 23 else { break }
            end = range.upperBound
        }
        return label[..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
    /// Read exactly the first object; discard prose without putting it in state or diagnostics.
    static func parseAnswer(_ response: String) throws -> FileDropAnswer {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{") else { throw CocoaError(.fileReadCorruptFile) }
        var depth = 0, quoted = false, escaped = false
        for index in text[start...].indices {
            let character = text[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return try JSONDecoder().decode(FileDropAnswer.self, from: Data(text[start...index].utf8))
                }
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}

struct FileDropContext: Codable {
    var memories: [String]
    var outcomes: [String: String]
    var agentRoles: [String: [String]]? = nil
    var works: [String]? = nil
}

enum FileDropClaude {
    static func context(_ signals: FileDropSignals, home: URL, remote: RemoteHermes?) async throws -> FileDropContext {
        guard !signals.sensitive else { throw FileDropServiceError.sensitive }
        let s = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signals))
        let input = try JSONSerialization.data(withJSONObject: ["mode": "context", "signals": s])
        let result = try await Task.detached(priority: .userInitiated) {
            if let remote { return try remote.suggestDrop(input, files: []) }
            return try FileDropRunner.run(input, home: home)
        }.value
        return try JSONDecoder().decode(FileDropContext.self, from: result)
    }

    static func request(_ signals: FileDropSignals, files: [URL], home: URL, remote: RemoteHermes?) async throws -> FileDropAnswer {
        guard !signals.sensitive else { throw FileDropServiceError.sensitive }
        var signals = signals
        let originals = Array(files.filter {
            let size = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            return size <= 20 * 1024 * 1024 && (["pdf", "png", "jpg", "jpeg", "hwp", "hwpx", "xlsx"].contains($0.pathExtension.lowercased()) || signals.unread.contains($0.lastPathComponent))
        }.prefix(5))
        func encode() throws -> Data {
            let s = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signals))
            return try JSONSerialization.data(withJSONObject: ["signals": s, "files": originals.map(\.path), "deadline": Date().addingTimeInterval(15).timeIntervalSince1970])
        }
        var data = try encode()
        while data.count > 60 * 1024 && !signals.content.isEmpty {
            signals.content = String(signals.content.prefix(max(0, signals.content.count - 1000))); signals.truncated = true; signals.partial = true
            data = try encode()
        }
        guard data.count <= 60 * 1024 else { throw FileDropServiceError.unavailable }
        let input = data
        let result = try await Task.detached(priority: .userInitiated) {
            if let remote { return try remote.suggestDrop(input, files: originals) }
            return try FileDropRunner.run(input, home: home)
        }.value
        return try JSONDecoder().decode(FileDropAnswer.self, from: result)
    }
}
