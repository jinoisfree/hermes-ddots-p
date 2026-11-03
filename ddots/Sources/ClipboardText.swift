import Foundation

enum ClipboardTextTransform: String, CaseIterable {
    case whitespace = "공백 정리", singleLine = "줄바꿈 없애기", uppercase = "대문자", lowercase = "소문자", json = "JSON 보기 좋게"
    func apply(_ text: String) -> String? {
        switch self {
        case .whitespace: return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        case .singleLine: return text.components(separatedBy: .newlines).joined(separator: " ")
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .json:
            guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
                  let result = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return nil }
            return String(data: result, encoding: .utf8)
        }
    }
}
