import AppKit

/// A made-up workspace that counts what is asked of it and can hold one call back until told. Nothing reaches Slack.
final class ClosingScript {
    private let lock = NSLock()
    private var calls = 0, posts = 0, raws = 0
    private var methods: [String: Int] = [:]
    private var gate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
    static var current: ClosingScript?
    var counts: (calls: Int, posts: Int, raws: Int) { lock.lock(); defer { lock.unlock() }; return (calls, posts, raws) }
    func count(_ method: String) -> Int { lock.lock(); defer { lock.unlock() }; return methods[method, default: 0] }
    /// The next call signals `entered` and waits for `release`.
    func holdNext() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let next = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        lock.lock(); gate = next; lock.unlock()
        return next
    }
    var api: SlackAPI {
        let base = SlackSmokeFixture.api()
        return SlackAPI(transport: { [self] method, parameters in
            lock.lock(); calls += 1; if method == "chat.postMessage" { posts += 1 }
            methods[method, default: 0] += 1
            let held = gate; gate = nil; lock.unlock()
            if let held { held.entered.signal(); held.release.wait() }
            if method == "search.messages", parameters["query"] == "closing-late" { return .failure(.network("closing search answer")) }
            if method == "chat.postMessage" {
                let ts = String(format: "%.6f", Date().timeIntervalSince1970)
                let message = ["ts": ts, "user": "UME", "text": parameters["text"] ?? "", "thread_ts": parameters["thread_ts"] ?? ""]
                return .success(try! JSONSerialization.data(withJSONObject: ["ok": true, "ts": ts, "message": message]))
            }
            return base.transport(method, parameters)
        }, raw: { [self] url, body in
            lock.lock(); raws += 1; lock.unlock()
            return base.raw(url, body)
        })
    }
}

/// `--ui-smoke-closing <kind>` with `--ui-smoke-chat --ui-smoke-slack`: slows one part of closing past its limit, closes,
/// and writes what closing did for the runner outside, which also times the process's end. The disk is slowed by
/// stand-ins; nothing reaches Slack, and the Slack cache and files go to scratch folders.
/// - save, remove, flush: a slow private save, private-copy removal or cache flush has begun before closing.
/// - paste: removing the pasted pictures is slow; the run ends at the limit and leaves them for the next start.
/// - late: a reading is held on the Slack queue and the file queue is held; closing begins from a run-loop timer,
///   as a menu or key event would, so the main queue keeps running and the reading's late answer does arrive.
/// - paste-recover: a later run with the same `--ui-smoke-paste-area`, whose start removes what was left.
extension AppDelegate {
    static var closingKind: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-closing"), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    /// Longer than the closing limit, so a step that is waited on would show.
    static let closingHold: TimeInterval = 4
    /// The recovery check holds the start's removal until it has pasted a picture of its own.
    static let recoveryGate = DispatchSemaphore(value: 0)

    @MainActor func verifyClosing(destination: URL, kind: String) async {
        func check(_ condition: Bool, _ message: String) { if !condition { smokeFailed(message) } }
        func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func write(_ name: String, _ values: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            try? data.write(to: destination.appendingPathComponent(name))
        }
        func waited(_ signal: DispatchSemaphore) async -> Bool {
            for _ in 0..<80 { if signal.wait(timeout: .now()) == .success { return true }; await settle(0.05) }
            return false
        }
        let model = slack.model
        for _ in 0..<100 where model.threads.isEmpty { await settle(0.1) }
        check(!model.threads.isEmpty && slack.bridge != nil, "The made-up workspace is read before closing")
        if kind == "paste-recover" { await verifyPasteRecovery(destination: destination); return }
        if kind == "late" { await verifyDeferredClosing(destination: destination) }
        guard let bridge = slack.bridge, let cache = slack.scratchCache, let script = ClosingScript.current else { smokeFailed("The closing check has its scratch cache and workspace") }

        // The flush that closing waits on writes to the scratch cache, not the real one.
        let flushed = DispatchSemaphore(value: 0)
        slack.queue.async { bridge.flush(); flushed.signal() }
        _ = await waited(flushed)
        check(FileManager.default.fileExists(atPath: cache.path), "A flush writes the scratch cache")

        // A file the user picked stays where it is; a pasted picture is ddots's own and goes.
        let original = destination.appendingPathComponent("사용자 원본.txt")
        try? Data("ORIGINAL".utf8).write(to: original)
        let board = model.clipboard
        let picture = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.systemRed.setFill(); rect.fill(); return true }
        board.clearContents(); board.writeObjects([picture])
        model.pasteAttachments(from: board)
        board.clearContents(); board.writeObjects([original as NSURL])
        model.pasteAttachments(from: board)
        let pasted = model.attachments.first { $0.path.hasPrefix(SlackModel.pasteArea.path + "/run-") }
        check(pasted != nil && model.attachments.contains(original), "A pasted picture and a picked file are attached: \(model.attachments)")

