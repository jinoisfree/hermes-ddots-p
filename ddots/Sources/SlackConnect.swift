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

    /// Slack documents manifest_json at https://api.slack.com/reference/manifests.
    static func manifestURL(_ manifest: String?) -> URL {
        var parts = URLComponents(string: "https://api.slack.com/apps")!
        parts.queryItems = [URLQueryItem(name: "new_app", value: "1")]
        if let manifest, let data = manifest.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            parts.queryItems?.append(URLQueryItem(name: "manifest_json", value: manifest))
        }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
}
