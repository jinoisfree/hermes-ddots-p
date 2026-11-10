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
        let roster = #"""
        {"schema":"hermes-installed-apps/1","scanned_at":"now","apps":[],"agents":[
          {"profile":"new-staff","role_hint":"선택한 직책 안내","connected":[
            {"bundle_id":"service:obsidian-notes","name":"보관함","state":"connected","route":"tool","can_do":"메모","rules":[]}],
           "connectable":[{"bundle_id":"new.app","name":"새 앱","state":"connectable","route":"sdef","can_do":"앱 기능","rules":[],"tools":["mac_app"]}],
           "unavailable":[{"bundle_id":"missing.app","name":"없는 앱","state":"unavailable","route":"none","reason":"연결 방법이 없어요"}]}]}
        """#
        let group = try InstalledAppDocument.decode(Data(roster.utf8)).agents!.first!
        assert(group.profile == "new-staff" && group.all.count == 3 && group.connected[0].connected)
        assert(group.connectable[0].available && !group.unavailable[0].available)
        assert(AppConnectionCommands.apps(selfID: "viewer") == ["apps", "--json", "--self", "viewer"])
        let args = AppConnectionCommands.action("connect", profile: "new-staff", app: "new.app", accounts: ["a", "b"], scopes: ["x", "y"], defaultID: "y", values: true)
        assert(args == ["app", "connect", "--profile", "new-staff", "--app", "new.app", "--json", "--account", "a", "--account", "b", "--scope", "x", "--scope", "y", "--default", "y", "--values-stdin"])
        let waiting = #"""
        {"profile":"new-staff","app":"new.app","outcome":"waiting","reason":"CHOOSE_SCOPE","steps":[
          {"id":"values","label":"쓸 곳 고르기","state":"todo","reason":"직접 골라 주세요","needs_user":true,"hint":"선택 후 계속"}],
         "next":{"kind":"choose_scope","options":[{"id":"x","label":"사용 가능"},{"id":"y","label":"동기화 필요","disabled":true,"hint":"동기화해 주세요"}],"needs_default":true},"undo_until":null}
        """#
        let flow = try AppConnectionReply.decode(Data(waiting.utf8))
        var pendingDocument = try JSONSerialization.jsonObject(with: Data(roster.utf8)) as! [String: Any]
        var pendingAgents = pendingDocument["agents"] as! [[String: Any]]
        var pendingApps = pendingAgents[0]["connectable"] as! [[String: Any]]
        pendingApps[0]["progress"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(flow))
        pendingAgents[0]["connectable"] = pendingApps; pendingDocument["agents"] = pendingAgents
        let reopened = try InstalledAppDocument.decode(JSONSerialization.data(withJSONObject: pendingDocument)).agents![0].connectable[0]
        assert(reopened.progress?.next.kind == "choose_scope" && reopened.progress?.steps.first?.needs_user == true)
        assert(flow.steps.first?.needs_user == true && flow.next.options?.last?.disabled == true && flow.next.needs_default == true)
        assert(flow.next.loginURL == nil)
        for pane in ["automation", "calendars", "contacts", "full_disk_access", "internet_accounts"] {
            for kind in ["open_settings", "permission_request"] {
                let next: [String: Any] = ["kind": kind, "pane": pane, "url": "x-apple.systempreferences:fixture", "target": "Observed subject → App", "hint": "직접 켜 주세요"]
                let value: [String: Any] = ["profile": "new-staff", "app": "new.app", "outcome": "waiting", "reason": "PERMISSION_DENIED", "steps": [], "next": next]
                let parsed = try AppConnectionReply.decode(JSONSerialization.data(withJSONObject: value))
                assert(parsed.next.pane == pane && parsed.next.target == "Observed subject → App" && parsed.next.hint == "직접 켜 주세요" && parsed.next.settingsURL != nil)
            }
        }
        // A fresh credential input survives an equal/older inventory response.
        func pending(_ kind: String, _ done: [String]) throws -> AppConnectionReply {
            let steps = ["address", "login"].map { ["id": $0, "label": $0, "state": done.contains($0) ? "done" : "todo", "needs_user": false] as [String: Any] }
            return try AppConnectionReply.decode(JSONSerialization.data(withJSONObject: ["profile": "test", "app": "test", "outcome": "waiting", "reason": "VALUES_REQUIRED", "steps": steps, "next": ["kind": kind]]))
        }
        let login = try pending("secret_set", ["address"])
        let older = try pending("resume", []); assert(!login.acceptsProgress(older))
        let equal = try pending("resume", ["address"]); assert(!login.acceptsProgress(equal))
        let newer = try pending("resume", ["address", "login"]); assert(login.acceptsProgress(newer))
        let choosing = try pending("choose_scope", ["address"]); assert(!choosing.acceptsProgress(older))
        let prefill: [String: Any] = ["profile":"test", "app":"test", "outcome":"waiting", "reason":"VALUES_REQUIRED", "steps":[], "next":["kind":"secret_set", "fields":[["id":"api_base", "label":"주소", "secure":false, "value":"https://nas.example.test"], ["id":"password", "label":"비밀번호", "secure":true, "value":"must-not-prefill"]]]]
        let prefilled = try AppConnectionReply.decode(JSONSerialization.data(withJSONObject: prefill))
        assert(prefilled.next.prefilledValues == ["api_base":"https://nas.example.test"])
        assert(!prefilled.next.canSubmit(prefilled.next.prefilledValues))
        assert(prefilled.next.canSubmit(prefilled.next.prefilledValues.merging(["password":"synthetic-only"]) { _, edited in edited }))
        assert(!prefilled.next.canSubmit(["password":"synthetic-only"]))
        var retry = prefill
        retry["reason"] = "AUTH_FAILED"
        let sameStage = try AppConnectionReply.decode(JSONSerialization.data(withJSONObject: retry))
        assert(prefilled.inputStage == sameStage.inputStage)
        retry["next"] = ["kind":"secret_set", "fields":[["id":"user", "label":"아이디", "secure":true]]]
        let differentFields = try AppConnectionReply.decode(JSONSerialization.data(withJSONObject: retry))
        assert(prefilled.inputStage != differentFields.inputStage)
        assert(!differentFields.next.canSubmit([:]))
        assert(!differentFields.next.canSubmit(["user":""]))
        assert(differentFields.next.canSubmit(["user":"test"]))
        print("InstalledApps: grouping, primary link, info tags, strict decode passed")
    }
}
