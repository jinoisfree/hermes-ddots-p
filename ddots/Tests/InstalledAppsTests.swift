import Foundation

@main struct InstalledAppsTests {
    static func main() throws {
        let json = #"""
        {"schema":"hermes-installed-apps/1","scanned_at":"2026-11-07T00:00:00Z","apps":[
         {"name":"Mail","bundle_id":"com.apple.mail","kind":"mac","features":{"applescript":true,"app_intents":true,"url_schemes":true},
          "links":[{"profile":"personal-secretary","connection":"mail_read","state":"off"},{"profile":"work-assistant","connection":"mail_read","state":"connected"}]},
         {"name":"Synology Drive Client","bundle_id":"com.example.drive","kind":"mac","features":{"applescript":false,"app_intents":false,"url_schemes":false},
          "links":[{"profile":"personal-secretary","connection":"synology","state":"off"}]},
         {"name":"Safari","bundle_id":"com.apple.Safari","kind":"mac","features":{"applescript":true,"app_intents":false,"url_schemes":true},"links":[]},
         {"name":"피클","bundle_id":"com.pickle.client","kind":"ios_wrapped","features":{"applescript":false,"app_intents":true,"url_schemes":true},"links":[]}]}
        """#
        let document = try InstalledAppDocument.decode(Data(json.utf8))
        assert(document.connectable.map(\.name) == ["Mail", "Synology Drive Client"] && document.others.map(\.name) == ["Safari", "피클"])
        // An app opens the first connection that is on; when every one is off, the first one.
        assert(document.apps[0].primaryLink == InstalledApp.Link(profile: "work-assistant", connection: "mail_read", state: .connected))
        assert(document.apps[1].primaryLink?.profile == "personal-secretary" && document.apps[1].primaryLink?.state == .off)
        assert(document.apps[2].primaryLink == nil)
        // Other apps carry information only.
        assert(document.apps[2].infoTags == ["AppleScript"] && document.apps[3].infoTags == ["단축어"] && document.apps[3].kind == "ios_wrapped")
        assert(InstalledAppsText.noDirectFeature == "이 앱과 직접 연동하는 기능은 아직 없어요.")
        for invalid in [json.replacingOccurrences(of: "hermes-installed-apps/1", with: "wrong/1"),
                        json.replacingOccurrences(of: "\"bundle_id\":\"com.apple.Safari\"", with: "\"bundle_id\":\"com.apple.mail\""),
                        json.replacingOccurrences(of: "\"state\":\"connected\"", with: "\"state\":\"invented\""), "{}", "not json"] {
            do { _ = try InstalledAppDocument.decode(Data(invalid.utf8)); fatalError("invalid accepted") } catch ConnectionFailure.invalid {}
        }
        assert(ConnectionCommands.apps == ["apps", "--json"] && ConnectionCommands.timeout(ConnectionCommands.apps) == 30)
        // The command's real output has no secret or path: only names, ids and states.
        for secret in [NSHomeDirectory(), "token", "password"] { assert(!json.lowercased().contains(secret.lowercased())) }
        // A synthetic folder of 600 apps stays under the size cap the decoder enforces.
        let many = (0..<600).map { #"{"name":"App\#($0)","bundle_id":"id.\#($0)","kind":"mac","features":{"applescript":false,"app_intents":false,"url_schemes":false},"links":[]}"# }.joined(separator: ",")
        let big = #"{"schema":"hermes-installed-apps/1","scanned_at":"x","apps":["# + many + "]}"
        let decodedBig = try InstalledAppDocument.decode(Data(big.utf8))
        assert(decodedBig.apps.count == 600)
        print("InstalledApps: grouping, primary link, info tags, strict decode passed")
    }
}
