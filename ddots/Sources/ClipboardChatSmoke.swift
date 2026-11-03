import AppKit
import SwiftUI
import Vision
import ScreenCaptureKit

extension AppDelegate {
    /// Keep production hover policy and dispatch a real press/release. Never move or drag after the click.
    @MainActor func verifyClipboardChatVisibility(library: ClipboardLibrary, destination: URL) async {
        let originalPointer = pet.pointerLocation, originalAlways = pet.bubbleAlwaysShown, originalPreview = isPreview
        let physicalPointer = NSEvent.mouseLocation, originalFront = NSWorkspace.shared.frontmostApplication
        let legacy = CommandLine.arguments.contains("--ui-smoke-chat-legacy")
        let reduced = CommandLine.arguments.contains("--ui-smoke-reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var pointer = CGPoint(x: -10000, y: -10000)
        pet.pointerLocation = { pointer }; pet.bubbleAlwaysShown = false; isPreview = false
        NSApp.activate(ignoringOtherApps: true)
        defer {
            pet.pointerLocation = originalPointer; pet.bubbleAlwaysShown = originalAlways; isPreview = originalPreview
            CGWarpMouseCursorPosition(CGPoint(x: physicalPointer.x, y: NSScreen.screens.first!.frame.maxY - physicalPointer.y))
            if originalFront?.processIdentifier != getpid() { originalFront?.activate(options: []) }
        }
        let savedSnapshot = slack.snapshot, savedSource = slack.model.source, savedSelected = slack.model.selected, savedStore = slack.store
        defer { slack.model.source = savedSource; slack.model.selected = savedSelected; slack.store = savedStore; slack.acceptSnapshot(savedSnapshot) }
        let disconnected = CommandLine.arguments.contains("--ui-smoke-chat-unconnected")
        if disconnected { slack.model.source = .slack; slack.model.selected = "CCOW" }
        if !disconnected {
            slack.persists = false; slack.store = SlackFileStore(root: destination.appendingPathComponent("t63-slack-files"))
            slack.start(SlackSmokeFixture.api())
            for _ in 0..<250 {
                if slack.model.connected && !slack.model.loading && !slack.model.rooms.isEmpty { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            slack.model.selected = "CCOW"
            if CommandLine.arguments.contains("--ui-smoke-chat-search") { slack.model.findOpen = true }
        }
        var observations: [[String: Any]] = [], failures: [String] = []
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
        func head() -> CGPoint {
            let r = pet.atlas.interactionRect(in: pet.spriteRect)
            return panel.convertPoint(toScreen: pet.convert(CGPoint(x: r.midX, y: r.midY), to: nil))
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseUp ? 0 : 1)!, atStart: false)
        }
        func move(_ point: CGPoint) async {
            pointer = point
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: NSScreen.screens.first!.frame.maxY - point.y))
            event(.mouseMoved, point); await pause(0.4)
        }
        func click(_ point: CGPoint) { event(.leftMouseDown, point); event(.leftMouseUp, point) }
        func ocr(_ image: CGImage, region: CGRect) -> String {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]; request.regionOfInterest = region
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        func save() {
            let value: [String: Any] = ["legacy": legacy, "reduced": reduced, "cases": observations, "failures": failures]
            try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("clipboard-chat-visibility.json"))
        }
        // Both versions use the same screen, anchor and conversation dimensions.
        let screen = panel.screen!.visibleFrame
        func pair(_ flag: String) -> [CGFloat]? {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: flag), i + 2 < args.count,
                  let x = Double(args[i + 1]), let y = Double(args[i + 2]) else { return nil }
            return [CGFloat(x), CGFloat(y)]
        }
        if let size = pair("--ui-smoke-chat-size") { preferredChatSize = CGSize(width: size[0], height: size[1]) }
        let referenceArgs = CommandLine.arguments
        let referencePath: String
        if let i = referenceArgs.firstIndex(of: "--ui-smoke-chat-reference"), i + 1 < referenceArgs.count { referencePath = referenceArgs[i + 1] }
        else {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let root = cwd.appendingPathComponent("ddots/Tests/Fixtures/clipboard-chat-baseline.json")
            referencePath = FileManager.default.fileExists(atPath: root.path) ? root.path : cwd.appendingPathComponent("Tests/Fixtures/clipboard-chat-baseline.json").path
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: referencePath)),
              let reference = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let layouts = reference["layouts"] as? [String: [String: [String: Any]]],
              let referenceScreen = reference["screen"] as? [Double] else { smokeFailed("T-63 requires independently measured 1.6.110 reference") }
        guard zip(referenceScreen, rect(screen)).allSatisfy({ abs($0 - $1) <= 1 }) else { smokeFailed("T-63 screen differs from 1.6.110 reference; measure the reference on this display") }
        let layoutKey = (pair("--ui-smoke-chat-size") == nil ? "" : "user-") + (reduced ? "reduced" : "normal")
        guard let referenceCases = layouts[layoutKey] else { smokeFailed("T-63 missing reference layout") }
        let point = pair("--ui-smoke-chat-anchor")
        let anchor = point.map { CGPoint(x: $0[0], y: $0[1]) } ?? CGPoint(x: screen.midX - 90, y: screen.minY + 90)
        func findRow(_ root: NSView) -> NSView? {
            if String(describing: type(of: root)) == "ClipboardDrawerRow" { return root }
            return root.subviews.lazy.compactMap(findRow).first
        }
        let args = CommandLine.arguments
        let only = args.firstIndex(of: "--ui-smoke-chat-case").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        for name in ["row", "shelf", "notification", "empty", "reopen"] where only == nil || only == name {
            if chatExpanded { collapseChat(); await pause(0.8) }
            slack.model.approvalThreads = []; nudges.dismiss(); updatePet()
            pet.state = .idle; setBubbleActions([])
            library.clear(includingPins: true)
            for _ in 0..<200 { if library.entries.isEmpty { break }; await pause(0.02) }
            if name != "empty" {
                library.add(ClipboardInput(kind: .text, text: "T63 합성 복사본", source: "fixture"))
                for _ in 0..<200 { if !library.entries.isEmpty { break }; await pause(0.02) }
            }
            // Legacy has no drawer row: compare its original folded bubble in the matching history state.
            pet.clipboardAvailable = name == "shelf" || (!legacy && name != "empty")
            await move(CGPoint(x: screen.minX + 2, y: screen.minY + 2)); await pause(3.2)
            placePet(at: anchor); await pause(0.4)
            await move(head())
            if name == "shelf", !legacy {
                if let control = findRow(pet) {
                    click(panel.convertPoint(toScreen: control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)))
                }
                await pause(0.5)
            }
            if name == "notification" { pet.state = .waiting; await pause(0.2) }
            if name == "reopen" {
                click(head()); await pause(reduced ? 0.15 : 0.4); collapseChat(); await pause(0.02)
            }
            let rowVisible = findRow(pet).map { !$0.isHiddenOrHasHiddenAncestor } ?? false
            if CommandLine.arguments.contains("--ui-smoke-chat-search") { slack.model.findOpen = true; await pause(0.05) }
            let prepared = ((name == "empty") == library.entries.isEmpty) && !chatExpanded && (name != "notification" || pet.state == .waiting) && (name != "shelf" || pet.clipboardPresented)
                && (name != "row" || legacy || rowVisible)
            if !prepared { failures.append(name + " preparation") }
            let wasShelf = pet.clipboardPresented
            chat.draft = "T63 INPUT CHECK"; slack.model.draft = "T63 INPUT CHECK"
            let clickPoint = head(); pointer = clickPoint
            let before = panel.frame, started = ProcessInfo.processInfo.systemUptime
            click(clickPoint)
            await pause(reduced ? 0.10 : 0.40)
            // No layoutSubtreeIfNeeded/display/constrain/drag here: inspect what the real event path rendered.
            let surface = pet.chatVisibilityProbe.surface
            let host = pet.chatVisibilityProbe.host!
            let target = placementTarget!.globalBubble
            let surfaceScreen = panel.convertToScreen(pet.convert(surface.frame, to: nil))
            var record: [String: Any] = ["name": name, "prepared": prepared, "beforeShelf": wasShelf, "beforeRow": rowVisible, "historyCount": library.entries.count, "waitSeconds": ProcessInfo.processInfo.systemUptime - started,
                "screen": rect(screen), "anchor": [anchor.x, anchor.y], "panelBefore": rect(before), "panel": rect(panel.frame),
                "surface": rect(surfaceScreen), "surfaceLocal": rect(surface.frame), "target": rect(target),
                "bubbleSize": [bubbleSize.width, bubbleSize.height], "foldedHeight": pet.foldedHeight,
                "motion": String(reflecting: bubbleMotion), "chatExpanded": chatExpanded, "slackConnected": slack.model.connected, "hasSelectedRoom": slack.model.selected != nil, "searchOpen": slack.model.findOpen,
                "hostHidden": host.isHidden, "hostAlpha": host.alphaValue, "hostFrame": rect(host.frame),
                "hostMask": String(describing: host.layer?.mask), "maskBounds": (host.layer?.mask as? CAShapeLayer)?.path.map { rect($0.boundingBoxOfPath) } ?? [], "surfaceAlpha": surface.alphaValue, "surfaceHidden": surface.isHidden,
                "clipboardSurfaceActive": pet.chatVisibilityProbe.clipboardActive,
                "genieActive": pet.genieActive, "perchAwaitingTick": perchAwaitingTick]
            do {
                let imageURL = destination.appendingPathComponent("clipboard-chat-" + name + ".png")
                try await clipboardCaptureWindow(panel, to: imageURL)
                let capturedAt = ProcessInfo.processInfo.systemUptime - started
                record["captureSeconds"] = capturedAt
                let image = NSBitmapImageRep(data: try Data(contentsOf: imageURL))!.cgImage!
                let normalized = CGRect(x: (surfaceScreen.minX - panel.frame.minX) / panel.frame.width,
                    y: (surfaceScreen.minY - panel.frame.minY) / panel.frame.height,
                    width: surfaceScreen.width / panel.frame.width, height: surfaceScreen.height / panel.frame.height)
                let header = CGRect(x: normalized.minX, y: normalized.maxY - 60 / panel.frame.height, width: normalized.width, height: 60 / panel.frame.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let composer = CGRect(x: normalized.minX, y: normalized.minY, width: normalized.width, height: min(normalized.height, 140 / panel.frame.height)).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let titleText = header.isNull ? "" : ocr(image, region: header)
                let inputText = composer.isNull ? "" : ocr(image, region: composer)
                record["titlePixels"] = titleText; record["inputPixels"] = inputText
                let connectText = ocr(image, region: normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
                record["connectionPixels"] = connectText
                // The disconnected UI intentionally offers a connection button, never a composer.
                // This extra regression does not replace the five connected AC-63 composer cases.
                let contentVisible = disconnected ? connectText.replacingOccurrences(of: " ", with: "").contains("슬랙연결") : inputText.replacingOccurrences(of: " ", with: "").contains("T63INPUTCHECK")
                guard let baseline = referenceCases[name], let baselineTarget = baseline["target"] as? [Double], let baselinePanel = baseline["panel"] as? [Double], let baselineFolded = baseline["foldedHeight"] as? Double else { smokeFailed("T-63 reference case missing") }
                let targetDelta = zip(rect(target), baselineTarget).map { abs($0 - $1) }.max() ?? .infinity
                let panelDelta = zip(rect(panel.frame), baselinePanel).map { abs($0 - $1) }.max() ?? .infinity
                let surfaceDelta = zip(rect(surfaceScreen), baselineTarget).map { abs($0 - $1) }.max() ?? .infinity
                record["referenceTargetDelta"] = targetDelta; record["referencePanelDelta"] = panelDelta; record["referenceSurfaceDelta"] = surfaceDelta
                record["referenceSource"] = reference["sourceCommit"]
                let noRow = findRow(pet).map({ $0.isHiddenOrHasHiddenAncestor }) ?? true
                let valid = capturedAt <= (reduced ? 0.3 : 0.6) && prepared && targetDelta <= 1 && panelDelta <= 1 && surfaceDelta <= 1 && abs(Double(pet.foldedHeight) - baselineFolded) <= 1 && (legacy || noRow)
                    && screen.insetBy(dx: -1, dy: -1).contains(target) && panel.frame.insetBy(dx: -1, dy: -1).contains(target)
                    && abs(surfaceScreen.width - target.width) <= 1 && abs(surfaceScreen.height - target.height) <= 1
                    && !titleText.isEmpty && contentVisible
                record["visible"] = valid
                if !valid { failures.append(name) }
                if CommandLine.arguments.contains("--ui-smoke-chat-drag-diagnostic") && !valid {
                    let point = head(); pointer = point; event(.leftMouseDown, point)
                    pointer = CGPoint(x: point.x + 12, y: point.y)
                    event(.leftMouseDragged, pointer); event(.leftMouseUp, pointer)
                    await pause(0.3)
                    let recovery = destination.appendingPathComponent("clipboard-chat-" + name + "-after-drag.png")
                    try await clipboardCaptureWindow(panel, to: recovery)
                    let recovered = NSBitmapImageRep(data: try Data(contentsOf: recovery))!.cgImage!
                    record["afterDragPixels"] = ocr(recovered, region: CGRect(x: 0, y: 0, width: 1, height: 1))
                    record["afterDragGenieActive"] = pet.genieActive
                }
            } catch { record["captureError"] = String(describing: error); failures.append(name) }
            observations.append(record); save()
        }
        if !failures.isEmpty { smokeFailed("T-63 visible chat cases: " + failures.joined(separator: ",")) }
    }
}

/// The SDK explicitly permits current-process content without screen-recording consent.
/// Restrict the filter to this process's selected window; never enumerate or capture other applications.
@MainActor func clipboardCaptureWindow(_ window: NSWindow, backdrop: NSWindow? = nil, to destination: URL) async throws {
    guard #available(macOS 14.4, *) else { throw CocoaError(.featureUnsupported) }
    let content = try await SCShareableContent.currentProcess
    guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else { throw CocoaError(.fileReadNoSuchFile) }
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * window.backingScaleFactor)
    configuration.height = Int(window.frame.height * window.backingScaleFactor)
    configuration.showsCursor = false
    let filter: SCContentFilter
    if let backdrop {
        guard let background = content.windows.first(where: { $0.windowID == CGWindowID(backdrop.windowNumber) && $0.owningApplication?.processID == getpid() }),
              let display = content.displays.first(where: { $0.frame.intersects(own.frame) }) else { throw CocoaError(.fileReadNoSuchFile) }
        // The inclusion list contains only two windows belonging to this process, never other desktop content.
        filter = SCContentFilter(display: display, including: [own, background])
        configuration.sourceRect = own.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    } else { filter = SCContentFilter(desktopIndependentWindow: own) }
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: destination)
}
