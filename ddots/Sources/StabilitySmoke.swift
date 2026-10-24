import AppKit
import Darwin

/// A source whose response can be held until after the user switches connections. No files or network.
private final class DelayedHermesSmoke: HermesSource {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let message = ChatMessage(id: "default:900001", fromUser: false, speaker: "위키담당", body: "이전 연결의 늦은 결과", date: Date())
    func result() -> [ChatMessage] {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        return [message]
    }
    func poll(unreadSince: Date?) -> HermesBridge.PollResult { .init(status: .connected(stores: 1), messages: result()) }
    func search(_ text: String) -> [ChatMessage] { result() }
    func older(before message: ChatMessage?) -> [ChatMessage] { result() }
    func around(profile: String, messageID: Int64) -> [ChatMessage] { result() }
}

extension AppDelegate {
    func verifyStability(destination: URL) {
        Task { @MainActor [self] in
            func settle(_ milliseconds: UInt64 = 350) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
            var measurements: [String: Any] = [:]
            func resources() -> (cpu: Double, peak: Int) {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
                return (cpu, usage.ru_maxrss)
            }
            var ticks = 0
            let previous = pet.onAnimationWork
            pet.onAnimationWork = { start, elapsed in ticks += 1; previous?(start, elapsed) }
            defer { pet.onAnimationWork = previous }
            func sample(_ name: String) async -> Int {
                ticks = 0
                let before = resources(), began = ProcessInfo.processInfo.systemUptime
                await settle(1000)
                let after = resources()
                measurements[name] = ["callbacks": ticks, "seconds": ProcessInfo.processInfo.systemUptime - began,
                                      "cpu_ms": (after.cpu - before.cpu) * 1000, "peak_resident_bytes": after.peak]
                return ticks
            }
            smokeCheck(isSmoke && chatExpanded, "Stability checks use the synthetic chat")
            let draft = chat.draft
            let messages = chat.messages
            let expandedTicks = await sample("expanded")
            smokeCheck(expandedTicks > 0, "Visible conversation animates")
            panel.orderOut(nil); await settle()
            let hiddenTicks = await sample("hidden")
            smokeCheck(hiddenTicks == 0 && !pet.animationTimerActive, "Hidden pet has no animation timer callbacks")
            smokeCheck(chat.draft == draft && chat.messages == messages, "Hiding preserves the draft and conversation")
            panel.makeKeyAndOrderFront(nil); await settle()
            let shownTicks = await sample("shown")
            smokeCheck(shownTicks > 0 && pet.animationTimerActive, "Opening a hidden chat restarts animation")
            collapseChat(); await settle(700)
            let foldedTicks = await sample("folded")
            smokeCheck(foldedTicks > 0, "Folded visible pet still animates")
            pet.resting = true; await settle()
            let screenRestTicks = await sample("screenRest")
            smokeCheck(screenRestTicks == 0, "Screen rest stops animation")
            panel.orderOut(nil); panel.orderFrontRegardless()
            smokeCheck(!pet.animationTimerActive, "Showing cannot override screen rest")
            pet.resting = false; await settle()
            let awakeTicks = await sample("awake")
            smokeCheck(awakeTicks > 0, "Waking restarts animation")
            // Hiding in either transition must finish its geometry without waiting for a stopped clock.
            showChat(); panel.orderOut(nil); await settle(500)
            smokeCheck(perchTransition == nil, "Hiding settles an opening transition")
            panel.makeKeyAndOrderFront(nil); await settle(500)
            toggleChatWidth(); panel.orderOut(nil); await settle(500)
            smokeCheck(!widthSliding, "Hiding settles a width transition")
            panel.makeKeyAndOrderFront(nil); await settle(500)
            smokeCheck(chat.draft == draft, "Hide, show and screen rest preserve the draft")

            let fixture = hermes
            for operation in IMessageFeature.enabled ? ["poll", "search", "older", "around"] : ["poll"] {
                let delayed = DelayedHermesSmoke()
                replaceHermesSource(delayed)
                await settle(100)
                let revision = hermesRevision
                switch operation {
                case "poll":
                    polling = true
                    monitorQueue.async {
                        let result = delayed.poll(unreadSince: nil)
                        DispatchQueue.main.async {
                            self.finishRefresh(snapshot: Snapshot(observedAt: Date(), tasks: [], connections: [], warning: nil, screenUseUntil: nil, screenFocus: nil),
                                               conversation: result, portraits: result, activity: nil, revision: revision)
                        }
                    }
                case "search": chat.openSearch(); chat.query = "이전"
                case "older": chat.loadingOlder = true; loadOlderChat(before: nil)
                default: selectChatResult(delayed.message)
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                var started = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if delayed.entered.wait(timeout: .now()) == .success { started = true; break }
                    await settle(10)
                }
                smokeCheck(started, "Delayed \(operation) started (search open=\(chat.searchOpen), query=\(chat.query))")
                let begin = ProcessInfo.processInfo.systemUptime
                replaceHermesSource(fixture)
                let elapsed = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                smokeCheck(elapsed < 1000, "Switching source does not wait for background I/O: \(elapsed) ms")
                delayed.release.signal()
                // Wait for the serial queue and then the main-thread completion, without blocking the main thread.
                await withCheckedContinuation { continuation in
                    monitorQueue.async { DispatchQueue.main.async { continuation.resume() } }
                }
                smokeCheck(!storedMessages.contains(delayed.message) && !chat.messages.contains(delayed.message) && !chat.results.contains(delayed.message), "Old \(operation) cannot repopulate the new source")
                smokeCheck(!chat.searching && !chat.loadingOlder && chat.draft == draft, "Switching during \(operation) restores controls and keeps the draft")
            }
            let restored = await withCheckedContinuation { continuation in
                monitorQueue.async { continuation.resume(returning: fixture.poll(unreadSince: nil)) }
            }
            applyChat(restored)
            smokeCheck((IMessageFeature.enabled ? !chat.messages.isEmpty : chat.messages.isEmpty) && chat.draft == draft, "The replacement source obeys the iMessage feature switch")
            let data = try! JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: destination.appendingPathComponent("lifecycle-metrics.json"))
            capture(destination: destination.appendingPathComponent("restored"))
            print("PASS: animation lifecycle, hidden/screen-rest callbacks, delayed source changes and draft preservation")
            NSApp.terminate(nil)
        }
    }
}
