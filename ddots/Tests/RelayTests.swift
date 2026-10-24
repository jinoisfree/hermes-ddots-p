import AppKit
import Foundation
import ImageIO
import Network
import SQLite3

@main struct RelayTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed += 1
    }
    static func execute(_ url: URL, _ statements: [String]) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        for sql in statements { precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sql) }
        sqlite3_close(db)
    }
    /// Polls until the condition holds and returns how long that took, or nil after the deadline.
    static func wait(_ seconds: Double, _ condition: () -> Bool) -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if condition() { return Date().timeIntervalSince(start) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
    static func main() throws {
        // Wire format and settings
        var buffer = Data("{\"op\":\"hello\",\"token\":\"t\"}\n{\"op\":\"wat".utf8)
        var frames = RelayFrame.take(from: &buffer)
        check(frames.count == 1 && frames[0]?.op == "hello" && frames[0]?.token == "t", "complete line is decoded")
        check(String(data: buffer, encoding: .utf8) == "{\"op\":\"wat", "partial line waits for the rest")
        buffer.append(Data("ch\"}\nnot json\n".utf8)); frames = RelayFrame.take(from: &buffer)
        check(frames.count == 2 && frames[0]?.op == "watch" && frames[1] == nil && buffer.isEmpty, "bad line is reported, not skipped")
        let original = ChatMessage(id: "archive-helper:7", fromUser: false, speaker: "보관담당", body: "줄1\n줄2 \"따옴표\"", date: Date(timeIntervalSince1970: 123.5), sessionID: "s1", replyInterrupted: true)
        var carrier = RelayFrame(op: "state"); carrier.messages = [RelayFrame.Message(original)]
        var encoded = carrier.line()
        check(encoded.filter { $0 == 0x0A }.count == 1, "a message with line breaks stays one line")
        check(RelayFrame.take(from: &encoded).first??.messages?.first?.message == original, "message survives the round trip")
        var avatar = ProfileAvatar(); avatar.hasProfileColor = true; avatar.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let restored = RelayFrame.Avatar(avatar).avatar
        check(restored.hasProfileColor && abs(restored.color.greenComponent - 0.4) < 0.01 && restored.image == nil, "profile color survives without a photo")
        let token = String(repeating: "ab", count: 32)
        check(RelaySettings.validToken(" " + token.uppercased() + "\n") == token && RelaySettings.validToken("abc") == nil, "code is 64 hex digits")
        check(RelaySettings.matches(token, token) && !RelaySettings.matches(token, String(repeating: "ac", count: 32)) && !RelaySettings.matches(token, "ab"), "code comparison")
        check(RelaySettings.isTailnet("100.64.0.1") && RelaySettings.isTailnet("100.127.255.254") && !RelaySettings.isTailnet("100.128.0.1") && !RelaySettings.isTailnet("192.168.0.2") && !RelaySettings.isTailnet("100.64.1"), "tailnet range")
        check(RelaySettings.tailnetAddress(among: [("en0", "100.70.1.2"), ("utun3", "10.0.0.2"), ("utun4", "100.79.1.2")]) == "100.79.1.2"
              && RelaySettings.tailnetAddress(among: [("en0", "100.70.1.2"), ("pdp_ip0", "100.100.1.1")]) == nil, "only an address on a tunnel interface is taken for Tailscale's")
        check(RelaySettings.validHost("mini.tail-net.ts.net") == "mini.tail-net.ts.net" && RelaySettings.validHost("a b") == nil && RelaySettings.validHost("x/y") == nil && RelaySettings.validHost("") == nil, "host name form")
        let plist = RelayAgent.plist(executable: "/x/ddots", port: 5, log: "/x/relay.log")
        check(plist["StandardOutPath"] as? String == "/x/relay.log" && plist["StandardErrorPath"] as? String == "/x/relay.log", "launch agent keeps a log")
        check(plist["ProgramArguments"] as? [String] == ["/x/ddots", "--relay", "--relay-port", "5"] && plist["Label"] as? String == AppIdentity.bundleID + ".relay", "launch agent runs the relay mode")
        let tokenFile = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-relay-token-\(UUID().uuidString)/code")
        defer { try? FileManager.default.removeItem(at: tokenFile.deletingLastPathComponent()) }
        try RelaySettings.writeToken(token, to: tokenFile)
        let mode = (try FileManager.default.attributesOfItem(atPath: tokenFile.path)[.posixPermissions] as? NSNumber)?.intValue
        check(mode == 0o600 && RelaySettings.readToken(tokenFile) == token, "code file is private to the user")
        let second = String(repeating: "ab", count: 32)
        try RelaySettings.writeToken(second, to: tokenFile)
        let replacedMode = (try FileManager.default.attributesOfItem(atPath: tokenFile.path)[.posixPermissions] as? NSNumber)?.intValue
        let beside = try FileManager.default.contentsOfDirectory(atPath: tokenFile.deletingLastPathComponent().path)
        check(replacedMode == 0o600 && RelaySettings.readToken(tokenFile) == second && beside == ["code"], "a new code takes the old one's place and leaves nothing beside it")

        // Synthetic Hermes record
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let schema = ["CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL)",
                      "CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_calls TEXT, timestamp REAL)",
                      "INSERT INTO sessions VALUES ('s1', 'photon'), ('s2', 'slack')"]
        let now = Date().timeIntervalSince1970
        execute(home.appendingPathComponent("state.db"), schema + [
            "INSERT INTO messages VALUES (1, 's1', 'user', '합성 질문', NULL, \(now - 600))",
            "INSERT INTO messages VALUES (2, 's1', 'assistant', '합성 답변', NULL, \(now - 590))",
            "INSERT INTO messages VALUES (3, 's2', 'assistant', 'SLACK ONLY', NULL, \(now - 580))"])
        // A real photo, written without AppKit drawing so the test process stays windowless too.
        let pixels = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); pixels.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let photo = CGImageDestinationCreateWithURL(home.appendingPathComponent("assets/avatar.png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(photo, pixels.makeImage()!, nil); precondition(CGImageDestinationFinalize(photo))
        try "display_name: '위키담당'\nui_meta:\n  hermes-bots:\n    color: '#336699'\n".write(to: home.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)
        let knight = home.appendingPathComponent("profiles/archive-helper")
        execute(knight.appendingPathComponent("state.db"), schema + ["INSERT INTO messages VALUES (1, 's1', 'assistant', '정상.', NULL, \(now - 500))"])
        try "display_name: 보관담당\n".write(to: knight.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)

        let portraitFile = home.appendingPathComponent("kept/portraits.json")
        let portraits = RelayPortraits(url: portraitFile)
        var portraitFrame = RelayFrame(op: "state")
        var photoAvatar = avatar; photoAvatar.thumbnail = pixels.makeImage()
        portraitFrame.avatars = ["default": RelayFrame.Avatar(photoAvatar)]
        portraitFrame.characters = [RelayFrame.Character(id: "default", name: "위키담당")]
        portraitFrame.messages = [RelayFrame.Message(original)]
        portraits.receive(portraitFrame, fromRelay: false)
        check(!FileManager.default.fileExists(atPath: portraitFile.path), "local sources never write portraits")
        portraits.receive(portraitFrame, fromRelay: true)
        let keptData = try Data(contentsOf: portraitFile)
        let keptJSON = try JSONSerialization.jsonObject(with: keptData) as! [String: Any]
        check(Set(keptJSON.keys) == Set(["version", "characters", "avatars"]), "only names and avatars are persisted, never messages")
        check((try? FileManager.default.attributesOfItem(atPath: portraitFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "portrait file permissions are 0600")
        let stamp = try FileManager.default.attributesOfItem(atPath: portraitFile.path)[.modificationDate] as! Date
        Thread.sleep(forTimeInterval: 0.02)
        portraits.receive(portraitFrame, fromRelay: true)
        check((try? FileManager.default.attributesOfItem(atPath: portraitFile.path)[.modificationDate] as? Date) == stamp, "identical relay portraits do not rewrite the file")
        let empty = HermesBridge.PollResult(status: .unavailable("offline"), messages: [])
        let restoredPortraits = RelayPortraits(url: portraitFile).merging(empty)
        check(restoredPortraits.avatars["default"]?.image != nil && restoredPortraits.characters.first?.name == "위키담당", "offline restart restores photos and character names")
        check(restoredPortraits.messages.isEmpty && restoredPortraits.typing.isEmpty && restoredPortraits.receipts.isEmpty && restoredPortraits.status == empty.status, "merge never restores chat activity or connection state")
        var local = empty; local.avatars = ["default": ProfileAvatar(), "local": photoAvatar]; local.characters = [ChatCharacter(id: "local", name: "로컬")]
        let merged = portraits.merging(local)
        check(merged.avatars["default"]?.image == nil && merged.avatars["default"]?.hasProfileColor == false && merged.avatars["local"] == photoAvatar, "present source keys win even after their photo was deleted")
        check(merged.characters == local.characters, "nonempty source character list wins")
        var namesOnly = RelayFrame(op: "state"); namesOnly.characters = [RelayFrame.Character(id: "default", name: "새 이름")]
        portraits.receive(namesOnly, fromRelay: true)
        check(portraits.merging(empty).avatars["default"]?.image != nil && portraits.merging(empty).characters.first?.name == "새 이름", "omitted avatar field keeps the photo when names change")
        let corruptFile = home.appendingPathComponent("corrupt.json")
        try Data("broken".utf8).write(to: corruptFile)
        let corrupt = RelayPortraits(url: corruptFile)
        check(corrupt.merging(empty).avatars.isEmpty, "corrupt cache is ignored")
        corrupt.receive(portraitFrame, fromRelay: true)
        check(RelayPortraits(url: corruptFile).merging(empty).avatars["default"]?.image != nil, "new relay frame replaces corrupt cache")
        var unknown = keptJSON; unknown["version"] = 2
        try JSONSerialization.data(withJSONObject: unknown).write(to: corruptFile)
        check(RelayPortraits(url: corruptFile).merging(empty).characters.isEmpty, "unknown cache version is ignored")
        var excessive = portraitFrame
        excessive.avatars?["default"]?.png = Data(repeating: 0, count: 256 * 1024 + 1)
        let badFile = home.appendingPathComponent("oversized.json")
        RelayPortraits(url: badFile).receive(excessive, fromRelay: true)
        check(!FileManager.default.fileExists(atPath: badFile.path), "oversized relay image is rejected without writing")
        let wide = CGContext(data: nil, width: 513, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var wideAvatar = ProfileAvatar(); wideAvatar.thumbnail = wide.makeImage()
        excessive.avatars = ["wide": RelayFrame.Avatar(wideAvatar)]
        RelayPortraits(url: badFile).receive(excessive, fromRelay: true)
        check(!FileManager.default.fileExists(atPath: badFile.path), "image wider than 512 pixels is rejected")
        var many = portraitFrame
        many.avatars = Dictionary(uniqueKeysWithValues: (0..<600).map { ("profile-\($0)", RelayFrame.Avatar(photoAvatar)) })
        RelayPortraits(url: badFile).receive(many, fromRelay: true)
        check((try? Data(contentsOf: badFile).count) ?? 0 > 64 * 1024, "portrait storage is not limited to the small client request frame size")
        check(RelayPortraits(url: badFile).merging(empty).avatars.count == 600, "multiple valid thumbnails survive a larger cache round trip")
        try Data(repeating: 0, count: (16 << 20) + 1).write(to: badFile)
        check(RelayPortraits(url: badFile).merging(empty).avatars.isEmpty, "oversized cache file is ignored before decoding")
        var clear = RelayFrame(op: "state"); clear.avatars = [:]; clear.characters = []
        portraits.receive(clear, fromRelay: true)
        check(RelayPortraits(url: portraitFile).merging(empty).avatars.isEmpty, "explicit empty relay fields clear old portraits")

        var server = HermesRelayServer(home: home, token: token, interval: 0.1)
        let maintenanceLock = NSLock()
        var maintenance: [ThreeTapFailure] = []
        server.onTapFailure = { failure in maintenanceLock.lock(); maintenance.append(failure); maintenanceLock.unlock() }
        let port = try server.start(host: "127.0.0.1", port: 0)
        check(port > 0 && port != 47810, "listener uses a temporary port, never the installed relay port")
        Thread.sleep(forTimeInterval: 0.4)
        check(server.polls == 0, "nothing is read while no Mac is connected")

        // Wrong code
        let intruder = RemoteHermes(host: "127.0.0.1", port: port, token: String(repeating: "00", count: 32))
        intruder.start()
        check(wait(3) { intruder.poll(unreadSince: nil).status == .unavailable(RemoteHermes.denied) } != nil, "wrong code is told so")
        check(intruder.poll(unreadSince: nil).messages.isEmpty && intruder.search("합성").isEmpty, "wrong code receives no conversation")
        intruder.stop()
        check(server.polls == 0, "wrong code never triggers a read")

        // Oversized and malformed input
        for payload in [Data(repeating: 0x41, count: RelayFrame.maximumLine + 4096), Data("not json\n".utf8)] {
            let closed = DispatchSemaphore(value: 0)
            let raw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            raw.stateUpdateHandler = { state in
                if case .ready = state {
                    raw.send(content: payload, completion: .contentProcessed { _ in })
                    raw.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, finished, error in
                        if finished || error != nil || data == nil { closed.signal() }
                    }
                }
            }
            raw.start(queue: .global())
            check(closed.wait(timeout: .now() + 3) == .success, "garbage input closes the connection")
            raw.cancel()
        }

        // Right code
        var changes = 0; let changeLock = NSLock()
        let client = RemoteHermes(host: "127.0.0.1", port: port, token: token, portraits: portraits)
        client.onChange = { changeLock.lock(); changes += 1; changeLock.unlock() }
        let tapFailure = ThreeTapFailure(mac: "합성 Mac", os: "27.0.1", build: "TEST", app: "1", appBuild: "1", stage: "합성 고장")
        client.start(); client.start(); client.reportTapFailure(tapFailure)
        check(wait(3) { client.poll(unreadSince: nil).messages.count == 3 } != nil, "conversation arrives after connecting")
        check(wait(2) { maintenanceLock.lock(); defer { maintenanceLock.unlock() }; return maintenance == [tapFailure] } != nil, "authorized maintenance facts reach the server without sending a Slack message")
        let oldFrame = try JSONDecoder().decode(RelayFrame.self, from: Data("{\"op\":\"watch\"}".utf8))
        check(oldFrame.tapFailure == nil, "old relay frames still decode")
        var future = RelayFrame(op: "unknown-future-op"); future.tapFailure = tapFailure
        let futureFrame = try JSONDecoder().decode(RelayFrame.self, from: JSONEncoder().encode(future))
        check(futureFrame.op == "unknown-future-op", "unknown operations remain decodable")

        let first = client.poll(unreadSince: nil)
        check(first.status == .connected(stores: 2), "status names both records")
        check(client.lastReceivedAt != nil, "received state carries a time for offline presentation")
        check(first.messages.map(\.body) == ["합성 질문", "합성 답변", "정상."] && !first.messages.contains { $0.body == "SLACK ONLY" }, "only the iMessage thread is relayed, in time order")
        check(first.messages[1].speaker == "위키담당" && first.messages[2].speaker == "보관담당" && first.messages[2].profile == "archive-helper", "speaker names and profiles are kept")
        check(first.characters.map(\.name) == ["위키담당", "보관담당"], "characters are relayed in order")
        check(first.avatars["default"]?.hasProfileColor == true && first.avatars["archive-helper"]?.hasProfileColor == false, "profile colors are relayed")
        check(first.avatars["default"]?.image != nil && first.avatars["archive-helper"]?.image == nil, "profile photo is relayed as a thumbnail")
        check(first.typing.isEmpty && first.receipts.isEmpty, "old thread shows no typing and no unread mark was asked for")

        check(RelayPortraits(url: portraitFile).merging(empty).characters == first.characters, "(a/e) accepted client persists names after the wrong-code client was refused")
        check(RelayPortraits(url: portraitFile).merging(empty).avatars["default"]?.image != nil, "(a) received image is available after an offline restart")
        print("BENCH portrait cache bytes: \(try Data(contentsOf: portraitFile).count)")

        // A new answer shows up without waiting for a timer on the receiving side.
        changeLock.lock(); let seen = changes; changeLock.unlock()
        execute(home.appendingPathComponent("state.db"), ["INSERT INTO messages VALUES (10, 's1', 'user', '새 질문', NULL, \(Date().timeIntervalSince1970))"])
        let delay = wait(2) { client.poll(unreadSince: nil).messages.last?.body == "새 질문" }
        check(delay != nil && delay! < 1.0, "new message arrives within one second")
        print(String(format: "BENCH relay new message: %.0f ms", (delay ?? 0) * 1000))
        changeLock.lock(); let after = changes; changeLock.unlock()
        check(after > seen, "arrival notifies the app")
        check(wait(2) { client.poll(unreadSince: nil).typing.map(\.id) == ["fallback"] } != nil, "recent question shows the typing fallback")
        execute(home.appendingPathComponent("state.db"), ["INSERT INTO messages VALUES (11, 's1', 'assistant', '새 답변', NULL, \(Date().timeIntervalSince1970))"])
        check(wait(2) { let r = client.poll(unreadSince: nil); return r.messages.last?.body == "새 답변" && r.typing.isEmpty } != nil, "answer clears typing")

        // Unread marks follow the mark this Mac asks for.
        let mark = Date(timeIntervalSince1970: now - 595)
        check(wait(2) { client.poll(unreadSince: mark).receipts.count == 4 } != nil, "unread receipts are counted from this Mac's own mark")
        check(wait(2) { client.poll(unreadSince: Date()).receipts.isEmpty } != nil, "moving the mark clears them")

        // Requests
        check(client.search("답변").map(\.body) == ["새 답변", "합성 답변"], "search runs on the sharing Mac, newest first")
        check(client.search("SLACK").isEmpty, "search cannot reach other platforms")
        let latest = client.poll(unreadSince: nil).messages
        check(client.older(before: latest[2]).map(\.body) == ["합성 질문", "합성 답변"], "older page")
        check(client.around(profile: "default", messageID: 2).map(\.body) == ["합성 질문", "합성 답변", "정상.", "새 질문", "새 답변"], "context around a search hit")
        check(client.around(profile: "../../etc", messageID: 1).isEmpty, "unknown profile yields nothing")
        let requests = DispatchGroup(), resultsLock = NSLock()
        var correctResults = 0
        for index in 0..<12 {
            requests.enter()
            DispatchQueue.global().async {
                let expected = index % 2 == 0
                let result = client.search(expected ? "답변" : "SLACK")
                resultsLock.lock()
                if expected ? result.map(\.body) == ["새 답변", "합성 답변"] : result.isEmpty { correctResults += 1 }
                resultsLock.unlock(); requests.leave()
            }
        }
        check(requests.wait(timeout: .now() + 8) == .success && correctResults == 12, "concurrent searches retain their own results")

        // Link loss and recovery
        server.stop()
        check(wait(3) { client.poll(unreadSince: nil).status == .unavailable(RemoteHermes.lost) } != nil, "lost link is reported")
        check(client.poll(unreadSince: nil).messages.count == 5, "conversation stays on screen while reconnecting")
        check(client.lastReceivedAt != nil, "disconnect preserves the last received time")
        check(client.search("답변").isEmpty, "requests fail fast while disconnected")
        check(client.poll(unreadSince: nil).avatars["default"]?.image != nil && client.poll(unreadSince: nil).characters == first.characters, "(c) disconnection preserves received names and images")
        execute(home.appendingPathComponent("state.db"), ["INSERT INTO messages VALUES (12, 's1', 'assistant', '끊긴 동안', NULL, \(Date().timeIntervalSince1970))"])
        server = HermesRelayServer(home: home, token: token, interval: 0.1)
        check((try? server.start(host: "127.0.0.1", port: port)) == port, "relay comes back on the same port")
        check(wait(15) { let r = client.poll(unreadSince: nil); return r.status == .connected(stores: 2) && r.messages.last?.body == "끊긴 동안" } != nil, "client reconnects and catches up")

        let fresh = RemoteHermes(host: "127.0.0.1", port: port, token: token)
        fresh.start()
        check(wait(3) { fresh.poll(unreadSince: nil).avatars["default"]?.image != nil } != nil, "(f) restarted server sends unchanged avatars to a fresh connection")
        check(client.poll(unreadSince: nil).avatars["default"]?.image != nil, "(b) reconnecting client keeps its photo")
        fresh.stop()
        client.stop()
        Thread.sleep(forTimeInterval: 0.3)
        let idle = server.polls
        Thread.sleep(forTimeInterval: 0.5)
        check(server.polls == idle, "reading stops when the last Mac leaves")
        server.stop()
        Thread.sleep(forTimeInterval: 0.2)
        let late = RemoteHermes(host: "127.0.0.1", port: port, token: token)
        late.start()
        check(wait(3) { late.poll(unreadSince: nil).status == .unavailable(RemoteHermes.lost) } != nil, "(d) starting without a server reports retrying")
        server = HermesRelayServer(home: home, token: token, interval: 0.1)
        check((try? server.start(host: "127.0.0.1", port: port)) == port, "late server binds the temporary port")
        check(wait(15) { late.poll(unreadSince: nil).avatars["default"]?.image != nil && !late.poll(unreadSince: nil).characters.isEmpty } != nil, "(d) client automatically connects when server appears")
        late.stop(); server.stop()
        print("PASS: \(passed) relay wire, code, live delivery, request and reconnect checks")
    }
}
