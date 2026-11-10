import Foundation

enum SlackConnect {
    static func tokenCandidate(_ input: String?) -> String? {
        guard let input else { return nil }
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "-.").union(.alphanumerics)
        guard token.hasPrefix("xoxp-") || token.hasPrefix("xoxe.xoxp-"), (20...400).contains(token.count),
              token.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return token
    }

}
