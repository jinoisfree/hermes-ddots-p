import Foundation
import Darwin

/// Explicit acceptance run: real sockets, runner subprocesses, policy writer; synthetic home only.
@main struct FileDropModelRelayTests {
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FAIL \(name)\n", stderr); exit(1) }; print("PASS \(name)")
    }
    static func wait(_ condition: () -> Bool) {
        for _ in 0..<600 { if condition() { return }; Thread.sleep(forTimeInterval: 0.01) }
        check(false, "relay connected within six seconds")
    }
    static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func object(_ value: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: value) as! [String: Any] }
    static func unauthorized(port: UInt16, frame: RelayFrame) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        check(connected == 0, "raw authentication socket connected")
        let data = frame.line()
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &bytes, bytes.count)
        check(count > 0 && String(decoding: bytes.prefix(count), as: UTF8.self).contains("denied"), "T-05d server denies pre-authentication write or wrong token")
    }
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ddots-model-wire-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let operating = manager.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let privateLibrary = source.appendingPathComponent("hermes/plugin-store/team-kit/lib")
        let library = manager.fileExists(atPath: privateLibrary.path) ? privateLibrary : source.appendingPathComponent("plugins/team-kit/lib")
        func fixture(_ name: String) throws -> URL {
            let home = root.appendingPathComponent(name)
            for path in ["owner", "bin", "hermes-agent/venv/bin", "plugin-store/team-kit/lib/hermes_team_services"] {
                try manager.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            try manager.createSymbolicLink(at: home.appendingPathComponent("bin/hermes-run"), withDestinationURL: operating.appendingPathComponent("bin/hermes-run"))
            try manager.createSymbolicLink(at: home.appendingPathComponent("hermes-agent/venv/bin/python"), withDestinationURL: operating.appendingPathComponent("hermes-agent/venv/bin/python"))
            try manager.createSymbolicLink(at: FileDropRunner.engineScript(home), withDestinationURL: library.appendingPathComponent("hermes_team_services/file_drop_engine.py"))
            try Data("# synthetic policy\nother: {enabled: true}\n".utf8).write(to: home.appendingPathComponent("owner/policy.yaml"))
            let script = """
            import json,os,sys,time
            from pathlib import Path
            sys.path.insert(0,\(library.path.debugDescription))
            from hermes_team_services.file_drop_engine import describe
            home=Path(sys.argv[-1]); request=json.loads(input()); mode=request.get('mode','request')
            with (home/'calls.jsonl').open('a') as log: log.write(json.dumps({'mode':mode,'pid':os.getpid()})+'\\n')
            if mode=='context':
                if (home/'delay').exists(): time.sleep(8)
                print(json.dumps({'memories':[],'outcomes':{},'agentRoles':{'agent-a':['work']},'works':[],'engine':describe(home)}))
            else:
                current=describe(home)
                if request.get('engine_revision',current['revision'])!=current['revision']:
                    print(json.dumps({'error':'engine_changed'}))
                else: print(json.dumps({'suggestions':[{'id':'summarize','label':'합성 요약','profile':'agent-a','confidence':1}],'summary':'합성','confidence':1,'works':[]}))
            """
            try script.write(to: FileDropRunner.script(home), atomically: true, encoding: .utf8)
            return home
        }
        let home = try fixture("new")
        let token = String(repeating: "ab", count: 32)
        let server = HermesRelayServer(home: home, token: token, interval: 0.1, readUsage: { nil })
        let port = try server.start(host: "127.0.0.1", port: 0); defer { server.stop() }
        let policy = home.appendingPathComponent("owner/policy.yaml"), before = try Data(contentsOf: policy)
        var write = RelayFrame(op: "drop-engine"); write.id = 9
        write.drop = try json(["mode": "write", "model": "opus", "effort": "high"])
        try unauthorized(port: port, frame: write)
        var hello = RelayFrame(op: "hello"); hello.token = String(repeating: "cd", count: 32)
        try unauthorized(port: port, frame: hello)
        check(try! Data(contentsOf: policy) == before, "T-05d unauthenticated traffic preserves policy bytes")
        let badCode = RemoteHermes(host: "127.0.0.1", port: port, token: String(repeating: "cd", count: 32), includeMessages: false)
        badCode.start(); wait { badCode.dropFailure == "연결 코드를 다시 입력해 주세요" }; badCode.stop()
        print("PASS T-08c actual denied connection reason")
        let unsupportedServer = HermesRelayServer(home: root.appendingPathComponent("unsupported"), token: token, interval: 0.1, readUsage: { nil })
        let unsupportedPort = try unsupportedServer.start(host: "127.0.0.1", port: 0)
        let unsupported = RemoteHermes(host: "127.0.0.1", port: unsupportedPort, token: token, includeMessages: false)
        unsupported.start(); wait { unsupported.linked }
        check(unsupported.dropFailure == "맥미니 앱을 업데이트해 주세요", "T-08c dropVersion zero reason")
        unsupported.stop(); unsupportedServer.stop()
        let disconnected = RemoteHermes(host: "127.0.0.1", port: unsupportedPort, token: token, includeMessages: false)
        disconnected.start(); wait { disconnected.dropFailure.contains("연결 확인 · ") }; disconnected.stop()
        print("PASS T-08c actual disconnected reason includes last failure time")
        let client = RemoteHermes(host: "127.0.0.1", port: port, token: token, includeMessages: false)
        defer { client.stop() }
        for (chat, drop) in [(true, true), (true, false), (false, true), (false, false), (false, true), (false, false)] {
            client.setEnabled(chat: chat, fileDrop: drop)
            if chat || drop { wait { client.supportsDropEngine } }
            else { check(!client.linked, "T-08d both features disabled stop relay") }
        }
        print("PASS T-08d four feature combinations and live toggle transitions; chat flag remains false for drop-only")
        client.start(); wait { client.supportsDropEngine }
        let observer = RemoteHermes(host: "127.0.0.1", port: port, token: token, includeMessages: false)
        observer.start(); defer { observer.stop() }; wait { observer.supportsDropEngine }
        let saved = try object(client.engineDrop(write.drop!))
        check(saved["model"] as? String == "opus" && saved["effort"] as? String == "high", "T-08f real engine writer round trip")
        // T-08j: Python startup plus bounded owner-lock contention exceeds the old five-second cutoff.
        let slowHome = try fixture("slow-write")
        try manager.removeItem(at: FileDropRunner.engineScript(slowHome))
        let slowScript = "import time,runpy\ntime.sleep(2)\nrunpy.run_path(" + library.appendingPathComponent("hermes_team_services/file_drop_engine.py").path.debugDescription + ",run_name='__main__')\n"
        try slowScript.write(to: FileDropRunner.engineScript(slowHome), atomically: true, encoding: .utf8)
        let holder = Process(); holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import fcntl,time,pathlib; h=pathlib.Path(" + slowHome.path.debugDescription + "); f=(h/'owner/.app-connect.lock').open('w'); fcntl.flock(f,fcntl.LOCK_EX); (h/'locked').touch(); time.sleep(5.5)"]
        holder.standardOutput = FileHandle.nullDevice; holder.standardError = FileHandle.nullDevice
        try holder.run(); defer { if holder.isRunning { holder.terminate() } }
        wait { manager.fileExists(atPath: slowHome.appendingPathComponent("locked").path) }
        let slowServer = HermesRelayServer(home: slowHome, token: token, interval: 0.1, readUsage: { nil })
        let slowPort = try slowServer.start(host: "127.0.0.1", port: 0); defer { slowServer.stop() }
        let slowClient = RemoteHermes(host: "127.0.0.1", port: slowPort, token: token, includeMessages: false)
        slowClient.start(); defer { slowClient.stop() }; wait { slowClient.supportsDropEngine }
        let writeStarted = Date()
        let slowSaved = try object(slowClient.engineDrop(json(["mode": "write", "model": "opus", "effort": "high"])))
        let writeElapsed = Date().timeIntervalSince(writeStarted)
        check(slowSaved["model"] as? String == "opus" && writeElapsed > 5 && writeElapsed < 10, "T-08j real lock-contended engine write survives past five seconds within ten")
        holder.waitUntilExit()
        let input = try json(["mode": "context", "signals": [:]])
        let seen = try object(observer.contextDrop(input))
        check((seen["engine"] as? [String: Any])?["model"] as? String == "opus", "T-08f other client context reloads shared policy")
        let request = try json(["signals": [:], "deadline": Date().addingTimeInterval(15).timeIntervalSince1970])
        for _ in 0..<3 {
            _ = try client.contextDrop(input)
            _ = try client.suggestDrop(request, files: [])
        }
        print("PASS T-08g three serialized drops: drop_unavailable=0")
        try Data().write(to: home.appendingPathComponent("delay"))
        let started = Date()
        do { _ = try client.contextDrop(input); check(false, "delayed context must fail") } catch { }
        check(Date().timeIntervalSince(started) >= 4.8 && Date().timeIntervalSince(started) < 6, "T-08h new context cutoff at five seconds")
        _ = try client.suggestDrop(request, files: [])
        print("PASS T-08h context timeout leaves request slot available")
        Thread.sleep(forTimeInterval: 0.2)
        let calls = try String(contentsOf: home.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(separator: "\n").map { try object(Data($0.utf8)) }
        let pid = calls.last { $0["mode"] as? String == "context" }!["pid"] as! Int32
        check(kill(pid, 0) != 0 && errno == ESRCH, "T-08h delayed server context process was killed")
        Thread.sleep(forTimeInterval: 3.1)
        _ = try client.engineDrop(json(["mode": "read"]))
        print("PASS T-08h expired context response cannot satisfy a later engine query")
        let oldHome = try fixture("old")
        try manager.removeItem(at: FileDropRunner.engineScript(oldHome))
        let old = HermesRelayServer(home: oldHome, token: token, interval: 0.1, readUsage: { nil })
        let countLock = NSLock(); var requests = 0
        old.dropSuggest = { data in
            if try object(data)["mode"] as? String == "context" { Thread.sleep(forTimeInterval: 8) }
            else { countLock.withLock { requests += 1 } }
            return try json(["memories": [], "outcomes": [:]])
        }
        let oldPort = try old.start(host: "127.0.0.1", port: 0); defer { old.stop() }
        let legacy = RemoteHermes(host: "127.0.0.1", port: oldPort, token: token, includeMessages: false)
        legacy.start(); defer { legacy.stop() }; wait { legacy.supportsDrop }
        check(!legacy.supportsDropEngine, "T-08f old relay does not advertise engine settings")
        do { _ = try legacy.contextDrop(input); check(false, "old context must time out") }
        catch FileDropServiceError.legacyContextTimeout { print("PASS T-08h old relay context timeout explicitly forbids request") }
        check(countLock.withLock { requests == 0 }, "T-08h old relay request count zero")
    }
}
