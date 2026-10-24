import AppKit
import SwiftUI

/// Dormant outside the measured steps of the synthetic resize smoke.
enum SlackResizeSmoke {
    static let experiment: String = {
        let args = CommandLine.arguments
        guard args.contains("--ui-smoke"), args.contains("--ui-smoke-resize"),
              let index = args.firstIndex(of: "--ui-smoke-resize-without"), index + 1 < args.count else { return "" }
        return args[index + 1]
    }()
    /// The comparison run lays every row out at every step, as it was before rows were held.
    static let holdsRows: Bool = {
        let args = CommandLine.arguments
        guard args.contains("--ui-smoke"), args.contains("--ui-smoke-resize"),
              let index = args.firstIndex(of: "--ui-smoke-resize-rows"), index + 1 < args.count else { return true }
        return args[index + 1] != "none"
    }()
    static let records = CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--ui-smoke-resize")
    static func without(_ name: String) -> Bool { experiment == name }
    static var renderedHolds: [String: Bool] = [:]
    static var measuring = false
    static var places = 0, frames = 0, layouts = 0
    static var placeCallers: [String] = []
    static func reset() {
        places = 0; frames = 0; layouts = 0; placeCallers = []
        SlackInputSmoke.bodies = 0; SlackInputSmoke.conversations = 0; SlackInputSmoke.threads = 0
    }
    static var counts: [Int] { [SlackInputSmoke.bodies, SlackInputSmoke.conversations, SlackInputSmoke.threads, places, frames, layouts] }
}

