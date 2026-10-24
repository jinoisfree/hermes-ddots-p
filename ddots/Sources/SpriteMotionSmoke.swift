import AppKit
import WebKit

extension AppDelegate {
    /// Shared harness for the old and new transition implementations. Sampling does not force layout/flush.
    func verifySpriteMotion(destination: URL) {
        Task { @MainActor [self] in
            guard let screen = panel.screen else { smokeFailed("Sprite probe needs a screen") }
            let area = screen.visibleFrame
            pet.previewRow = 0
            let withWeb = CommandLine.arguments.contains("--ui-smoke-sprite-web")
            if withWeb {
                let page = destination.appendingPathComponent("synthetic.html")
                try! "<html><title>Synthetic</title><body>Local synthetic page</body></html>".write(to: page, atomically: true, encoding: .utf8)
                web.open(page)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            var rows: [[String: Any]] = []
            var cases: [[String: Any]] = []
            var label = "", direction = "", initial = CGRect.zero
            func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
            func shift(_ a: CGRect, _ b: CGRect) -> Double {
                max(hypot(a.minX-b.minX, a.minY-b.minY), hypot(a.maxX-b.maxX, a.maxY-b.maxY))
            }
            func sample(_ phase: String) {
                guard !label.isEmpty else { return }
                let actual = pet.spriteDrawnScreenRect
                rows.append(["case": label, "direction": direction, "phase": phase,
                    "time": ProcessInfo.processInfo.systemUptime, "panel": rect(panel.frame),
                    "sprite": rect(panel.convertToScreen(pet.convert(pet.spriteRect, to: nil))),
                    "global": rect(pet.placement?.globalSprite ?? .zero),
                    "layer": rect(pet.spriteLayerFrame), "presentation": rect(pet.spritePresentationFrame),
                    "drawn": rect(actual), "foot": rect(PetLayout.visibleSprite(in: actual)),
                    "below": pet.placement?.bubbleBelow ?? false, "perched": pet.perched, "scale": pet.placement?.effectiveScale ?? 0,
                    "backing": panel.backingScaleFactor, "shift": shift(actual, initial),
                    "placement_shift": shift(actual, pet.placement?.globalSprite ?? .zero)])
            }
            spriteProbe = sample
            let timer = Timer(timeInterval: 1.0/120, repeats: true) { _ in sample("observer") }
            RunLoop.main.add(timer, forMode: .common)
            let top = CommandLine.arguments.contains("--ui-smoke-sprite-top")
            if !top {
            for scale in [CGFloat(0.59), 1] {
                for below in [true, false] {
                    for edge in [false, true] {
                        collapseChat(); try? await Task.sleep(nanoseconds: 600_000_000)
                        pet.petScale = scale; resizedBelow = below; foldedPerchAnchor = nil
                        let foot = CGPoint(x: edge ? area.maxX-20 : area.midX,
                                           y: edge ? area.minY+45 : area.midY+100)
                        placePet(at: PetLayout.sprite(foot: foot, scale: scale).origin)
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        for reuse in [false, true] {
                            if !reuse { pet.invalidateGeniePicture() }
                            for opening in [true, false] {
                                direction = opening ? "open" : "close"
                                label = "\(Int(scale*100))-\(below ? "below" : "above")-\(edge ? "edge" : "center")-\(reuse ? "reuse" : "fresh")"
                                if opening { resizedBelow = below }
                                initial = pet.spriteDrawnScreenRect
                                let start = rows.count
                                let captures = pet.genieCaptures
                                sample("input.before")
                                if reuse { spriteSmokeTap(opening: opening) }
                                else { pet.onClick?(1) }
                                sample("input.after")
                                try? await Task.sleep(nanoseconds: 850_000_000)
                                sample("settled")
                                let selected = rows[start...].filter { ($0["phase"] as? String) == "observer" }
                                cases.append(["case":label,"direction":direction,"max_shift":selected.map { $0["shift"] as! Double }.max() ?? 0,
                                              "end_shift":shift(pet.spriteDrawnScreenRect,initial), "captures":pet.genieCaptures-captures, "web":withWeb,"samples":selected.count,
                                              "max_placement_shift":selected.map { $0["placement_shift"] as! Double }.max() ?? 0])
                                label = ""
                            }
                        }
                    }
                }
            }
            }
            if top {
                for scale in [CGFloat(0.59), 1] {
                    collapseChat(); try? await Task.sleep(nanoseconds: 850_000_000)
                    pet.petScale = scale; resizedBelow = true; foldedPerchAnchor = nil
                    placePet(at: PetLayout.sprite(foot: CGPoint(x: area.midX, y: area.midY+100), scale: scale).origin)
                    showChat(); try? await Task.sleep(nanoseconds: 850_000_000)
                    let p = placementTarget!, pointer = CGPoint(x: p.globalBubble.midX, y: p.globalBubble.maxY-30)
                    beginChatDrag(at: pointer); moveChatDrag(to: CGPoint(x: pointer.x, y: pointer.y+9999)); endChatDrag()
                    try? await Task.sleep(nanoseconds: 850_000_000)
                    smokeCheck(placementTarget!.effectiveScale < scale, "Top fixture automatically shrinks the pet")
                    for opening in [false, true] {
                        direction = opening ? "open" : "close"; label = "top-\(Int(scale*100))"
                        initial = pet.spriteDrawnScreenRect; let start = rows.count
                        sample("input.before"); spriteSmokeTap(opening: opening); sample("input.after")
                        try? await Task.sleep(nanoseconds: 850_000_000)
                        sample("settled")
                        if !opening { smokeCheck(foldedPerchAnchor != nil, "Shrunken close retains its perch anchor") }
                        let selected = rows[start...].filter { ($0["phase"] as? String) == "observer" }
                        cases.append(["case":label,"direction":direction,
                            "max_shift":selected.map { $0["shift"] as! Double }.max() ?? 0,
                            "end_shift":shift(pet.spriteDrawnScreenRect,initial),"samples":selected.count])
                        label = ""
                    }
                }
            }
            timer.invalidate(); spriteProbe = nil
            for (name, value) in [("sprite-frames.json", rows), ("sprite-cases.json", cases)] {
                let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                try! data.write(to: destination.appendingPathComponent(name))
            }
            let regression = cases.filter { ($0["case"] as! String).contains("below-center-reuse") }
            // A tall pane reaches the screen top, where the pet deliberately shrinks; folding restores its own scale.
            let metric = withWeb ? "max_placement_shift" : "max_shift"
            smokeCheck(top || (!regression.isEmpty && regression.allSatisfy { ($0[metric] as! Double) <= 1 }),
                       withWeb ? "Every sampled frame follows the tall pane's intended pet placement without a rendering jump"
                               : "Every sampled frame of reused opening and closing keeps the pet fixed")
            NSApp.terminate(nil)
        }
    }
    @MainActor func spriteSmokeTap(opening: Bool) {
        smokeCheck(chatExpanded != opening, "Synthetic tap starts in the opposite chat state")
        var frames = ThreeTapFrames()
        let contacts = (0..<3).map { ThreeTapContact(id: $0, state: 4, x: 0.2+Double($0)*0.1, y: 0.5) }
        smokeCheck(frames.receive(contacts, count: 3, at: 0) == .valid(tapped: false), "Synthetic three-finger landing")
        smokeCheck(frames.receive([], count: 0, at: 0.1) == .valid(tapped: true), "Synthetic three-finger release recognizes a tap")
        threeTap.receive(.ready)
        threeTap.tapped()
    }
}