        let files = slack.temporaryFiles
        let opened = try? files.save(Data("OPENED".utf8), name: "열어 본 파일.txt")
        check(opened != nil, "A private copy is there before closing")
        let entered = DispatchSemaphore(value: 0)
        let hold: (String) -> (String) -> Void = { wanted in { step in
            guard step == wanted else { return }
            entered.signal(); Thread.sleep(forTimeInterval: Self.closingHold)
        } }
        final class Record {
            var count = 0, answers = 0; var midSaveRefused: Bool?; var late: [String: Any] = [:]
            var atClose = (calls: 0, posts: 0, raws: 0), settled = (calls: 0, posts: 0, raws: 0)
        }
        let record = Record()
        var startedBefore = true
        switch kind {
        case "save":
            // A download landing: the write is under way when closing begins, and closing does not wait for it.
            files.stall = hold("write")
            slack.fileQueue.async { _ = try? files.save(Data("LATE".utf8), name: "늦은.txt") }
        case "remove":
            // Every removal is slow, the one closing starts as well.
            files.stall = hold("remove")
            DispatchQueue.global().async { try? files.clear() }
        case "flush":
            // A flush is under way; the one closing adds waits behind it on the Slack queue.
            slack.queue.async { hold("flush")("flush"); bridge.flush() }
        case "paste":
            // Removing the pasted pictures is what closing does slowly; it begins only once closing has.
            ClipboardAttachments.stall = hold("remove")
            startedBefore = false
        case "late":
            // The file queue is held, as by a slow download: anything that waited on it from the main thread would stop the beat.
            let fileHeld = DispatchSemaphore(value: 0)
            slack.fileQueue.async { fileHeld.signal(); Thread.sleep(forTimeInterval: Self.closingHold) }
            check(await waited(fileHeld), "The file queue is held before closing")
            // Closing itself waits to its limit on a slow private-copy removal, so the late answer lands while it waits.
            files.stall = { step in if step == "remove" { Thread.sleep(forTimeInterval: Self.closingHold) } }
            // A reading is held on the Slack queue; its answer carries a room mapping other than the one last applied.
            slack.retentionMapping = "closing-check-stale"
            slack.smokeSends = true
            let gate = script.holdNext()
            slack.tick()
            check(await waited(gate.entered) && slack.syncing, "A reading is under way when closing begins")
            entered.signal()
            let publishes = slack.publishCount, threads = model.threads.map(\.id), thumbs = model.thumbs.count
            let fileMessage = model.threads.flatMap(\.messages).first { !$0.files.isEmpty }
            check(fileMessage != nil, "A message with files is there to try")
            /// Everything the controller can be asked to start: a reading, a send, a file, a picture.
            @MainActor func ask(_ text: String) {
                slack.tick()
                model.draft = text; model.send()
                if let message = fileMessage { for file in message.files { slack.open(file, in: message); slack.loadThumb(file) } }
            }
            func later(_ delay: TimeInterval, _ work: @escaping () -> Void) { RunLoop.main.add(Timer(timeInterval: delay, repeats: false) { _ in work() }, forMode: .common) }
            later(0.05) { [self] in NSApp.terminate(nil) }
            later(0.25) { record.atClose = script.counts; ask("종료 중 보낸 글") }
            // The held reading goes on; its answer reaches the main thread while closing waits.
            later(0.45) { gate.release.signal() }
            later(1.2) { [self] in record.settled = script.counts; ask("종료 중 다시 보낸 글"); record.late["synced_done"] = !slack.syncing }
            later(1.7) { [self] in
                let now = script.counts
                record.late = record.late.merging([
                    "calls_after_settled": now.calls - record.settled.calls, "posts_after_close": now.posts - record.atClose.posts, "raws_after_close": now.raws - record.atClose.raws,
                    "publishes_after_close": slack.publishCount - publishes, "retention_mapping_untouched": slack.retentionMapping == "closing-check-stale",
                    "threads_unchanged": model.threads.map(\.id) == threads, "thumbs_unchanged": model.thumbs.count == thumbs,
                    "nothing_opened": slack.lastSaved == nil && model.busyFiles.isEmpty], uniquingKeysWith: { $1 })
            }
        default: smokeFailed("Unknown closing kind \(kind)")
        }
        if startedBefore { check(await waited(entered), "The slow \(kind) has begun before closing is asked for") }

        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in record.count += 1 }
        RunLoop.main.add(timer, forMode: .common)
        let requested = ProcessInfo.processInfo.systemUptime
        // Run-loop timers keep firing while AppKit waits for closing; the main queue need not (see `ClosingRun`).
        RunLoop.main.add(Timer(timeInterval: 0.5, repeats: false) { _ in record.midSaveRefused = (try? files.save(Data("NEW".utf8), name: "새.txt")) == nil }, forMode: .common)
        onClosingAnswered = { [weak self] late in
            record.answers += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - requested
            write("closing-answer.json", ["kind": kind, "answers": record.answers, "late": late, "elapsed_ms": Int(elapsed * 1000),
                                          "beats": record.count, "save_refused_while_closing": record.midSaveRefused as Any,
                                          "save_refused_at_answer": (try? files.save(Data("NEW".utf8), name: "새.txt")) == nil,
                                          "closing_state": self?.slack.closing ?? false, "late_answer": record.late,
                                          "answered_epoch": Date().timeIntervalSince1970])
        }
        write("closing-request.json", ["kind": kind, "requested_epoch": Date().timeIntervalSince1970, "limit_s": Self.closingLimit,
                                       "hold_s": Self.closingHold, "temporary_root": files.root.path, "opened": opened?.path ?? "",
                                       "pasted": pasted?.path ?? "", "paste_area": SlackModel.pasteArea.path, "original": original.path, "cache": cache.path])
        // `late` asks from a run-loop timer above; the others from this block on the main queue, as most checks end.
        if kind != "late" { NSApp.terminate(nil) }
    }

    /// Work already scheduled or in flight must not restart search, page reads or archive publication after closing.
    @MainActor private func verifyDeferredClosing(destination: URL) async {
        func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func signaled(_ signal: DispatchSemaphore) -> Bool { signal.wait(timeout: .now()) == .success }
        var results: [String: Bool] = [:]
        func check(_ name: String, _ passed: Bool) {
            results[name] = passed
            try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("closing-deferred.json"))
            if !passed { smokeFailed("Closing deferred work: " + name) }
        }
        func controller(_ script: ClosingScript) async -> SlackController {
            let controller = SlackController()
            controller.persists = false; controller.smokeSends = true
            controller.chatOpen = true; controller.characters = chat.characters
            controller.model.source = .slack; controller.model.selected = "CCOW"
            controller.start(script.api)
            for _ in 0..<100 where controller.syncing || controller.model.threads.isEmpty { controller.tick(); await settle(0.05) }
            check("fixture_ready", !controller.syncing && !controller.model.threads.isEmpty)
            return controller
        }
        func close(_ controller: SlackController) {
            let run = ClosingRun(limit: 0.5) { _ in }
            controller.prepareClose(run); run.start()
        }

        let delayedScript = ClosingScript(), lateScript = ClosingScript(), pageScript = ClosingScript()
        let delayed = await controller(delayedScript)
        delayed.model.findOpen = true; delayed.model.findQuery = "closing-delayed"
        close(delayed)
        await settle(0.8)
        check("scheduled_search_cancelled", delayedScript.count("search.messages") == 0)
        delayed.submitFind(); delayed.openFind(); delayed.refreshFind()
        await settle(0.1)
        check("new_search_refused", delayedScript.count("search.messages") == 0)

        let late = await controller(lateScript)
        let held = lateScript.holdNext()
        late.model.findOpen = true; late.model.findQuery = "closing-late"; late.submitFind()
        var entered = false
        for _ in 0..<100 { if signaled(held.entered) { entered = true; break }; await settle(0.02) }
        check("search_started_before_close", entered)
        late.model.findNotice = "종료 전 검색 상태"
        close(late); held.release.signal()
        // A main-queue marker behind the search response proves its callback had a chance to run.
        let drained = DispatchSemaphore(value: 0)
        late.find.queue.async(flags: .barrier) { DispatchQueue.main.async { drained.signal() } }
        var answered = false
        for _ in 0..<100 { if signaled(drained) { answered = true; break }; await settle(0.02) }
        check("late_search_callback_drained", answered)
        check("late_search_not_shown", late.model.findNotice == "종료 전 검색 상태")

        let page = await controller(pageScript)
        var completions = 0
        let initialReads = pageScript.count("conversations.replies")
        page.model.onPageSend?("쪽: 2", page.model.threads[0]) { completions += 1 }
        for _ in 0..<100 where pageScript.count("conversations.replies") == initialReads && completions == 0 { await settle(0.02) }
        check("page_started_before_close", pageScript.count("chat.postMessage") == 1 && completions == 0)
        check("page_read_before_close", pageScript.count("conversations.replies") > initialReads)
        let pageDrained = DispatchSemaphore(value: 0)
        page.queue.async { DispatchQueue.main.async { pageDrained.signal() } }
        var pageAnswered = false
        for _ in 0..<100 { if signaled(pageDrained) { pageAnswered = true; break }; await settle(0.02) }
        check("page_next_read_scheduled", pageAnswered && completions == 0)
        let reads = pageScript.count("conversations.replies")
        close(page)
        await settle(0.8)
        check("scheduled_page_read_cancelled", pageScript.count("conversations.replies") == reads && completions == 1)

        let archive = await controller(ClosingScript())
        archive.archive = DdotsArchive(root: destination.appendingPathComponent("record"), retention: archive.retention)
        let release = DispatchSemaphore(value: 0), drainedArchive = DispatchSemaphore(value: 0)
        archive.fileQueue.async { release.wait() }
        let revision = archive.keptRevision
        archive.loadKept(initial: true)
        close(archive); release.signal()
        archive.fileQueue.async { DispatchQueue.main.async { drainedArchive.signal() } }
        var archiveAnswered = false
        for _ in 0..<100 { if signaled(drainedArchive) { archiveAnswered = true; break }; await settle(0.02) }
        check("late_archive_callback_drained", archiveAnswered)
        check("late_archive_not_applied", archive.keptRevision == revision)
    }

    /// The start removes the folders an earlier run left, while a picture pasted now gets a folder of its own that stays.
    @MainActor private func verifyPasteRecovery(destination: URL) async {
        let model = slack.model, area = SlackModel.pasteArea
        let before = ClipboardAttachments.runFolders(in: area).map(\.lastPathComponent)
        let board = model.clipboard
        let picture = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        board.clearContents(); board.writeObjects([picture])
        model.pasteAttachments(from: board)
        let fresh = model.attachments.first { $0.path.hasPrefix(area.path + "/run-") }
        // The start's removal is held until here, so the new picture is made while it is still under way.
        let pastedDuringRecovery = pasteRecovered == nil
        Self.recoveryGate.signal()
        for _ in 0..<200 where pasteRecovered == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        let values: [String: Any] = ["recovered": pasteRecovered as Any, "cache": slack.scratchCache?.path ?? "", "run_folders_seen_at_start": before, "pasted_during_recovery": pastedDuringRecovery,
               "fresh": fresh?.path ?? "", "fresh_kept": fresh.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
               "run_folders_after": ClipboardAttachments.runFolders(in: area).map(\.lastPathComponent)]
        try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("paste-recover.json"))
        NSApp.terminate(nil)
    }
}