extension AppDelegate {
    func verifySlackResize(destination: URL) {
        Task { @MainActor [self] in
            let model = slack.model
            let root = ChatMessage(id: "resize-root", fromUser: true, speaker: "", body: "합성 크기 조절 검사", date: Date(), profile: "")
            let replies = (0..<50).map { index in
                ChatMessage(id: "resize-reply-\(index)", fromUser: false, speaker: "개인비서",
                            body: "**합성 답변 \(index)** — 펼친 스레드에서 창의 폭과 높이를 바꿉니다. 줄이 접힐 때 높이가 바뀌는 긴 한글 문장을 함께 표시합니다.\n> 인용문과 `코드`\nhttps://example.com/check/\(index)", date: Date(), profile: "personal-secretary")
            }
            let thread = SlackThread(id: "resize-thread", room: model.postRoom ?? "SYNTHETIC", ts: "100.1", root: root,
                                     replies: replies, replyCount: 50, loaded: true, latest: 100, latestFromUser: false)
            var fixtures = [thread]
            let threadCount = SlackResizeSmoke.without("threads-40") ? 40 : (SlackResizeSmoke.without("threads-8") ? 8 : (SlackResizeSmoke.without("threads-4") ? 4 : 1))
            for index in 1..<threadCount {
                var extra = thread; extra.id = "resize-extra-\(index)"; extra.root.id = "resize-root-\(index)"
                fixtures.append(extra)
            }
            model.threads = fixtures; model.typing = [:]; model.draft = "입력 "
            var report = "Experiment: \(SlackResizeSmoke.experiment); threads: \(threadCount). 50 synthetic replies; 40 steps per case. Counts: body, conversation, thread, placePet, setFrame, measured onLayout. Times: callback through next main-queue layout; 30ms settling excluded, counts include it.\n"
            let baseline = CommandLine.arguments.contains("--ui-smoke-resize-baseline")
            var acceptable = true
            var sampler: Process?
            for expanded in [true, false] {
                model.open = expanded ? [thread.id] : []
                resizeChat(to: CGSize(width: 400 + slackStrip, height: 400))
                // Initial manual sizing clears focus, just like a user resize. Establish the
                // opened-thread fitting fixture afterwards, before measuring resize behavior.
                model.focusThread = expanded ? thread.id : nil
                model.requestScroll(expanded ? SlackModel.end(thread.id) : thread.id)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if expanded { smokeCheck(slackFitHeight != nil, "Resize fixture exercises opened-thread fitting") }
                if expanded, CommandLine.arguments.contains("--ui-smoke-resize-profile") {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "5", "-file", destination.appendingPathComponent("resize-sample.txt").path]
                    do { try process.run(); sampler = process } catch { report += "sample unavailable: \(error)\n" }
                }
                for horizontal in [true, false] {
                    let startSize = pet.chatSize
                    let startPlacement = pet.placement!
                    let fullHeight = model.scrollView?.documentView?.bounds.height ?? 0
                    let began = ProcessInfo.processInfo.systemUptime
                    pet.onResizeBegan?()
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                    pet.layoutSubtreeIfNeeded()
                    report += "ROWS held=\(SlackResizeSmoke.holdsRows) saved=\(model.resizeRows.count) live=\(model.resizeLive.count) visible=\(model.visibleThreads.count)\n"
                    let beginMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    var times: [Double] = [], totals = Array(repeating: 0, count: 6), peaks = totals
                    for step in 0..<40 {
                        let offset = CGFloat(step < 20 ? step + 1 : 39 - step)
                        let size = CGSize(width: startSize.width + (horizontal ? offset * 10 : 0),
                                          height: startSize.height - (horizontal ? 0 : offset * 6))
                        let origin = horizontal ? nil : PetLayout.resizedSpriteOrigin(startPlacement, edge: .near, size: size)
                        let visibleBefore = Set(model.visibleThreads)
                        SlackResizeSmoke.reset(); SlackResizeSmoke.measuring = true; SlackInputSmoke.measuring = true
                        let start = ProcessInfo.processInfo.systemUptime
                        pet.onResize?(size, origin)
                        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                        pet.layoutSubtreeIfNeeded()
                        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        SlackResizeSmoke.measuring = false; SlackInputSmoke.measuring = false
                        if !model.resizeRows.isEmpty, let scroll = model.scrollView {
                            let expected = scroll.contentView.bounds.width - ChatMetrics.horizontalInset * 2
                            let visible = model.threads.filter { model.resizeFrame($0.id)?.intersects(scroll.contentView.bounds) == true }
                            for row in visible {
                                smokeCheck(SlackResizeSmoke.renderedHolds[row.id] == false,
                                           "Visible row stays live during resizing: \(row.id), step=\(step)")
                                smokeCheck(abs((model.rowGeometry[row.id]?.width ?? -1) - expected) <= 0.5,
                                           "Visible row uses current width: \(row.id), step=\(step)")
                            }
                        }
                        var counts = SlackResizeSmoke.counts
                        // macOS reports a change of screens whenever it likes; that placement is not the drag's own.
                        let foreign = SlackResizeSmoke.placeCallers.filter { $0.contains("screensChanged") }.count
                        if foreign > 0 { counts[3] -= foreign; report += "screen change during step \(step): \(foreign) placement(s) left out\n" }
                        if counts[3] > 1 { report += "EXTRA PLACE step \(step):\n" + SlackResizeSmoke.placeCallers.joined(separator: "\n--\n") + "\n" }
                        times.append(elapsed)
                        for index in counts.indices { totals[index] += counts[index]; peaks[index] = max(peaks[index], counts[index]) }
                        let visible = visibleBefore.union(model.visibleThreads).count
                        if counts.enumerated().contains(where: { $0.offset != 2 && $0.element > 1 }) || counts[5] != 0 { acceptable = false }
                        report += "step \(expanded ? "open" : "folded") \(horizontal ? "width" : "height") \(step): ms=\(elapsed) counts=\(counts) visible=\(visible)\n"
                    }
                    let reading = model.rowResizePlace()
                    let ended = ProcessInfo.processInfo.systemUptime
                    pet.onResizeEnded?()
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                    pet.layoutSubtreeIfNeeded()
                    let endMS = (ProcessInfo.processInfo.systemUptime - ended) * 1000
                    report += "EDGES \(expanded ? "open" : "folded") \(horizontal ? "width" : "height"): begin_ms=\(beginMS), end_ms=\(endMS)\n"
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let scroll = model.scrollView, let document = scroll.documentView {
                        smokeCheck(abs(document.bounds.height - fullHeight) <= 0.5,
                                   "Released rows have the full-layout document height: delta=\(document.bounds.height - fullHeight)")
                        let expected = scroll.contentView.bounds.width - ChatMetrics.horizontalInset * 2
                        smokeCheck(model.threads.allSatisfy { abs((model.rowGeometry[$0.id]?.width ?? -1) - expected) <= 0.5 },
                                   "All rows use the final width after release")
                        if let reading {
                            let displacement: CGFloat
                            if reading.bottom { displacement = abs(document.bounds.maxY - scroll.contentView.bounds.maxY) }
                            else { displacement = reading.id.flatMap(model.resizeFrame).map { abs($0.minY - scroll.contentView.bounds.minY - reading.offset) } ?? .infinity }
                            smokeCheck(displacement <= 2, "Release preserves the reading position: \(displacement)pt")
                        }
                    }
                    let line = "RESULT \(expanded ? "open" : "folded") \(horizontal ? "width" : "height"): mean_ms=\(times.reduce(0,+)/40), max_ms=\(times.max()!), mean_counts=\(totals.map { Double($0)/40 }), peak_counts=\(peaks)\n"
                    report += line; print(line)
                    try! report.write(to: destination.appendingPathComponent("resize.txt"), atomically: true, encoding: .utf8)
                }
            }
            if !baseline {
                model.open = []; model.focusThread = nil
                let original = CGSize(width: 400 + slackStrip, height: 400)
                let final = CGSize(width: original.width + 70, height: 460)
                resizeChat(to: final)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let fullHeight = model.scrollView?.documentView?.bounds.height ?? 0
                resizeChat(to: original); model.requestScroll("slack-bottom")
                try? await Task.sleep(nanoseconds: 600_000_000)
                pet.onResizeBegan?(); pet.onResize?(final, nil)
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                pet.onResizeEnded?()
                try? await Task.sleep(nanoseconds: 600_000_000)
                if let scroll = model.scrollView, let document = scroll.documentView {
                    smokeCheck(abs(document.bounds.height - fullHeight) <= 0.5,
                               "A changed final width matches the unskipped document height")
                    smokeCheck(abs(document.bounds.maxY - scroll.contentView.bounds.maxY) <= 2,
                               "A changed final width keeps the reader at the bottom")
                } else { smokeFailed("Missing final resize document") }
                let size = pet.chatSize
                pet.onResizeBegan?()
                SlackResizeSmoke.reset(); SlackResizeSmoke.measuring = true
                for delta: CGFloat in [10, 20, 30] { pet.onResize?(CGSize(width: size.width + delta, height: size.height), nil) }
                smokeCheck(SlackResizeSmoke.places == 0, "A burst waits for the next main-loop turn")
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                smokeCheck(SlackResizeSmoke.places == 1 && preferredChatSize.width == size.width + 30 - slackStrip,
                           "A burst applies only its latest size")
                pet.onResize?(CGSize(width: size.width + 40, height: size.height), nil)
                pet.onResize?(CGSize(width: size.width + 50, height: size.height), nil)
                pet.onResizeEnded?()
                smokeCheck(preferredChatSize.width == size.width + 50 - slackStrip && !resizingChat && !model.measuringResize,
                           "Ending a drag flushes its final size and releases thread fitting")
                SlackResizeSmoke.measuring = false
                model.open = [thread.id]; model.focusThread = thread.id; model.onLayout?()
                try? await Task.sleep(nanoseconds: 600_000_000)
                resetChatSize()
                smokeCheck(slackFitHeight != nil && pet.chatSize.height > preferredChatSize.height,
                           "Resetting the size keeps an opened thread fitted")
                model.foldAll()
                try? await Task.sleep(nanoseconds: 600_000_000)
                smokeCheck(pet.chatSize.height == preferredChatSize.height, "Folding after reset returns to the preferred height")
                report += "PASS: burst coalescing and final pending size flush.\n"
            }
            if let sampler, !sampler.isRunning { report += "sample exit=\(sampler.terminationStatus)\n" }
            try! report.write(to: destination.appendingPathComponent("resize.txt"), atomically: true, encoding: .utf8)
            smokeCheck(baseline || acceptable, "Resize steps calculate and place at most once, without measured onLayout; see resize.txt")
            if CommandLine.arguments.contains("--ui-smoke-resize-room") {
                let room = destination.appendingPathComponent("after-resize")
                try! FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
                verifySlackRoom(destination: room)
            } else { NSApp.terminate(nil) }
        }
    }
}
