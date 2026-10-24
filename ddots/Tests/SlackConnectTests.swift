import Foundation

@main struct SlackConnectTests {
    static func main() {
        let token = "xoxp-" + String(repeating: "a", count: 30)
        precondition(SlackConnect.tokenCandidate(token) == token)
        precondition(SlackConnect.tokenCandidate(" \n" + token + "\n ") == token)
        precondition(SlackConnect.tokenCandidate("xoxe." + token) == "xoxe." + token)
        for input in ["", " ", "xoxb-" + String(repeating: "b", count: 30), token + " " + token, token + "\n" + token, "prefix " + token] {
            precondition(SlackConnect.tokenCandidate(input) == nil)
        }
        precondition(SlackConnect.tokenCandidate(nil) == nil)
        let manifest = "{\"display_information\":{\"name\":\"캐릭터 + & # ? = %\"}}"
        let url = SlackConnect.manifestURL(manifest)
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        precondition(parts.host == "api.slack.com" && parts.scheme == "https")
        precondition(parts.queryItems?.first(where: { $0.name == "new_app" })?.value == "1")
        precondition(parts.queryItems?.first(where: { $0.name == "manifest_json" })?.value == manifest)
        precondition(url.absoluteString.contains("%2B") && url.absoluteString.contains("%26"))
        precondition(SlackConnect.manifestURL(nil).absoluteString == "https://api.slack.com/apps?new_app=1")
        precondition(SlackConnect.manifestURL("invalid").absoluteString == "https://api.slack.com/apps?new_app=1")
        print("SlackConnectTests passed: user token selection/rejection and manifest URL round trip; credentials never printed")
    }
}
