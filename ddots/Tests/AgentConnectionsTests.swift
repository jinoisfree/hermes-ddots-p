import Foundation

@main struct AgentConnectionsTests {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let now = ISO8601DateFormatter().date(from: "2026-11-07T03:00:00Z")!
        assert(ConnectionTime.label("2026-11-07T02:59:40.123+00:00", now: now, calendar: calendar) == "방금 확인")
        assert(ConnectionTime.label("2026-11-07T02:00:00Z", now: now, calendar: calendar) == "11:00 확인")
        assert(ConnectionTime.label("2026-11-06T02:00:00Z", now: now, calendar: calendar) == "11월 6일 11:00 확인")
        assert(ConnectionTime.label("2026-11-07 11:00:00", now: now, calendar: calendar) == "11:00 확인")
        assert(ConnectionTime.label("bad", now: now, calendar: calendar) == "확인 시각 알 수 없음")
        print("ConnectionTime: recent, local today, previous day, gateway log, invalid passed")
        let json = #"{"schema":"hermes-connections/1","checked_at":"2026-11-07T00:00:00Z","agents":[{"profile":"example","display_name":"시험 에이전트","connections":[{"id":"google","group":"account","service":"google","label":"Google","account":"test@example.test","scope":"personal","state":"needs_reconnect","reason":"SCOPE_MISSING","checked_at":"2026-11-07T00:00:00Z","capabilities":["조회"],"rules":["승인 유지"],"reconnect":"personal"}]}]}"#
        let current = json.replacingOccurrences(of: #""reconnect":"personal"}"#, with: #""reconnect":"personal","connect_kind":"oauth","verified_by":"google_check","actions":[{"id":"oauth_connect","label":"권한 업데이트","primary":true},{"id":"check","label":"확인","primary":false}]}"#)
        // Consume the command's authoritative schema when supplied by the private integration run.
        if CommandLine.arguments.count > 1 {
            let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
            func validate(_ value: Any, _ spec: [String: Any]) {
                if let constant = spec["const"] as? String { assert(value as? String == constant) }
                if let values = spec["enum"] as? [Any] {
                    assert(values.contains { ($0 as! NSObject).isEqual(value) })
                }
                if let object = value as? [String: Any], let properties = spec["properties"] as? [String: [String: Any]] {
                    assert(Set(spec["required"] as? [String] ?? []).isSubset(of: Set(object.keys)))
                    if spec["additionalProperties"] as? Bool == false { assert(Set(object.keys).isSubset(of: Set(properties.keys))) }
                    for (key, item) in object { if let property = properties[key] { validate(item, property) } }
                }
                if let items = value as? [Any], let itemSpec = spec["items"] as? [String: Any] {
                    items.forEach { validate($0, itemSpec) }
                }
            }
            validate(try JSONSerialization.jsonObject(with: Data(current.utf8)), schema)
            print("Authoritative connections-status.json matches the Swift decoder fixture")
        }
        if CommandLine.arguments.count > 2 {
            let source = URL(fileURLWithPath: CommandLine.arguments[2])
            for name in ["AgentConnections.swift", "AgentConnectionsView.swift", "AgentConnectionActions.swift"] {
                let code = try String(contentsOf: source.appendingPathComponent(name), encoding: .utf8)
                for secret in [".env", "auth.json", "google_token", "client_secret"] {
                    assert(!code.contains("\"" + secret), "Connection UI must not access secret file paths")
                }
            }
            print("Connection source contains no secret-file path literals")
        }
        let document = try AgentConnectionDocument.decode(Data(current.utf8))
        for name in ["AgentConnections.swift", "AgentConnectionsView.swift", "AgentConnectionActions.swift"] where CommandLine.arguments.count > 2 {
            let code = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(name), encoding: .utf8)
            assert(!code.contains("canReconnect"), "state-based reconnect guess was replaced by actions")
        }
        assert(document.agents[0].summary == "다시 연결 필요")
        let first = document.agents[0].connections[0]
        assert(first.action(.oauthConnect)?.label == "권한 업데이트" && first.primaryAction?.id == "oauth_connect")
        assert(first.otherActions.map(\.id) == ["check"] && first.primaryAction?.resolves == true && first.action(.check)?.resolves == false)
        // Output from an older command has no new fields: it still decodes and offers no buttons.
        let old = try AgentConnectionDocument.decode(Data(json.utf8)).agents[0].connections[0]
        assert(old.actions == nil && old.primaryAction == nil && old.connect_kind == nil)
        // A button kind this app does not know is not drawn.
        let unknown = try AgentConnectionDocument.decode(Data(current.replacingOccurrences(of: "\"id\":\"check\"", with: "\"id\":\"future_action\"").utf8))
        assert(unknown.agents[0].connections[0].otherActions.isEmpty)
        for state in ["connected", "needs_reconnect", "not_connected", "unknown", "off"] {
            let value = try AgentConnectionDocument.decode(Data(current.replacingOccurrences(of: "needs_reconnect", with: state).utf8))
            assert(!value.agents[0].connections[0].state.title.isEmpty)
        }
        for invalid in [current.replacingOccurrences(of: "hermes-connections/1", with: "wrong/1"),
                        current.replacingOccurrences(of: "needs_reconnect", with: "invented"), "{}"] {
            do { _ = try AgentConnectionDocument.decode(Data(invalid.utf8)); fatalError("invalid accepted") } catch {}
        }
        for url in ["https://accounts.google.com.evil.test/o/oauth2/auth", "http://accounts.google.com/o/oauth2/auth", "https://evil.test/", "https://accounts.google.com/other"] {
            let data = try JSONSerialization.data(withJSONObject: ["state": "running", "url": url])
            let reply = try JSONDecoder().decode(AgentReconnectReply.self, from: data)
            assert(reply.loginURL == nil)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = root.appendingPathComponent("fake-command")
        try Data("#!/bin/sh\nprintf '%s' '\(json)'\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let output = try AgentConnectionDocument.decode(AgentConnectionCommand.run(executable: command, arguments: []))
        assert(output.agents.count == 1)
        try Data("#!/bin/sh\nexit 4\n".utf8).write(to: command)
        do { _ = try AgentConnectionCommand.run(executable: command, arguments: []); fatalError("exit accepted") } catch ConnectionFailure.command {}
        try Data("#!/bin/sh\nexec sleep 5\n".utf8).write(to: command)
        let began = Date()
        do { _ = try AgentConnectionCommand.run(executable: command, arguments: [], timeout: 0.1); fatalError("timeout accepted") } catch ConnectionFailure.timeout {}
        assert(Date().timeIntervalSince(began) < 1)
        do { _ = try AgentConnectionCommand.run(executable: root.appendingPathComponent("absent"), arguments: []); fatalError("absent accepted") } catch ConnectionFailure.missing {}
        let gate = DispatchSemaphore(value: 0), finished = DispatchGroup(), lock = NSLock()
        var calls = 0, results = 0
        let cache = AgentConnectionCache {
            lock.lock(); calls += 1; lock.unlock()
            gate.wait(); return document
        }
        for _ in 0..<8 {
            finished.enter()
            cache.read { reply in
                if case .success = reply { lock.lock(); results += 1; lock.unlock() }
                finished.leave()
            }
        }
        gate.signal()
        assert(finished.wait(timeout: .now() + 2) == .success)
        finished.enter(); cache.read { _ in finished.leave() }
        assert(finished.wait(timeout: .now() + 1) == .success)
        assert(calls == 1 && results == 8)
        print("AgentConnections: schema, states, safe URLs, command failures/timeout, shared 60-second cache passed")

        // Action replies: every code the Hermes command can return has an owner-facing sentence.
        func reply(_ text: String) throws -> AgentActionReply { try AgentActionReply.decode(Data(text.utf8)) }
        let check = try reply(#"{"action":"check","outcome":"done","reason":"OK","check":{"state":"connected","reason":"NOTION_VERIFIED","verified_by":"notion_users_me","checked_at":"2026-11-07T00:00:00Z"}}"#)
        assert(ConnectionSentence.notice(check, label: "Notion") == ActionNotice(success: true, text: "연결을 확인했어요."))
        let publicOnly = try reply(#"{"action":"check","outcome":"done","reason":"OK","check":{"state":"connected","reason":"PUBLIC_ONLY"}}"#)
        assert(ConnectionSentence.notice(publicOnly, label: "X").text.contains("공개 글"))
        let expired = try reply(#"{"action":"check","outcome":"done","reason":"OK","check":{"state":"needs_reconnect","reason":"TOKEN_INVALID"}}"#)
        assert(!ConnectionSentence.notice(expired, label: "Notion").success && ConnectionSentence.notice(expired, label: "Notion").text.contains("토큰"))
        let recent = try reply(#"{"action":"check","outcome":"done","reason":"RECENTLY_CHECKED","check":{"state":"connected","reason":"NOTION_VERIFIED"}}"#)
        assert(ConnectionSentence.notice(recent, label: "Notion").text.contains("방금 확인한 결과"))
        for (reason, fragment) in [("BUSY", "처리 중"), ("BUSY_CHECK_FAILED", "확인하지 못해"), ("FORMAT_INVALID", "형식"), ("TOKEN_INVALID", "저장하지 않았어요"),
                                   ("AUTH_FAILED", "로그인에 실패"), ("COOKIE_EXPIRED", "X 로그인"), ("TIMEOUT", "응답"), ("WRITE_FAILED", "기존 값은 그대로"),
                                   ("NAME_NOT_ALLOWED", "바꿀 수 없어요"), ("EXPIRED", "시간이 지났어요"), ("LAUNCH_FAILED", "권한 확인"), ("OFF", "꺼져"),
                                   ("UNKNOWN_CONNECTION", "찾지 못했어요"), ("RESTART_FAILED", "다시 시도하지 않아요")] {
            let refused = try reply(#"{"action":"secret_set","outcome":"refused","reason":"\#(reason)"}"#)
            let notice = ConnectionSentence.notice(refused, label: "Notion")
            assert(!notice.success && notice.text.contains(fragment), reason)
        }
        let limited = try reply(#"{"action":"gateway_restart","outcome":"refused","reason":"RATE_LIMITED","last_restart_at":1794000000}"#)
        assert(ConnectionSentence.notice(limited, label: "x", now: Date(timeIntervalSince1970: 1794000600), calendar: calendar).text.contains("60분에 한 번"))
        let partial = try reply(#"{"action":"gateway_restart","outcome":"failed","reason":"NOT_RECONNECTED","missing":[{"profile":"a","connection":"slack"}]}"#)
        assert(ConnectionSentence.notice(partial, label: "x").text.contains("a slack"))
        let saved = try reply(#"{"action":"secret_set","outcome":"done","reason":"OK","saved_names":["INSTAGRAM_ACCESS_TOKEN"],"restart_required":true,"undo_until":"2026-11-07T03:10:00Z"}"#)
        assert(ConnectionSentence.notice(saved, label: "Instagram").text.contains("다시 시작해야") && saved.undoDeadline != nil)
        let restarted = try reply(#"{"action":"gateway_restart","outcome":"done","reason":"OK","connected":7}"#)
        assert(ConnectionSentence.notice(restarted, label: "x").text.contains("7개"))
        let granted = try reply(#"{"action":"permission_request","outcome":"done","reason":"OK","check":{"state":"connected","reason":"PERMISSION_GRANTED"}}"#)
        let denied = try reply(#"{"action":"permission_request","outcome":"done","reason":"OK","check":{"state":"not_connected","reason":"PERMISSION_DENIED"}}"#)
        assert(ConnectionSentence.notice(granted, label: "x").success && !ConnectionSentence.notice(denied, label: "x").success)
        let all = [check, expired]
        assert(ConnectionSentence.summary(all).text == "2개를 확인했어요. 1개 연결됨, 1개는 확인이 필요해요." && !ConnectionSentence.summary(all).success)
        assert(ConnectionSentence.summary([check]).success)
        // Settings addresses: only privacy panes of System Settings are ever opened.
        let pane = try reply(#"{"outcome":"done","reason":"OK","url":"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"}"#)
        assert(pane.settingsURL != nil)
        for bad in ["https://evil.test/", "x-apple.systempreferences:com.apple.Software-Update-Settings.extension", "file:///etc/passwd", "x-apple.systempreferences:com.apple.preference.security?Other"] {
            let other = try reply("{\"outcome\":\"done\",\"reason\":\"OK\",\"url\":\"" + bad + "\"}")
            assert(other.settingsURL == nil, bad)
        }
        do { _ = try AgentActionReply.decode(Data("not json".utf8)); fatalError("garbage accepted") } catch ConnectionFailure.invalid {}
        // Every reason code the Hermes command emits has its own wording or falls back to the account/state.
        for reason in ["NO_TOKEN", "TOKEN_INVALID", "AUTH_FAILED", "COOKIE_EXPIRED", "FORMAT_INVALID", "NETWORK", "RATE_LIMITED", "SERVER_ERROR", "PUBLIC_ONLY",
                       "PERMISSION_DENIED", "NOT_DETERMINED", "TARGET_UNAVAILABLE"] { assert(ConnectionSentence.explanation(reason) != nil, reason) }
        // A revoked Slack token is fixed in Slack's app settings; other kinds keep the generic token sentence.
        assert(ConnectionSentence.explanation("TOKEN_INVALID", kind: "channel") == "Slack 앱 설정에서 앱을 다시 설치해 주세요")
        assert(ConnectionSentence.explanation("TOKEN_INVALID", kind: "secret") == "저장된 토큰이 맞지 않아요")
        assert(ConnectionSentence.notice(expired, label: "Slack", kind: "channel").text.contains("앱을 다시 설치"))
        let slackJson = json.replacingOccurrences(of: #""reconnect":"personal"}"#, with: #""reconnect":null,"connect_kind":"channel","actions":[{"id":"check","label":"확인","primary":true}]}"#)
            .replacingOccurrences(of: "SCOPE_MISSING", with: "TOKEN_INVALID")
        let slackRow = try AgentConnectionDocument.decode(Data(slackJson.utf8)).agents[0].connections[0]
        assert(slackRow.explanation == "Slack 앱 설정에서 앱을 다시 설치해 주세요" && slackRow.primaryAction?.kind == .check && slackRow.action(.gatewayRestart) == nil)
        // Command lines: names and ids only; secret values and time limits.
        assert(ConnectionCommands.check("a", "notion") == ["check", "--profile", "a", "--connection", "notion", "--json"])
        assert(ConnectionCommands.secret("set", "a", "notion") == ["secret", "set", "--profile", "a", "--connection", "notion", "--json"])
        assert(ConnectionCommands.restart == ["gateway", "restart", "--json"])
        assert(ConnectionCommands.timeout(ConnectionCommands.check("a", "x")) == 30 && ConnectionCommands.timeout(ConnectionCommands.checkAll("a")) == 90)
        assert(ConnectionCommands.timeout(ConnectionCommands.secret("set", "a", "x")) == 30 && ConnectionCommands.timeout(ConnectionCommands.permission("request", "a", "x")) == 130)
        assert(ConnectionCommands.timeout(ConnectionCommands.permission("settings", "a", "x")) == 30 && ConnectionCommands.timeout(ConnectionCommands.restart) == 150)
        // A secret value reaches the command only through standard input.
        let sink = root.appendingPathComponent("stdin.out").path
        try Data("#!/bin/sh\ncat > '\(sink)'\nprintf '{\"outcome\":\"done\",\"reason\":\"OK\"}'\nprintf '%s' \"$*\" > '\(sink).args'\n".utf8).write(to: command)
        let canary = "SECRET-CANARY-\(UUID().uuidString)"
        let args = ConnectionCommands.secret("set", "a", "notion")
        let answer = try AgentConnectionCommand.run(executable: command, arguments: args, timeout: 5, input: Data(("{\"token\":\"" + canary + "\"}").utf8))
        assert(String(data: answer, encoding: .utf8)?.contains("done") == true)
        let received = try String(contentsOfFile: sink, encoding: .utf8), argumentsSeen = try String(contentsOfFile: sink + ".args", encoding: .utf8)
        assert(received.contains(canary) && !argumentsSeen.contains(canary))
        assert(!ProcessInfo.processInfo.environment.values.contains { $0.contains(canary) })
        let guideReply = try AgentActionReply.decode(Data(#"{"outcome":"done","reason":"OK","guide":[{"n":4,"text":"복사하세요.","check":{"field":"token","pattern":"^xoxp-[a-z]+$","message":"4번 단계의 사용자 토큰이에요."}}]}"#.utf8))
        assert(guideReply.guide?.items.count == 1)
        assert(guideReply.guide?.error(["token":"wrong"]) == "4번 단계의 사용자 토큰이에요.")
        assert(guideReply.guide?.error(["token":"xoxp-valid"]) == nil)
        assert(guideReply.guide?.error(["token":"xoxp-valid\n"]) != nil)
        let legacyGuide = try AgentActionReply.decode(Data(#"{"outcome":"done","reason":"OK","guide":{"steps":["이전 안내"],"link":"https://example.test"}}"#.utf8))
        assert(legacyGuide.guide?.items.first?.text == "이전 안내")
        print("AgentConnections: action sentences, safe settings URLs, command lines/time limits, stdin-only secret passed")
    }
}
