import AppKit
import SwiftUI

/// Smoke-only references to the text's exact drawing bounds, excluding the spinner and elapsed seconds.
enum WritingShimmerProbe {
    final class Entry {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    static var views: [String: [Entry]] = [:]
    static func record(_ view: NSView, key: String) {
        views[key] = (views[key] ?? []).filter { $0.view != nil && $0.view !== view } + [.init(view)]
    }
    static func visible(_ key: String) -> NSView? {
        views[key]?.compactMap(\.view).first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
    }
}

private struct WritingShimmerMeasure: NSViewRepresentable {
    let key: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        WritingShimmerProbe.record(view, key: key)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { WritingShimmerProbe.record(view, key: key) }
}

extension View {
    @ViewBuilder func writingSmokeMeasure(_ key: String) -> some View {
        if CommandLine.arguments.contains("--ui-smoke-chat") {
            background(WritingShimmerMeasure(key: key).allowsHitTesting(false).accessibilityHidden(true))
        } else { self }
    }
}

extension AppDelegate {
    /// T-03/04: exercise the real thread renderer and stopControl using SlackSetup's in-memory thinking record.
    @MainActor func verifyWritingShimmer(destination: URL) async {
        let model = slack.model
        let saved = (model.threads, model.open, model.selected, model.query, model.stopped, chat.expanded)
        defer {
            model.threads = saved.0; model.open = saved.1; model.selected = saved.2
            model.query = saved.3; model.stopped = saved.4; chat.expanded = saved.5
        }
        let folder = destination.appendingPathComponent("writing-shimmer")
        let spinnerFolder = destination.appendingPathComponent("writing-spinner")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: spinnerFolder, withIntermediateDirectories: true)
        let now = Date()
        let ts = String(format: "%.6f", now.timeIntervalSince1970 - 7200)
        guard case .success(let json) = SlackSmokeFixture.api(now: now).call("conversations.replies", ["channel": "CCOW", "ts": ts]),
              let lines = json["messages"] as? [[String: Any]],
              let thinking = lines.compactMap({ $0["text"] as? String }).last, SlackText.isThinking(thinking)
        else { smokeFailed("Shimmer needs SlackSetup's synthetic thinking record") }
        let root = ChatMessage(id: "writing-root", fromUser: true, speaker: "나", body: "합성 답변 준비 확인", date: now)
        let reply = ChatMessage(id: "writing-reply", fromUser: false, speaker: "개인비서", body: thinking, date: now, profile: "personal-secretary")
        var thread = SlackThread(id: "writing-smoke", room: "CCOW", ts: ts, root: root, replies: [reply], replyCount: 1,
                                 loaded: true, latest: now.timeIntervalSince1970, latestFromUser: false)
        let key = "stop:" + thread.id
        let spinnerKey = "spinner:" + thread.id
        model.selected = "CCOW"; model.query = ""; model.stopped = []
        model.threads = [thread]; model.open = [thread.id]; chat.expanded = true
        model.requestScroll(SlackModel.end(thread.id))
        func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        await settle(0.8)
        for _ in 0..<40 where WritingShimmerProbe.visible(key) == nil { await settle(0.1) }
        func snapshot(_ name: String, key measuredKey: String) -> (CGRect, [UInt8]) {
            guard let probe = WritingShimmerProbe.visible(measuredKey), let host = probe.window?.contentView else {
                smokeFailed("Working thread has a visible probe: " + measuredKey)
            }
            host.layoutSubtreeIfNeeded()
            let rect = probe.convert(probe.bounds, to: host)
            let spinner = measuredKey == spinnerKey
            smokeCheck((spinner ? rect.size == CGSize(width: 8, height: 13) : rect.width > 20 && rect.height > 5) && host.bounds.contains(rect),
                       spinner ? "Spinner stays 8×13 inside the conversation" : "Activity text stays inside the conversation")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { smokeFailed("Activity text can be captured") }
            host.cacheDisplay(in: rect, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: (spinner ? spinnerFolder : folder).appendingPathComponent(name + ".png"))
            var pixels: [UInt8] = []
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                pixels += [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
            } }
            return (rect, pixels)
        }
        // Choose two distinct positions within a cycle, avoiding timing-dependent equal/offscreen frames.
        func waitForPhase(_ target: Double) async {
            let current = Date().timeIntervalSinceReferenceDate
            let within = current - floor(current / WritingShimmer.period) * WritingShimmer.period
            let wanted = WritingShimmer.period * target
            let delay = wanted > within ? wanted - within : WritingShimmer.period + wanted - within
            await settle(delay)
        }
        await waitForPhase(0.28)
        let first = snapshot("working-1", key: key)
        await waitForPhase(0.68)
        let second = snapshot("working-2", key: key)
        try! "frame1=\(first.0) frame2=\(second.0) changed=\(first.1 != second.1)\n"
            .write(to: folder.appendingPathComponent("comparison.txt"), atomically: true, encoding: .utf8)
        smokeCheck(first.0 == second.0, "T-03 activity frame is unchanged across phases")
        let reduce = ChatView.reducesMotionForChecks
        smokeCheck(reduce ? first.1 == second.1 : first.1 != second.1,
                   reduce ? "T-04 reduce motion activity pixels remain identical" : "T-03 shimmer changes activity text pixels")
        // Spinner T-03/04: middle of steps zero and three leaves at least one 24fps tick before capture.
        func waitForSpinnerStep(_ step: Int) async {
            let period = 6 * WritingSpinner.stepDuration
            let current = Date().timeIntervalSinceReferenceDate
            let within = current - floor(current / period) * period
            let wanted = (Double(step) + 0.5) * WritingSpinner.stepDuration
            await settle(wanted > within ? wanted - within : period + wanted - within)
        }
        await waitForSpinnerStep(0)
        let spinnerFirst = snapshot("working-1", key: spinnerKey)
        await waitForSpinnerStep(3)
        let spinnerSecond = snapshot("working-2", key: spinnerKey)
        try! "frame1=\(spinnerFirst.0) frame2=\(spinnerSecond.0) changed=\(spinnerFirst.1 != spinnerSecond.1)\n"
            .write(to: spinnerFolder.appendingPathComponent("comparison.txt"), atomically: true, encoding: .utf8)
        smokeCheck(spinnerFirst.0 == spinnerSecond.0, "Spinner T-03 frame is unchanged across steps")
        smokeCheck(reduce ? spinnerFirst.1 == spinnerSecond.1 : spinnerFirst.1 != spinnerSecond.1,
                   reduce ? "Spinner T-04 reduce motion pixels remain identical" : "Spinner T-03 clockwise tail changes pixels")
        // Pausing must freeze the existing timeline, without leaving an independent animation running.
        chat.expanded = false
        await settle()
        let folded = snapshot("paused-1", key: key)
        let spinnerFolded = snapshot("paused-1", key: spinnerKey)
        await settle(0.5)
        let foldedAgain = snapshot("paused-2", key: key)
        let spinnerFoldedAgain = snapshot("paused-2", key: spinnerKey)
        smokeCheck(folded.1 == foldedAgain.1, "AC-04 folded conversation stops activity animation")
        smokeCheck(spinnerFolded.0 == spinnerFoldedAgain.0 && spinnerFolded.1 == spinnerFoldedAgain.1,
                   "Spinner T-03 folded conversation stops the tail")
        chat.expanded = true
        model.stopped.insert(thread.id)
        await settle()
        smokeCheck(WritingShimmerProbe.visible(key) == nil && WritingShimmerProbe.visible(spinnerKey) == nil, "T-03 undo removes activity text and spinner")
        capture(destination: folder.appendingPathComponent("undo"))
        model.stopped = []
        thread.replies[0].body = "합성 답변이 끝났습니다"
        model.threads = [thread]
        await settle()
        smokeCheck(WritingShimmerProbe.visible(key) == nil && WritingShimmerProbe.visible(spinnerKey) == nil, "T-03 completed work removes activity text and spinner")
        capture(destination: folder.appendingPathComponent("finished"))
        try! "PASS spinner T-03/T-04 reduceMotion=\(reduce) frame1=\(spinnerFirst.0) frame2=\(spinnerSecond.0) changed=\(spinnerFirst.1 != spinnerSecond.1); paused pixels/frame equal; undo/finished absent\n"
            .write(to: spinnerFolder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        try! "PASS T-03/T-04 reduceMotion=\(reduce) frame1=\(first.0) frame2=\(second.0) changed=\(first.1 != second.1); paused pixels equal; undo/finished activity absent\n"
            .write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }
}
