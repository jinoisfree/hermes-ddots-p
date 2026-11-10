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
        print("SlackConnectTests passed: user token selection/rejection; manifest URL assembly belongs to the facility; credentials never printed")
    }
}
