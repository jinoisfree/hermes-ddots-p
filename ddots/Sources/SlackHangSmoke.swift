import AppKit

/// `--ui-smoke-slack-hang`: replays sending while switching between a thread with a "생각 중" reply and a long thread,
/// through a made-up workspace, and stops with code 3 if the main thread stalls. Only calls that existed before the
/// per-place drafts are used, so the same file runs on an older build for comparison. Nothing reaches Slack.
final class SlackHangScript {
    private let lock = NSLock()
    private var plan: [(ok: Bool, gate: DispatchSemaphore?)] = []
    private var answeredCount = 0
    static var current: SlackHangScript?
    @discardableResult func next(_ ok: Bool, held: Bool = false) -> DispatchSemaphore? {
        let gate = held ? DispatchSemaphore(value: 0) : nil
        lock.lock(); plan.append((ok, gate)); lock.unlock()
        return gate
    }
    var answered: Int { lock.lock(); defer { lock.unlock() }; return answeredCount }
    var api: SlackAPI {
        let base = SlackSmokeFixture.api()
        return SlackAPI(transport: { [self] method, parameters in
            guard method == "chat.postMessage" else { return base.transport(method, parameters) }
            lock.lock(); let step = plan.isEmpty ? (true, nil) : plan.removeFirst(); lock.unlock()
            step.1?.wait()
            defer { lock.lock(); answeredCount += 1; lock.unlock() }
            guard step.0 else { return .success(Data("{\"ok\":false,\"error\":\"smoke_refused\"}".utf8)) }
            var message: [String: Any] = ["ts": String(format: "%.6f", Date().timeIntervalSince1970), "user": "UME", "text": parameters["text"] ?? ""]
            if let thread = parameters["thread_ts"] { message["thread_ts"] = thread }
            return .success((try? JSONSerialization.data(withJSONObject: ["ok": true, "message": message])) ?? Data())
        }, raw: base.raw)
    }
}

extension AppDelegate {
    @MainActor func verifySlackHang(destination: URL, script: SlackHangScript) async {
        let log = destination.appendingPathComponent("slack-hang-steps.txt")
        let started = ProcessInfo.processInfo.systemUptime
        let state = NSLock()
        var beat = 0, current = "start"
        func step(_ name: String) {
            state.lock(); current = name; state.unlock()
            let line = String(format: "%7.2f %@\n", ProcessInfo.processInfo.systemUptime - started, name)
            if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile() } else { try? Data(line.utf8).write(to: log) }
        }
        step("start")
        // The main thread beats four times a second; a watcher on another thread ends the run if it stops for 15 seconds.
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in state.lock(); beat += 1; state.unlock() }
        RunLoop.main.add(timer, forMode: .common)
        Thread.detachNewThread {
            var last = -1, still = 0
            while true {
                Thread.sleep(forTimeInterval: 1)
                state.lock(); let now = beat, at = current; state.unlock()
                if now == last { still += 1 } else { still = 0; last = now }
                if still == 8 {
                    // A stack of the stalled run, taken while it is still stalled.
                    let sampler = Process()
                    sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    sampler.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", destination.appendingPathComponent("slack-hang-sample.txt").path]
                    try? sampler.run()
                }
                if still >= 15 {
                    let line = "HANG: main thread stopped for 15s during: \(at)\n"
                    if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile() }
                    FileHandle.standardError.write(Data(line.utf8))
                    exit(3)
                }
            }
        }
        func settle(_ seconds: Double = 0.5) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func answered(_ count: Int) async {
            for _ in 0..<100 where script.answered < count { await settle(0.1) }
            if script.answered < count { step("TIMEOUT waiting for answer \(count)"); smokeFailed("A send was not answered") }
            await settle()
        }
        let model = slack.model
        slack.smokeSends = true
        for _ in 0..<60 where !model.threads.contains(where: { $0.replyCount >= 5 }) { await settle(0.1) }
        var sends = 0
        func send(_ ok: Bool, held: Bool = false, _ text: String) -> DispatchSemaphore? {
            let gate = script.next(ok, held: held)
            model.draft = text; model.send(); sends += 1
            return gate
        }
        for round in 1...3 {
            step("round \(round): new post in A, failure while writing in B")
            model.select("CCOW"); model.writeNewPost()
            var gate = send(false, held: true, "A방 새 글")
            model.select("CTRUTH"); model.draft = "B방 초안"
            gate?.signal(); await answered(sends)
            model.select("CCOW"); model.writeNewPost(); model.draft = ""
            _ = send(true, "A방 새 글"); await answered(sends)
            model.select("CTRUTH"); model.draft = ""
            model.select("CCOW")
            for _ in 0..<40 where !model.threads.allSatisfy({ $0.room == "CCOW" }) { await settle(0.1) }
            guard let x = model.threads.first(where: { $0.replies.contains { SlackText.isThinking($0.body) } }),
                  let y = model.threads.first(where: { $0.replyCount >= 5 }) else { smokeFailed("The thinking thread and the long thread are there") }
            step("round \(round): reply to thinking thread \(x.ts), failure after picking long thread \(y.ts)")
            model.reply(x)
            gate = send(false, held: true, "X 답글")
            model.pick(y, foldable: false); model.draft = "Y 초안"
            gate?.signal(); await answered(sends)
            step("round \(round): reply to thinking thread again")
            model.reply(x); model.draft = ""
            _ = send(true, "X 답글"); await answered(sends)
            step("round \(round): pick long thread")
            model.pick(y, foldable: false); model.draft = ""; await settle()
            step("round \(round): failure in the same thread while writing again")
            model.reply(x)
            gate = send(false, held: true, "첫 답글")
            model.draft = "새로 쓰는 답글"
            gate?.signal(); await answered(sends)
            model.draft = ""; model.foldAll(); await settle()
        }
        step("done")
        timer.invalidate()
        try? "PASS: \(sends) sends while switching the thinking thread and the long thread, no stall over 15s\n"
            .write(to: destination.appendingPathComponent("slack-hang.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
