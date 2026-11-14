import AppKit

extension AppDelegate {
    @MainActor func verifyFileDropSequence(destination: URL, engine: @escaping FileDropCard.Engine) async {
        let previous = remoteHermes
        defer { remoteHermes = previous; fileDrop.close() }
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) {
            checks.append((value ? "PASS " : "FAIL ") + name)
            try? checks.joined(separator: "\n").write(to: destination.appendingPathComponent("drop-model-sequence.txt"), atomically: true, encoding: .utf8)
            if !value { smokeFailed(name) }
        }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        for (delay, changes, requestDelay) in [(0.0, 0, 16.0), (4.0, 0, 0.0), (0.0, 1, 0.0), (0.0, 2, 0.0)] {
            let lock = NSLock(); var revision = "a", contexts = 0, requests = 0, active = false, overlap = false, correctDeadline = true
            let server = HermesRelayServer(home: destination, token: String(repeating: "ab", count: 32), interval: 0.1, readUsage: { nil })
            func snapshot() -> [String: Any] {
                ["model": "opus", "effort": "high", "seconds": revision == "a" && delay == 0 ? 30 : 15, "revision": revision]
            }
            server.dropEngine = { _ in try JSONSerialization.data(withJSONObject: lock.withLock { snapshot() }) }
            server.dropContext = { _ in
                lock.withLock { active = true; contexts += 1 }
                Thread.sleep(forTimeInterval: delay)
                return try lock.withLock {
                    active = false
                    return try JSONSerialization.data(withJSONObject: ["memories": [], "outcomes": [:], "agentRoles": ["work-x": ["work"]], "works": [], "engine": snapshot()])
                }
            }
            server.dropSuggest = { data in
                let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let changing = lock.withLock { () -> Bool in
                    requests += 1; overlap = overlap || active
                    let remaining = (request["deadline"] as? Double ?? 0) - Date().timeIntervalSince1970
                    let expected = snapshot()["seconds"] as! Int
                    correctDeadline = correctDeadline && remaining > Double(expected) - 1 && remaining <= Double(expected) && request["engine_revision"] as? String == revision
                    if requests <= changes { revision = requests == 1 ? "b" : "c"; return true }
                    return false
                }
                if changing { return Data("{\"error\":\"engine_changed\"}".utf8) }
                Thread.sleep(forTimeInterval: requestDelay)
                return Data("{\"suggestions\":[{\"id\":\"summarize\",\"label\":\"합성 요약\",\"profile\":\"work-x\",\"confidence\":1}],\"summary\":\"합성\",\"confidence\":1,\"works\":[]}".utf8)
            }
            guard let port = try? server.start(host: "127.0.0.1", port: 0) else { smokeFailed("sequence relay start") }
            let client = RemoteHermes(host: "127.0.0.1", port: port, token: String(repeating: "ab", count: 32), includeMessages: false)
            client.start(); remoteHermes = client
            for _ in 0..<200 { if client.supportsDropEngine { break }; try? await Task.sleep(nanoseconds: 20_000_000) }
            check(client.supportsDropEngine, "T-08e synthetic relay connected")
            fileDrop.engine = engine
            fileDrop.cast = { FileDropCast(members: ["work-x"], roles: ["work-x": ["work"]], fallback: "work-x") }
            board.clearContents(); board.setString("합성 납품 안내", forType: .string); fileDrop.receive(board)
            if requestDelay > FileDropTiming.legacySeconds {
                try? await Task.sleep(nanoseconds: 15_300_000_000)
                check(fileDrop.origin.isEmpty && !fileDrop.status.isEmpty, "T-08e reading continues beyond old 15 seconds within engine budget")
            }
            for _ in 0..<400 { if !fileDrop.origin.isEmpty { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
            check(lock.withLock { !overlap && correctDeadline }, "T-08e context finishes before request; deadline derives from engine seconds")
            check(lock.withLock { contexts == (changes > 0 ? 2 : 1) && requests == (changes > 0 ? 2 : 1) }, "T-08e retries context/request at most once")
            check(fileDrop.origin == (changes == 2 ? "기본 제안이에요 · 설정이 바뀌는 중이었어요" : "Claude가 읽고 골랐어요"), "T-08e revision race result matches retry contract: " + fileDrop.origin)
            fileDrop.close(); client.stop(); server.stop()
        }
    }

    /// T-08i: real card and production engine, only local IO and remote service are delayed.
    @MainActor func verifyFileDropClock(destination: URL) async {
        let engine = fileDrop.engine, reader = fileDrop.readSignals, previous = remoteHermes
        let onAnswer = fileDrop.onAnswer
        defer { remoteHermes = previous; fileDrop.readSignals = reader; fileDrop.onAnswer = onAnswer; fileDrop.close() }
        var results: [String] = []
        func check(_ ok: Bool, _ label: String) {
            results.append((ok ? "PASS " : "FAIL ") + label)
            try? results.joined(separator: "\n").write(to: destination.appendingPathComponent("drop-clock.txt"), atomically: true, encoding: .utf8)
            if !ok { smokeFailed(label) }
        }
        for (localDelay, responseDelay) in [(10.0, 14.0), (10.0, 17.0), (16.0, 0.0)] {
            let lock = NSLock(); var requestAt: Double?, elapsed: Double?, requests = 0
            let server = HermesRelayServer(home: destination, token: String(repeating: "ab", count: 32), interval: 0.1, readUsage: { nil })
            server.dropEngine = { _ in Data("{}".utf8) }
            server.dropContext = { _ in
                Thread.sleep(forTimeInterval: 1)
                return Data("{\"engine\":{\"model\":\"sonnet\",\"seconds\":15,\"revision\":\"clock\"},\"agentRoles\":{\"work-x\":[\"work\"]},\"works\":[],\"memories\":[],\"outcomes\":{}}".utf8)
            }
            server.dropSuggest = { _ in
                lock.withLock { requestAt = ProcessInfo.processInfo.systemUptime; requests += 1 }
                Thread.sleep(forTimeInterval: responseDelay)
                return Data("{\"suggestions\":[{\"id\":\"summarize\",\"label\":\"합성 요약\",\"profile\":\"work-x\",\"confidence\":1}],\"summary\":\"합성\",\"confidence\":1,\"works\":[]}".utf8)
            }
            let port = try! server.start(host: "127.0.0.1", port: 0)
            let client = RemoteHermes(host: "127.0.0.1", port: port, token: String(repeating: "ab", count: 32), includeMessages: false)
            client.start(); remoteHermes = client
            for _ in 0..<200 { if client.supportsDropEngine { break }; try? await Task.sleep(nanoseconds: 20_000_000) }
            check(client.supportsDropEngine, "clock relay connected")
            fileDrop.readSignals = { payload, initial in Thread.sleep(forTimeInterval: localDelay); return reader(payload, initial) }
            fileDrop.engine = engine
            fileDrop.onAnswer = { value, _ in elapsed = value }
            fileDrop.cast = { FileDropCast(members: ["work-x"], roles: ["work-x": ["work"]], fallback: "work-x") }
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString("합성 납품 안내", forType: .string)
            let dropped = ProcessInfo.processInfo.systemUptime
            fileDrop.receive(board)
            for _ in 0..<650 { if !fileDrop.origin.isEmpty { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
            let ended = ProcessInfo.processInfo.systemUptime
            if localDelay == 16 {
                check(fileDrop.origin == "기본 제안이에요 · 시간 초과" && lock.withLock { requests == 0 }, "T-08i local read16 expires without engine request")
                check(abs(ended - dropped - 15) < 0.5, "T-08i phase1 cutoff=t15; observed=\(ended-dropped)")
            } else if responseDelay == 14 {
                check(fileDrop.origin == "Claude가 읽고 골랐어요", "T-08i local10/context1/request14 succeeds past old card cutoff")
            } else {
                check(fileDrop.origin == "기본 제안이에요 · 시간 초과", "T-08i response17 expires")
                let requestStarted = lock.withLock { requestAt } ?? 0
                check(abs(ended - requestStarted - 16) < 0.5 && (elapsed ?? 0) > 26, "T-08i phase3 replaces t30 by deadline+1=t27; observed=\(ended-dropped)")
            }
            fileDrop.close(); client.stop(); server.stop()
        }
        // T-08j: a lost response may follow a committed write. Reload the authoritative value.
        let settings = FileDropSettings(defaults: nil)
        let choices: [FileDropEnginePolicy.Choice] = [.init(model: "sonnet", efforts: [nil]), .init(model: "opus", efforts: [nil, "high"])]
        var actual = FileDropEnginePolicy(model: "sonnet", effort: nil, seconds: 15, revision: "a", choices: choices), reads = 0
        settings.engine = actual; settings.model = "opus"; settings.effort = "high"
        settings.loadEngine = { reads += 1; return actual }
        settings.saveEngine = { _, _ in actual = .init(model: "opus", effort: "high", seconds: 15, revision: "b", choices: choices); throw FileDropServiceError.timeout }
        settings.save()
        for _ in 0..<100 { if reads > 0 && !settings.engineBusy { break }; try? await Task.sleep(nanoseconds: 20_000_000) }
        check(reads == 1 && settings.engine == actual && settings.model == "opus" && settings.effort == "high", "T-08j save failure reloads actual committed value")
        check(settings.engineMessage.contains("현재값을 다시 읽었어요"), "T-08j failure reports reloaded current value")
    }

    /// Installed-binary acceptance run. A write is possible only in an explicitly supplied synthetic home.
    @MainActor func verifyFileDropModel(destination: URL) async {
        let home = DdotsConfig.shared.hermes
        let writing = CommandLine.arguments.contains("--ui-smoke-engine-write")
        let operating = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").resolvingSymlinksInPath()
        if writing && (ProcessInfo.processInfo.environment["HERMES_HOME"] == nil || home.resolvingSymlinksInPath() == operating) {
            smokeFailed("model write smoke requires an explicit synthetic HERMES_HOME")
        }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        func check(_ value: Bool, _ name: String) {
            print((value ? "PASS " : "FAIL ") + name); fflush(stdout)
            if !value { smokeFailed(name) }
        }
        func pause() async { try? await Task.sleep(nanoseconds: 100_000_000) }
        func until(_ name: String, _ condition: () -> Bool) async {
            for _ in 0..<1400 { if condition() { return }; await pause() }
            check(false, name)
        }
        remoteHermes = nil
        showOptions()
        func tabs(_ view: NSView) -> NSTabView? {
            if let tabs = view as? NSTabView { return tabs }
            return view.subviews.compactMap(tabs).first
        }
        if let view = optionsWindow?.contentView { tabs(view)?.selectTabViewItem(withIdentifier: "끌어놓기") }
        await until("engine settings loaded") { fileDropSettings.engine != nil && !fileDropSettings.engineBusy }
        check(!fileDropSettings.model.isEmpty, "settings read mini policy")
        if writing {
            fileDropSettings.model = "opus"; fileDropSettings.effort = "high"; fileDropSettings.save()
            await until("synthetic engine saved") { fileDropSettings.engineMessage == "저장했어요" && !fileDropSettings.engineBusy }
            check(fileDropSettings.engine?.model == "opus" && fileDropSettings.engine?.effort == "high", "synthetic settings handler saved Opus/high")
        }
        capture(destination: destination.appendingPathComponent("settings"))
        let image = NSImage(size: NSSize(width: 800, height: 220), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("SYNTHETIC delivery: Nov 20" as NSString).draw(at: NSPoint(x: 30, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
            return true
        }
        let inputs = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-engine-input-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        SmokeLeftovers.note(inputs)
        let png = inputs.appendingPathComponent("synthetic.png")
        let bytes = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try! bytes.write(to: png)
        try! bytes.write(to: destination.appendingPathComponent("synthetic.png"))
        let payload = FileDropIntake.Payload(files: [png])
        let signals = await Task.detached { FileDropSignals.read(payload, initial: .initial(payload)) }.value
        let context: FileDropContext
        do { context = try await FileDropClaude.context(signals, home: home, remote: nil) }
        catch { check(false, "PNG context failed: " + String(describing: error)); return }
        guard let roles = context.agentRoles, !roles.isEmpty else {
            check(false, "PNG context must return agent roles"); return
        }
        let members = roles.keys.sorted()
        fileDropSettings.learn(roles: roles)
        fileDrop.cast = { FileDropCast(members: members, roles: roles, fallback: members.first ?? "") }
        fileDrop.profileName = { roles[$0]?.contains("work") == true ? "업무 비서" : "개인 비서" }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([png as NSURL]); fileDrop.receive(board)
        optionsWindow?.orderOut(nil)
        await until("real engine answered") { !fileDrop.origin.isEmpty }
        capture(destination: destination.appendingPathComponent("drop"))
        let result: [String: Any] = ["model": fileDropSettings.engine?.model ?? "", "effort": fileDropSettings.engine.flatMap(\.effort).map { $0 as Any } ?? NSNull(), "origin": fileDrop.origin, "summary": fileDrop.summary, "writing": writing]
        try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: destination.appendingPathComponent("model-result.json"))
        try? JSONEncoder().encode(fileDrop.signals).write(to: destination.appendingPathComponent("signals.json"))
        check(fileDrop.origin == "Claude가 읽고 골랐어요", "binary real CLI suggestion: " + fileDrop.origin)
        fileDrop.close(); NSApp.terminate(nil)
    }
}
