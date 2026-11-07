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
            validate(try JSONSerialization.jsonObject(with: Data(json.utf8)), schema)
            print("Authoritative connections-status.json matches the Swift decoder fixture")
        }
        if CommandLine.arguments.count > 2 {
            let source = URL(fileURLWithPath: CommandLine.arguments[2])
            for name in ["AgentConnections.swift", "AgentConnectionsView.swift"] {
                let code = try String(contentsOf: source.appendingPathComponent(name), encoding: .utf8)
                for secret in [".env", "auth.json", "google_token", "client_secret"] {
                    assert(!code.contains("\"" + secret), "Connection UI must not access secret file paths")
                }
            }
            print("Connection source contains no secret-file path literals")
        }
        let document = try AgentConnectionDocument.decode(Data(json.utf8))
        assert(document.agents[0].summary == "다시 연결 필요")
        assert(document.agents[0].connections[0].canReconnect)
        for state in ["connected", "needs_reconnect", "not_connected", "unknown", "off"] {
            let value = try AgentConnectionDocument.decode(Data(json.replacingOccurrences(of: "needs_reconnect", with: state).utf8))
            assert(!value.agents[0].connections[0].state.title.isEmpty)
        }
        for invalid in [json.replacingOccurrences(of: "hermes-connections/1", with: "wrong/1"),
                        json.replacingOccurrences(of: "needs_reconnect", with: "invented"), "{}"] {
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
    }
}
