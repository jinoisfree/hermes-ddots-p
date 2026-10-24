import AppKit
import SwiftUI

/// Counters are dormant outside the measured part of a synthetic UI smoke.
enum SlackInputSmoke {
    static var measuring = false
    static var bodies = 0, conversations = 0, threads = 0, lines = 0
    static func countBody() { if measuring { bodies += 1 } }
    static func countConversation() { if measuring { conversations += 1 } }
    static func countThread() { if measuring { threads += 1 } }
    static func countLine() { if measuring { lines += 1 } }
}

extension AppDelegate {
    func verifySlackInput(destination: URL, then finish: @escaping () -> Void) {
        verifySlackInputModel()
        Task { @MainActor [self] in
            let model = slack.model
            let savedThreads = model.threads, savedOpen = model.open, savedTyping = model.typing
            let savedDraft = model.draft, savedPicked = model.picked, savedNewPost = model.newPost
            defer {
                SlackInputSmoke.measuring = false
                model.threads = savedThreads; model.open = savedOpen; model.typing = savedTyping
                model.draft = savedDraft; model.picked = savedPicked; model.newPost = savedNewPost
            }
            let root = ChatMessage(id: "input-root", fromUser: true, speaker: "", body: "합성 입력 성능 검사", date: Date(), profile: "")
            let replies = (0..<50).map { index in
                ChatMessage(id: "input-reply-\(index)", fromUser: false, speaker: "개인비서",
                            body: "**합성 답변 \(index)** — 한글 입력 중 펼친 스레드입니다.\n> 인용문과 `코드`\nhttps://example.com/check/\(index)", date: Date(), profile: "personal-secretary")
            }
            let thread = SlackThread(id: "input-thread", room: model.postRoom ?? "SYNTHETIC", ts: "100.1", root: root,
                                     replies: replies, replyCount: 50, loaded: true, latest: 100, latestFromUser: false)
            model.threads = [thread]; model.open = [thread.id]; model.typing = [:]
            model.picked = thread.id; model.newPost = false; model.draft = "입력 "
            NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
            model.focusRevision += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let editor = panel.firstResponder as? NSTextView, editor.isEditable, model.composerFocused else {
                smokeFailed("Input benchmark requires the focused Slack editor")
            }
            ChatView.moveCaretToEnd(in: panel)
            var report = "Synthetic expanded thread: 50 replies, 30 updates per path. Times include mutation and next main-queue layout; exclude the 50 ms settling pause.\n"
            let baseline = CommandLine.arguments.contains("--ui-smoke-input-baseline")
            for marked in [false, true] {
                SlackInputSmoke.bodies = 0; SlackInputSmoke.conversations = 0; SlackInputSmoke.threads = 0
                SlackInputSmoke.measuring = true
                var times: [Double] = []
                for index in 0..<30 {
                    let syllable = ["ㅎ", "하", "한", "한ㄱ", "한그", "한글"][index % 6]
                    let start = ProcessInfo.processInfo.systemUptime
                    if marked {
                        editor.setMarkedText(syllable, selectedRange: NSRange(location: (syllable as NSString).length, length: 0),
                                             replacementRange: NSRange(location: NSNotFound, length: 0))
                    } else { model.draft = "입력 " + syllable }
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { self.pet.layoutSubtreeIfNeeded(); continuation.resume() }
                    }
                    times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                SlackInputSmoke.measuring = false
                let line = "\(marked ? "marked" : "draft"): body=\(SlackInputSmoke.bodies), conversation=\(SlackInputSmoke.conversations), thread=\(SlackInputSmoke.threads), mean_ms=\(times.reduce(0, +) / Double(times.count)), max_ms=\(times.max()!), samples_ms=\(times)\n"
                report += line
                try! report.write(to: destination.appendingPathComponent("slack-input.txt"), atomically: true, encoding: .utf8)
                print(line)
                smokeCheck(baseline || (SlackInputSmoke.bodies == 0 && SlackInputSmoke.conversations == 0 && SlackInputSmoke.threads == 0), "Ordinary Korean input does not recompute the conversation: " + line)
                editor.unmarkText()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            // A committed syllable must reach the binding too, not just the editor's marked buffer.
            SlackInputSmoke.bodies = 0; SlackInputSmoke.conversations = 0; SlackInputSmoke.threads = 0
            SlackInputSmoke.measuring = true
            let beforeCommit = model.draft
            editor.insertText("한글", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(nanoseconds: 300_000_000)
            SlackInputSmoke.measuring = false
            smokeCheck(model.draft != beforeCommit && model.draft.contains("한글"), "Committed editor input reaches the draft binding")
            smokeCheck(baseline || (SlackInputSmoke.bodies == 0 && SlackInputSmoke.conversations == 0 && SlackInputSmoke.threads == 0), "Committed Korean input leaves the conversation unchanged")
            report += "PASS: committed editor input reaches the binding; derived destinations and rendering cache checks.\n"
            try! report.write(to: destination.appendingPathComponent("slack-input.txt"), atomically: true, encoding: .utf8)
            finish()
        }
    }
}

extension AppDelegate {
    private func verifySlackInputModel() {
        let model = SlackModel()
        model.source = .slack; model.selected = Ddots.room; model.ddotsHub = "HUB"
        model.ddotsMembers = [DdotsMember(profile: "personal-secretary", name: "개인비서", room: "DJ"),
                              DdotsMember(profile: "sns-manager", name: "SNS담당", room: "DC"),
                              DdotsMember(profile: "work-assistant", name: "업무비서", room: "TH")]
        let usual = model.ddotsMembers.contains { $0.profile == Ddots.defaultTarget } ? Ddots.defaultTarget : model.ddotsMembers.first?.profile
        let configured = !DdotsConfig.shared.members.isEmpty
        smokeCheck(model.litRecipientProfile == nil && model.recipient?.profile == usual, "Empty faces do not change the sending recipient")
        model.draft = " \n\t"
        smokeCheck(model.litRecipientProfile == nil, "Whitespace does not light a face")
        model.draft = ""
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        model.draft = "안녕"
        smokeCheck(changes == 1, "Empty to nonempty draft notifies the surrounding controls")
        smokeCheck(model.litRecipientProfile == nil && model.recipient?.profile == usual, "Words about no one light nobody and still go to the usual character")
        if configured {
            model.draft = "노션 정리해줘"
            smokeCheck(model.litRecipientProfile == "work-assistant", "Notion goes to the work secretary under the hub decision")
            model.draft = "위키에서 지난 회의록 찾아줘"
            smokeCheck(model.litRecipientProfile == nil, "Wiki belongs to a character without a face here, so nobody lights")
            model.draft = "내일 일정 확인해줘"
            smokeCheck(model.litRecipientProfile == "work-assistant", "Schedule requests light work-assistant, matching Hermes base/hub routing (D1)")
        } else {
            for text in ["노션 정리해줘", "내일 일정 확인해줘", "SNS담당 안녕"] {
                model.draft = text
                smokeCheck(model.litRecipientProfile == nil && model.postProfile == usual,
                           "Without a Hermes config, words alone light nobody and go to the first character")
            }
        }
        changes = 0; model.draft = "안녕"
        changes = 0; model.composer.text = "안녕하세요"
        smokeCheck(changes == 0 && model.draft == "안녕하세요", "Editor updates preserve the draft API without invalidating the parent")
        // Preview follows the draft without adding a synthetic mention to the outgoing post.
        model.draft = "SNS담당 안녕"
        if configured {
            smokeCheck(changes == 1 && model.postProfile == "sns-manager", "A named recipient updates the hub preview")
        } else {
            smokeCheck(model.litRecipientProfile == nil && model.postProfile == usual,
                       "Without a Hermes config, words alone light nobody and go to the first character")
        }
        model.draft = "@SNS담당 안녕"
        smokeCheck(changes == 1 && model.postProfile == "sns-manager", "A routed profile change notifies the parent")
        smokeCheck(model.litRecipientProfile == "sns-manager", "A call lights only its recipient")
        changes = 0; model.draft = "@SNS담당 안녕하세요"
        smokeCheck(changes == 0, "Further text for the same recipient stays local")
        model.draft = ""
        let root = ChatMessage(id: "derived-root", fromUser: true, speaker: "", body: "합성", date: Date(), profile: "")
        let reply = ChatMessage(id: "derived-reply", fromUser: false, speaker: "개인비서", body: "합성 답변", date: Date(), profile: "personal-secretary")
        let thread = SlackThread(id: "derived-thread", room: "DJ", ts: "1.0", root: root, replies: [reply], replyCount: 1, loaded: true, latest: 1, latestFromUser: false)
        model.threads = [thread]
        model.followPost(room: "DJ", ts: "1.0", revision: model.beginPost())
        smokeCheck(model.target?.id == thread.id, "A synthetic answer selects its thread")
        smokeCheck(model.litRecipientProfile == "personal-secretary", "An empty reply keeps its owner's face lit")
        // The answered thread stays the destination whoever the words name, as in the hub's project threads (36a6430).
        changes = 0; model.draft = "@SNS담당 안녕"
        smokeCheck(changes == 1 && model.target?.id == thread.id && model.postProfile == "sns-manager", "A call changes who is named, not the automatic reply, and notifies")
        changes = 0; model.draft = "안녕"
        smokeCheck(changes == 1 && model.target?.id == thread.id, "Plain words keep the reply destination and notify the change back")
        var sent = false
        model.onSend = { _, _, _, _ in sent = true }; model.send()
        smokeCheck(sent && model.composer.text.isEmpty, "Synthetic send clears the independent editor")
        model.newPost = true; model.picked = nil; model.replyTo = nil
        model.draft = "안녕"; sent = false; model.send()
        smokeCheck(sent && model.litRecipientProfile == nil && model.recipient?.profile == usual, "Sending a new post clears illumination without changing its default recipient")
        let cow = model.ddotsMembers[1]
        model.aim(cow)
        smokeCheck(model.litRecipientProfile == "sns-manager", "Explicit face selection remains lit")
        model.aim(cow)
        smokeCheck(model.litRecipientProfile == nil, "Releasing an empty selection lights nobody")
        model.draft = "실패한 글 복원"
        smokeCheck(model.composer.text == "실패한 글 복원", "Programmatic draft restoration reaches the editor")

        let link = PaletteRGB(r: 0, g: 0, b: 1)
        var renders = 0
        func render(_ text: String) -> AttributedString { renders += 1; return AttributedString(text) }
        func cached(_ body: String = "본문", dark: Bool = false, color: PaletteRGB? = nil) {
            _ = model.presentation(reply.id, body: body, dark: dark, link: color ?? link, style: render)
        }
        cached(); cached()
        smokeCheck(renders == 1, "Repeated reply presentation uses the cache")
        cached("접힌 본문"); cached("접힌 본문", dark: true)
        cached("접힌 본문", dark: true, color: PaletteRGB(r: 1, g: 0, b: 0))
        smokeCheck(renders == 4, "Displayed body, appearance and link color invalidate the cache")
        model.threads = []; cached()
        smokeCheck(renders == 5, "Removed messages leave the cache")
        model.selected = "OTHER"; cached()
        smokeCheck(renders == 6, "Changing rooms clears cached replies")
    }
}


extension AppDelegate {
    /// Synthetic hub screenshots; sending is exercised only on the isolated model above.
    func verifyDdotsFaces(destination: URL) {
        verifySlackInputModel()
        Task { @MainActor [self] in
            await ensureDdotsSmoke(destination: destination)
            let model = slack.model
            smokeCheck(model.isDdots && model.ddotsHub != nil, "Face screenshots use the synthetic hub")
            model.newPost = true; model.picked = nil; model.replyTo = nil; model.ddotsPicked = false; model.draft = ""
            // Preserve the existing hub recipient/outgoing invariant independently of face illumination.
            smokeCheck(model.target == nil && model.postRoom == "CHUB" && model.recipient?.profile == Ddots.defaultTarget
                && model.outgoing("안녕") == "안녕" && model.outgoing("@SNS담당 안녕") == "@SNS담당 안녕",
                "A new post reaches the usual character without an automatic mention")
            for (name, text, profile) in [("faces-empty", "", Optional<String>.none),
                                          ("faces-plain", "안녕", Optional<String>.none),
                                          ("faces-mention", "@SNS담당 안녕", Optional("sns-manager"))] {
                model.draft = text
                try? await Task.sleep(nanoseconds: 700_000_000)
                smokeCheck(model.litRecipientProfile == profile, "Synthetic face preview: " + name)
                let folder = destination.appendingPathComponent(name)
                capture(destination: folder)
                do {
                    let png = try Data(contentsOf: folder.appendingPathComponent("chat.png"))
                    try png.write(to: destination.appendingPathComponent(name + ".png"))
                } catch { smokeFailed("Cannot save face screenshot: " + name) }
            }
            try? "PASS: empty/whitespace, plain/mention, picked/reply, send reset; sending destination unchanged\n".write(to: destination.appendingPathComponent("faces-checks.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate {
    /// Synthetic stop/undo screenshots; the send callback is replaced so nothing leaves the app.
    func verifyAgentStop(destination: URL) {
        Task { @MainActor [self] in
            await ensureDdotsSmoke(destination: destination)
            let model = slack.model
            // The synthetic workspace lands asynchronously; a busy machine can take longer than a second.
            for _ in 0..<80 where !(model.isDdots && !model.threads.isEmpty) { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard model.isDdots, let thread = model.threads.last else { smokeFailed("Stop screenshots need a synthetic ddots thread: isDdots=\(model.isDdots) selected=\(model.selected ?? "nil") threads=\(model.threads.count) rooms=\(model.rooms.count) connected=\(slack.connected) syncing=\(slack.syncing) publishes=\(slack.publishCount) scrollInputAt=\(model.scrollInputAt) now=\(ProcessInfo.processInfo.systemUptime)") }
            var sent: [(String, String?)] = []
            model.onSend = { text, _, thread, _ in sent.append((text, thread?.id)) }
            model.open.insert(thread.id)
            model.typing[thread.id] = [TypingIndicator(id: "stop-smoke", speaker: "업무비서", profile: "work-assistant")]
            model.requestScroll("slack-bottom")
            for step in ["stop-working", "stop-stopped"] {
                if step == "stop-stopped" {
                    model.stop(thread); model.stop(thread)
                    smokeCheck(sent.count == 1 && sent[0].0 == AgentStop.command && sent[0].1 == thread.id, "Stop posts the command once, in its own thread")
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                let folder = destination.appendingPathComponent(step)
                capture(destination: folder)
                do { try Data(contentsOf: folder.appendingPathComponent("chat.png")).write(to: destination.appendingPathComponent(step + ".png")) }
                catch { smokeFailed("Cannot save stop screenshot: " + step) }
            }
            model.askUndo(thread); model.askUndo(thread)
            smokeCheck(sent.count == 2 && sent[1].0 == AgentStop.undoRequest && sent[1].1 == thread.id && !model.stopped.contains(thread.id), "Undo asks once, in the same thread")
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate {
    /// Synthetic strip screenshots: question and notification marks per tab, narrow and wide.
    func verifyRoomNotices(destination: URL) {
        Task { @MainActor [self] in
            await ensureDdotsSmoke(destination: destination)
            let model = slack.model
            for _ in 0..<80 where model.rooms.count < 3 { try? await Task.sleep(nanoseconds: 100_000_000) }
            let tabs = [Ddots.room] + model.rooms.map(\.id).filter { $0 != Ddots.room }
            guard tabs.count >= 3 else { smokeFailed("Notice marks need synthetic tabs") }
            let marks: [String: SlackModel.RoomNotice] = [tabs[0]: .init(alerts: 2, questions: 1), tabs[1]: .init(alerts: 0, questions: 1), tabs[2]: .init(alerts: 3, questions: 0)]
            for (step, width) in [("notices-narrow", SlackSidebar.width), ("notices-wide", SlackSidebar.expandedWidth)] {
                model.sidebarWidth = width
                model.roomNotices = marks
                try? await Task.sleep(nanoseconds: 900_000_000)
                model.roomNotices = marks; model.unread = [tabs[0]: 3, tabs[2]: 12]
                try? await Task.sleep(nanoseconds: 200_000_000)
                let folder = destination.appendingPathComponent(step)
                capture(destination: folder)
                do { try Data(contentsOf: folder.appendingPathComponent("chat.png")).write(to: destination.appendingPathComponent(step + ".png")) }
                catch { smokeFailed("Cannot save notice screenshot: " + step) }
            }
            // A plain notification goes away once its thread is clicked; nothing is sent.
            slack.publish(); try? await Task.sleep(nanoseconds: 300_000_000)
            var seen = "no synthetic notification in this room"
            if let id = model.notices.first(where: { $0.id == SlackNotice.alertID })?.threads.first, let thread = model.threads.first(where: { $0.id == id }) {
                model.pick(thread, foldable: false)
                try? await Task.sleep(nanoseconds: 300_000_000)
                smokeCheck(!(model.notices.first { $0.id == SlackNotice.alertID }?.threads.contains(id) ?? false), "Clicking a notification's thread clears it")
                smokeCheck(model.bells[id] == false, "A cleared notification keeps a quiet bell to put it back")
                seen = "PASS: clicked notification cleared, quiet bell kept"
            }
            try? (seen + "\n").write(to: destination.appendingPathComponent("notices-checks.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate {
    /// Drags the pet up and back as a hand would (`movePet`, one step per frame) while the window shrinks and grows,
    /// and records per step whether the conversation was hidden, jumped, or drew nothing.
    func verifyPetDrag(destination: URL) {
        Task { @MainActor [self] in
            await ensureDdotsSmoke(destination: destination)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let model = slack.model
            guard let scroll = model.scrollView, let start = placementTarget?.globalSprite.origin else { smokeFailed("Pet drag needs an open conversation") }
            var lines: [String] = []
            var hidden = 0, blank = 0, jumps = 0
            var lastFromBottom: CGFloat?
            var instant: [String] = []
            func blankConversation() -> Bool {
                guard let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { return true }
                scroll.cacheDisplay(in: scroll.bounds, to: rep)
                // A conversation with words has dark and light pixels; an empty or transparent one has neither.
                var lit = 0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 6) { for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
                    if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5, c.brightnessComponent > 0.6 { lit += 1 }
                } }
                return lit < 20
            }
            let path = (0..<60).map { CGFloat($0) * 10 } + (0..<60).map { CGFloat(59 - $0) * 10 }
            for (index, dy) in path.enumerated() {
                movePet(to: CGPoint(x: start.x, y: start.y + dy))
                // A Slack pass lands now and then while the hand is still moving, as it does about once a second.
                if index % 6 == 3 { slack.publish(); model.threads = model.threads }
                // What a display commit in this same turn would show: layout forced now, before any deferred work.
                panel.contentView?.layoutSubtreeIfNeeded()
                if scroll.alphaValue < 0.99 { hidden += 1 }
                if let document = scroll.documentView {
                    let clip = scroll.contentView.bounds
                    instant.append("step=\(index) instant_fromBottom=\(Int(document.bounds.height - clip.maxY)) viewport=\(Int(clip.height)) document=\(Int(document.bounds.height))")
                }
                // The instant after the move, before this turn's layout and drawing reach the screen.
                for (tag, delay) in [("a", 0), ("b", 4_000_000)] {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay)) }
                    if CommandLine.arguments.contains("--ui-smoke-drag-frames"), let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                       let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        try? data.write(to: destination.appendingPathComponent(String(format: "instant-%03d%@.png", index, tag)))
                    }
                }
                try? await Task.sleep(nanoseconds: 12_000_000)
                let clip = scroll.contentView.bounds, document = scroll.documentView?.bounds.height ?? 0
                let fromBottom = document - clip.maxY
                let isHidden = scroll.alphaValue < 0.99 || scroll.isHiddenOrHasHiddenAncestor
                let isBlank = index % 4 == 0 ? blankConversation() : false
                if isHidden { hidden += 1 }
                if isBlank { blank += 1 }
                if let last = lastFromBottom, abs(fromBottom - last) > 40 { jumps += 1 }
                lastFromBottom = fromBottom
                lines.append("step=\(index) dy=\(dy) window=\(Int(panel.frame.height)) viewport=\(Int(clip.height)) alpha=\(scroll.alphaValue) pending=\(model.entryViewportPending) fromBottom=\(Int(fromBottom)) blank=\(isBlank)")
                // What the window server shows for this window right now, frames included where content lags the frame.
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                    let rep = NSBitmapImageRep(cgImage: image)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: destination.appendingPathComponent(String(format: "frame-%03d.png", index)))
                    }
                }
            }
            lines.insert("hidden_steps=\(hidden) blank_samples=\(blank) bottom_jumps=\(jumps) rehides_prevented=\(model.entryRehides) native=\(NativeListFeature.enabled)", at: 0)
            lines += instant
            try? lines.joined(separator: "\n").write(to: destination.appendingPathComponent("pet-drag.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate {
    /// While the pet is dragged continuously, the window is captured as the window server shows it every few
    /// milliseconds; frames whose glass goes missing or flashes bright are counted.
    func verifyPetDragFlicker(destination: URL) {
        Task { @MainActor [self] in
            await ensureDdotsSmoke(destination: destination)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let start = placementTarget?.globalSprite.origin else { smokeFailed("Pet drag needs an open conversation") }
            var frames: [(Double, Int, Int, Double, Double)] = []
            var running = true
            let began = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
                guard let self, running,
                      let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(self.panel.windowNumber), [.boundsIgnoreFraming, .nominalResolution]) else { return }
                let rep = NSBitmapImageRep(cgImage: image)
                var opaque = 0, bright = 0, total = 0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 8) { for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    total += 1
                    if c.alphaComponent > 0.8 { opaque += 1; if c.brightnessComponent > 0.85 { bright += 1 } }
                } }
                frames.append((ProcessInfo.processInfo.systemUptime - began, rep.pixelsWide, rep.pixelsHigh,
                               Double(opaque) / Double(max(1, total)), Double(bright) / Double(max(1, total))))
            }
            RunLoop.main.add(timer, forMode: .common)
            // Slow, steady drag inside the range where the window only changes height (no flip across the pet).
            for pass in 0..<3 {
                for step in 0..<40 { movePet(to: CGPoint(x: start.x, y: start.y + 200 + CGFloat(pass % 2 == 0 ? step : 39 - step) * 8)); try? await Task.sleep(nanoseconds: 16_000_000) }
            }
            running = false; timer.invalidate()
            var text = "native=\(NativeListFeature.enabled) frames=\(frames.count)\n"
            for f in frames { text += String(format: "t=%.3f size=%dx%d opaque=%.2f bright=%.3f\n", f.0, f.1, f.2, f.3, f.4) }
            try? text.write(to: destination.appendingPathComponent("flicker.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
