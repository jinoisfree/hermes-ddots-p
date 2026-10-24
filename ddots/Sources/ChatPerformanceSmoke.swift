import AppKit
import CoreFoundation

/// Counts view construction only in the opt-in synthetic benchmark.
enum ChatPerfProbe {
    static let enabled = CommandLine.arguments.contains("--ui-smoke-chat-perf")
    static var activeMS = 0.0, longestMS = 0.0
    static var began: Double?
    static var observer: CFRunLoopObserver?
    static func start() {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, CFIndex.max) { _, activity in
            let now = ProcessInfo.processInfo.systemUptime
            if activity == .afterWaiting || activity == .entry {
                if began == nil { began = now }
            } else if activity == .beforeWaiting || activity == .exit {
                if let began {
                    let elapsed = (now - began) * 1000
                    activeMS += elapsed; longestMS = max(longestMS, elapsed)
                }
                began = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    static var counts: [String: Int] = [:]
    static func hit(_ name: String) { if enabled { counts[name, default: 0] += 1 } }
}

extension AppDelegate {
    func verifyChatPerformance(destination: URL) {
        Task { @MainActor [self] in
            if NativeListFeature.enabled && CommandLine.arguments.contains("--ui-smoke-native-captures") {
                await verifyNativeCellState(destination: destination)
            }
            if NativeListFeature.enabled && CommandLine.arguments.contains("--ui-smoke-native-text") {
                await verifyNativeTextCard(destination: destination)
            }
            ChatPerfProbe.start()
            var results: [[String: Any]] = []
            func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }
            // Synchronous mutation + forced layout is a main-thread work interval, not end-to-end latency.
            // A settling turn between samples allows SwiftUI to process its deferred updates; counters include it.
            @MainActor func sample(_ name: String, _ operation: @MainActor () -> Void) async {
                precondition(Thread.isMainThread)
                ChatPerfProbe.counts = [:]
                ChatPerfProbe.activeMS = 0; ChatPerfProbe.longestMS = 0
                ChatPerfProbe.began = ProcessInfo.processInfo.systemUptime
                let start = ProcessInfo.processInfo.systemUptime
                operation()
                panel.contentView?.layoutSubtreeIfNeeded()
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                await settle()
                results.append(["operation": name, "main_sync_ms": elapsed, "runloop_active_ms": ChatPerfProbe.activeMS, "longest_turn_ms": ChatPerfProbe.longestMS, "view_evaluations": ChatPerfProbe.counts])
            }
            if CommandLine.arguments.contains("--ui-smoke-starter_user-perf") {
                // --ui-smoke-ddots starts only the in-memory Slack transport and a temporary archive.
                slack.keepsRecord = false
                await ensureDdotsSmoke(destination: destination)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let model = slack.model
                let date = Date(timeIntervalSince1970: 1_800_000_000)
                slack.kept = ["personal-secretary": (0..<850).map { index in
                    let stamp = String(format: "%.6f", date.timeIntervalSince1970 + Double(index))
                    return DdotsLine(ts: stamp, thread: stamp, profile: "personal-secretary", name: "개인비서", mine: false,
                        at: date.timeIntervalSince1970 + Double(index),
                        text: index % 5 == 0 ? String(repeating: "합성 장문 기록입니다.\n", count: 260) : "합성 기록 \(index)", hub: true, room: "CHUB")
                }]
                slack.keptMonths = [DdotsArchive.month(date)]; slack.keptEarlier = false; slack.keptRevision += 1
                model.source = .slack; model.selected = Ddots.room; model.draft = ""
                model.choose(Ddots.room)
                slack.publish()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if CommandLine.arguments.contains("--ui-smoke-text-captures") { await captureNativeTextComparisons(destination: destination) }
                let initialCount = model.threads.count
                if NativeListFeature.enabled {
                    let state = "pending=\(model.entryViewportPending) alpha=\(model.scrollView?.alphaValue ?? -1) stamp=\(model.entryViewportStamp) ready=\(model.nativeGeometry?.isReady(stamp: model.entryViewportStamp) ?? false) document=\(String(describing: model.scrollView?.documentView?.frame)) bounds=\(String(describing: model.scrollView?.documentView?.bounds)) clip=\(String(describing: model.scrollView?.contentView.bounds)) bottom=\(String(describing: model.rowFrame("slack-bottom"))) last=\(String(describing: model.threads.last.flatMap { model.rowFrame($0.id) }))\n"
                    try? state.write(to: destination.appendingPathComponent("native-geometry.txt"), atomically: true, encoding: .utf8)
                }
                if CommandLine.arguments.contains("--ui-smoke-native-captures") {
                    let native = NativeListFeature.enabled
                    smokeCheck((model.scrollView?.documentView is NativeThreadList.Table) == native, "Feature flag selects the intended list")
                    smokeCheck(!model.entryViewportPending && (model.scrollView?.alphaValue ?? 0) > 0.99 && abs(model.place()?.fromBottom ?? .infinity) < 2,
                               "workspace is visible at its latest line before capture")
                    captureNativeList("entry", destination: destination)
                    let saved = model.threads
                    if let last = saved.last {
                        var expanded = last
                        expanded.replies = (0..<5).map { index in
                            ChatMessage(id: "native-capture-reply-\(index)", fromUser: false, speaker: "개인비서",
                                        body: "같은 합성 스레드의 답글 \(index + 1)", date: last.root.date.addingTimeInterval(Double(index + 1)))
                        }
                        expanded.replyCount = expanded.replies.count; expanded.loaded = true
                        model.threads[model.threads.count - 1] = expanded
                    }
                    if let thread = model.threads.last(where: { $0.replyCount > 0 }) {
                        model.toggle(thread)
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        if let frame = model.rowFrame(thread.id), let scroll = model.scrollView {
                            let gap = frame.maxY - scroll.contentView.bounds.maxY
                            try? "expanded_bottom_gap_points=\(gap)\n".write(to: destination.appendingPathComponent("expanded-bottom-gap.txt"), atomically: true, encoding: .utf8)
                            smokeCheck(abs(gap) < 2, "Expanded card ends at the same viewport foot as the legacy list")
                        } else { smokeFailed("Expanded card has native geometry") }
                        captureNativeList("expanded", destination: destination)
                        model.foldAll(); model.threads = saved; model.choose(Ddots.room)
                        try? await Task.sleep(nanoseconds: 900_000_000)
                    } else { smokeFailed("Native list capture needs a synthetic thread with replies") }
                }
                await sample("starter_user.edit") {
                    slack.kept["personal-secretary"]![849].text += " 본문 갱신"
                    slack.keptRevision += 1; slack.publish()
                }
                for index in 0..<20 { await sample("starter_user.type.\(index)") { model.draft.append("가") } }
                let profiling = CommandLine.arguments.contains("--ui-smoke-native-profile")
                let jumpProfile = startNativeProfile("jump", destination: destination)
                for index in 0..<(profiling ? 30 : 10) { await sample("starter_user.scroll.\(index)") {
                    if let scroll = model.scrollView, let document = scroll.documentView {
                        // Match real reading input on both renderers: a raw clip offset alone
                        // leaves entry anchoring active and can immediately snap back to bottom.
                        model.scrollInputAt = ProcessInfo.processInfo.systemUptime
                        model.userScrolls += 1
                        let span = max(0, document.bounds.height - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: span * CGFloat(index % 5) / 4))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                } }
                if let jumpProfile { await finishNativeProfile(jumpProfile, name: "jump", destination: destination) }
                if CommandLine.arguments.contains("--ui-smoke-wheel") {
                    let wheelProfile = startNativeProfile("wheel", destination: destination)
                    await measureWheel(model: model, destination: destination)
                    if let wheelProfile { await finishNativeProfile(wheelProfile, name: "wheel", destination: destination) }
                }
                if CommandLine.arguments.contains("--ui-smoke-window-check") {
                    smokeCheck(initialCount == 50 && model.hasOlder, "workspace starts with the latest 50")
                    let unread = model.unread
                    guard let visibleID = model.visibleThreads.first,
                          let scroll = model.scrollView,
                          let before = model.rowFrame(visibleID) else {
                        smokeFailed("A native page anchor is visible before expanding history"); return
                    }
                    let offset = before.minY - scroll.contentView.bounds.minY
                    model.onOlder?()
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    smokeCheck(model.threads.count == 100 && model.unread == unread, "Older adds 50 without changing unread")
                    guard let after = model.rowFrame(visibleID) else {
                        smokeFailed("The same native page anchor survives history expansion"); return
                    }
                    let shift = after.minY - scroll.contentView.bounds.minY - offset
                    try? "anchor_shift_points=\(shift)\n".write(to: destination.appendingPathComponent("page-anchor.txt"), atomically: true, encoding: .utf8)
                    smokeCheck(abs(shift) < 2, "Older preserves the native anchor within two points: \(shift)")
                    if CommandLine.arguments.contains("--ui-smoke-native-captures") { captureNativeList("older", destination: destination) }
                    let all = slack.keptThreads(for: model.ddotsShown)
                    if let oldest = all.first { model.go(to: oldest.id); await settle()
                        smokeCheck(model.threads.contains { $0.id == oldest.id }, "Notification target expands the window")
                    }
                    model.choose(Ddots.room); await settle()
                    smokeCheck(model.threads.count == 50, "Room re-entry resets to 50")
                }
                let data = try! JSONSerialization.data(withJSONObject: ["initial_threads": initialCount, "samples": results, "card_counts": model.nativeGeometry?.cardCounts ?? ["appkit": 0, "hosted": model.threads.count]], options: [.prettyPrinted, .sortedKeys])
                try! data.write(to: destination.appendingPathComponent("starter_user-performance.json"))
                NSApp.terminate(nil)
                return
            }
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let messages = (0..<500).map { index in
                ChatMessage(id: "perf-\(index)", fromUser: false, speaker: "위키담당",
                            body: index % 5 == 0 ? String(repeating: "합성 긴 대화 측정입니다.\n", count: 240) : "합성 대화 \(index)",
                            date: date.addingTimeInterval(Double(index)))
            }
            if IMessageFeature.enabled {
                chat.messages = messages; chat.hasOlder = false; chat.notice = nil; chat.draft = ""
                await settle()
                await sample("chat.arrival") { chat.messages.append(ChatMessage(id: "perf-new", fromUser: false, speaker: "위키담당", body: "새 합성 대화", date: date.addingTimeInterval(501))) }
                for index in 0..<20 { await sample("chat.type.\(index)") { chat.draft.append("가") } }
                for index in 0..<10 { await sample("chat.scroll.\(index)") {
                    if let scroll = chat.scrollView { scroll.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(index * 80))); scroll.reflectScrolledClipView(scroll.contentView) }
                } }
            }
            let model = slack.model
            // No bridge, network, credentials, or send callback participates in this fixture.
            model.onSource = nil; model.source = .slack; model.connected = true; model.selected = "CPERF"
            model.threads = (0..<320).map { index in
                let root = messages[index]
                return SlackThread(id: "CPERF:\(index)", room: "CPERF", ts: "\(index)", root: root,
                                   replies: [], replyCount: 0, loaded: true, latest: root.date.timeIntervalSince1970, latestFromUser: false)
            }
            await settle()
            await sample("slack.arrival") {
                var threads = model.threads; threads[0].root.body += " 새 글"; model.threads = threads
            }
            for index in 0..<20 { await sample("slack.type.\(index)") { model.draft.append("가") } }
            for index in 0..<10 { await sample("slack.scroll.\(index)") {
                if let scroll = model.scrollView { scroll.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(index * 80))); scroll.reflectScrolledClipView(scroll.contentView) }
            } }
            // A retained snapshot stays valid even after the timeline is edited or removed.
            let stable = model.renderedThreads[1], changed = model.renderedThreads[0]
            let inputs = model.rowInputs(stable, chat: chat, dark: false, reduceMotion: true, target: false)
            var edited = model.threads; edited[0].root.body += " 수정"; model.threads = edited
            smokeCheck(model.rowInputs(model.renderedThreads[1], chat: chat, dark: false, reduceMotion: true, target: false) == inputs, "Unchanged thread keeps its row inputs")
            smokeCheck(model.renderedThreads[0].revision != changed.revision, "Same-ID body edit changes revision")
            model.threads = []
            smokeCheck(model.rowInputs(stable, chat: chat, dark: false, reduceMotion: true, target: false) == inputs, "Retained snapshot does not read a replaced timeline")
            let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: destination.appendingPathComponent("chat-performance.json"))
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate {
    /// Opt-in profiler only: normal benchmark counts and timing remain unchanged.
    @MainActor private func startNativeProfile(_ name: String, destination: URL) -> Process? {
        guard CommandLine.arguments.contains("--ui-smoke-native-profile") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "5", "-file", destination.appendingPathComponent("sample-" + name + ".txt").path]
        do { try process.run(); return process }
        catch { smokeFailed("Cannot start native list profiler: " + error.localizedDescription) }
    }
    @MainActor private func finishNativeProfile(_ process: Process, name: String, destination: URL) async {
        while process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? "exitCode=\(process.terminationStatus)\n".write(to: destination.appendingPathComponent("sample-" + name + ".result.txt"), atomically: true, encoding: .utf8)
        smokeCheck(process.terminationStatus == 0, "Native list sample completed: " + name)
    }

    /// Trackpad-like scrolling: small continuous pixel steps posted to this process as the window server would,
    /// one per display frame. Reports main-thread run-loop time and how often SwiftUI rebuilt the list.
    @MainActor func measureWheel(model: SlackModel, destination: URL) async {
        guard let scroll = model.scrollView, let window = scroll.window, let document = scroll.documentView else { smokeFailed("Wheel test needs the Slack list") }
        let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let center = window.convertPoint(toScreen: scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil))
        let point = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - center.y)
        let start = scroll.contentView.bounds.minY
        var runs: [[String: Any]] = []
        var nativeSteps: [String] = []
        var attached = 0
        let watch = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in if event.window === window { attached += 1 }; return event }
        defer { NSEvent.removeMonitor(watch as Any) }
        for pass in 0..<3 {
            ChatPerfProbe.activeMS = 0; ChatPerfProbe.longestMS = 0
            SlackInputSmoke.conversations = 0; SlackInputSmoke.threads = 0; SlackInputSmoke.lines = 0; SlackInputSmoke.measuring = true
            let steps = 90, publishes = slack.publishCount
            // A poll pass arriving mid-swipe must wait until the list is still.
            if pass == 2 { slack.tick() }
            for index in 0..<steps {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pass == 1 ? -12 : 12, wheel2: 0, wheel3: 0) else { break }
                event.location = point
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                // CGScrollPhase: began 1, changed 2, ended 4.
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: index == 0 ? 1 : index == steps - 1 ? 4 : 2)
                // Window under the pointer (CGEventField 91/92), so AppKit attaches the event to the chat window as a real trackpad does.
                for field in [91, 92] { if let key = CGEventField(rawValue: UInt32(field)) { event.setIntegerValueField(key, value: Int64(window.windowNumber)) } }
                guard let ns = NSEvent(cgEvent: event) else { break }
                // A synthetic event carries no window, so it skips the probe's input monitor; do what that monitor
                // does for a real trackpad event in the chat window, then let the scroll view take the event.
                model.scrollInputAt = ProcessInfo.processInfo.systemUptime; model.userScrolls += 1
                let before = scroll.contentView.bounds.minY
                scroll.scrollWheel(with: ns)
                let immediate = scroll.contentView.bounds.minY
                try? await Task.sleep(nanoseconds: 16_000_000)
                if NativeListFeature.enabled && pass == 0 && index < 8 {
                    nativeSteps.append("step=\(index) dy=\(ns.scrollingDeltaY) phase=\(ns.phase.rawValue) before=\(before) immediate=\(immediate) after=\(scroll.contentView.bounds.minY) entry=\(model.entryViewportPending) revision=\(model.scrollRevision)/\(model.scrolledRevision)")
                }
            }
            let duringSwipe = slack.publishCount - publishes
            try? await Task.sleep(nanoseconds: 600_000_000)
            SlackInputSmoke.measuring = false
            runs.append(["pass": pass, "steps": steps, "runloop_active_ms": ChatPerfProbe.activeMS, "longest_turn_ms": ChatPerfProbe.longestMS,
                         "conversation_bodies": SlackInputSmoke.conversations, "thread_bodies": SlackInputSmoke.threads, "line_bodies": SlackInputSmoke.lines,
                         "offset": scroll.contentView.bounds.minY, "events_on_window": attached, "publishes_during_swipe": duringSwipe, "publishes_after": slack.publishCount - publishes - duringSwipe])
        }
        let data = try! JSONSerialization.data(withJSONObject: ["start_offset": start, "runs": runs], options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: destination.appendingPathComponent("wheel.json"))
        if !nativeSteps.isEmpty { try? nativeSteps.joined(separator: "\n").write(to: destination.appendingPathComponent("native-wheel-steps.txt"), atomically: true, encoding: .utf8) }
        smokeCheck(runs.contains { abs(($0["offset"] as? CGFloat ?? start) - start) > 100 }, "Synthetic trackpad events move the list")
    }
}

extension AppDelegate {
    /// The same fixture and capture path are used for both sides of the feature flag.
    private func captureNativeList(_ stage: String, destination: URL) {
        let name = (NativeListFeature.enabled ? "new-" : "old-") + stage
        let folder = destination.appendingPathComponent(name)
        capture(destination: folder)
        do {
            try Data(contentsOf: folder.appendingPathComponent("chat.png"))
                .write(to: destination.deletingLastPathComponent().appendingPathComponent(name + ".png"))
        } catch { smokeFailed("Cannot save native list comparison: " + name) }
    }
}
