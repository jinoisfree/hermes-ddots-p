import AppKit

/// `--ui-smoke-slack-limit`: a made-up workspace that refuses the listing of rooms once for pace. Nothing reaches Slack.
final class SlackLimitScript {
    private let lock = NSLock()
    private var refuse = false
    private var counts: [String: Int] = [:]
    let wait: Double = 3
    static var current: SlackLimitScript?

    func refuseNextListing() { lock.lock(); refuse = true; lock.unlock() }
    func count(_ method: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[method] ?? 0 }

    var api: SlackAPI {
        let base = SlackSmokeFixture.api()
        return SlackAPI(transport: { [self] method, parameters in
            lock.lock()
            counts[method, default: 0] += 1
            let refused = method == "conversations.history" && refuse
            if refused { refuse = false }
            lock.unlock()
            return refused ? .failure(.rateLimited(wait)) : base.transport(method, parameters)
        }, raw: base.raw)
    }
}

extension AppDelegate {
    /// While the listing waits out its refusal the notice says so, threads go on being read and the draft stays;
    /// when the wait is over the room is listed again and the notice goes.
    @MainActor func verifySlackLimit(destination: URL, script: SlackLimitScript) async {
        func check(_ condition: Bool, _ message: String) { if !condition { smokeFailed(message) } }
        func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func until(_ what: String, _ condition: () -> Bool) async {
            for _ in 0..<60 where !condition() { slack.tick(); await settle(0.2) }
            check(condition(), "Timed out: " + what)
        }
        let model = slack.model, limited = SlackAPI.message(.rateLimited(0))
        await until("rooms are read") { model.threads.count >= 2 && model.notice == nil }
        model.select("CCOW")
        model.draft = "제한 중에도 남을 초안"
        script.refuseNextListing()
        await until("the listing is refused") { model.notice == limited }
        let listings = script.count("conversations.history"), readings = script.count("conversations.replies")
        let refusedAt = Date()
        while Date().timeIntervalSince(refusedAt) < script.wait - 0.6 { slack.tick(); await settle(0.25) }
        check(script.count("conversations.history") == listings, "No room is listed while the wait lasts: \(script.count("conversations.history") - listings)")
        check(script.count("conversations.replies") > readings, "Threads go on being read meanwhile")
        check(model.notice == limited && model.draft == "제한 중에도 남을 초안" && !model.threads.isEmpty, "The notice stays, and the draft and threads are kept: \(String(describing: model.notice))")
        capture(destination: destination.appendingPathComponent("slack-limit-waiting"))
        await until("the wait is over") { model.notice == nil && script.count("conversations.history") > listings }
        check(Date().timeIntervalSince(refusedAt) >= script.wait - 0.6, "Listing resumed only after the wait")
        check(model.draft == "제한 중에도 남을 초안" && !model.threads.isEmpty, "The draft and threads are still there after the wait")
        await settle(0.3)
        capture(destination: destination.appendingPathComponent("slack-limit-recovered"))
        try? "PASS: listing refused once; threads read during the wait; notice kept then cleared; draft kept\n"
            .write(to: destination.appendingPathComponent("slack-limit.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
