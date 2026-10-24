import AppKit

extension AppDelegate {
    func capturePerch(destination: URL) {
        capture(destination:destination)
    }
    func verifyPerch(destination: URL) {
        if CommandLine.arguments.contains("--ui-smoke-sprite") { verifySpriteMotion(destination: destination); return }
        Task { @MainActor [self] in
            guard let screen = panel.screen else { smokeFailed("Perch needs a screen") }
            pet.previewRow = 0
            let visible = screen.visibleFrame
            let storedScale = UserDefaults.standard.object(forKey:"petScale") as? Double
            var report = ""
            func settle() async { try? await Task.sleep(nanoseconds:850_000_000) }
            func check(_ value: Bool, _ message: String) {
                smokeCheck(value,message)
                report += "PASS: \(message)\n"
            }
            func foot(_ placement: PetPlacement) -> CGRect { PetLayout.visibleSprite(in:placement.globalSprite) }
            func place(scale: CGFloat, y: CGFloat, below: Bool) {
                pet.petScale = scale
                resizedBelow = below
                let cell = PetLayout.sprite(foot:CGPoint(x:visible.midX,y:y),scale:scale)
                placePet(at:cell.origin)
            }
            let restingY = min(visible.maxY-290,visible.minY+650)
            place(scale:1,y:restingY,below:true)
            await settle()
            func liveContent() -> Bool {
                guard let host = pet.subviews.compactMap({ $0 as? GenieChatHost }).first else { return false }
                guard !host.isHidden, host.alphaValue > 0, host.bounds.width > 0, !pet.genieActive,
                      let layer = host.layer,
                      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
                layer.render(in: context.cgContext)
                // Inspect actual content pixels, not only the visibility flags.
                return stride(from: 10, to: bitmap.pixelsHigh, by: 20).contains { y in
                    stride(from: 10, to: bitmap.pixelsWide, by: 20).contains { x in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                    }
                }
            }
            if CommandLine.arguments.contains("--ui-smoke-reduce-motion") {
                NSApp.activate(ignoringOtherApps: true); await settle()
                collapseChat(); await settle()
                check(!chatExpanded && !pet.genieActive, "Reduced motion closes without a picture")
                showChat(); await settle()
                check(pet.genieCaptures == 0 && !pet.canReuseGenie(size: pet.chatSize), "Reduced motion never captures or reuses a Genie picture")
                check(!pet.genieHasBlurredImage && !pet.chatHasBlurFilter, "Reduced motion has no blurred picture or live filter")
                check(liveContent(), "Reduced motion shows live conversation content")
                let editor = panel.firstResponder as? NSTextView
                check(chat.composerFocused && editor?.isEditable == true && editor?.window === panel,
                      "Reduced motion restores the focused input editor in its panel")
                try? "key=\(panel.isKeyWindow), focused=\(chat.composerFocused), editable=\(editor?.isEditable == true)\n".write(to: destination.appendingPathComponent("input-focus.txt"), atomically: true, encoding: .utf8)
                capturePerch(destination: destination.appendingPathComponent("reduced-open"))
                collapseChat(); await settle()
                check(!chatExpanded && pet.genieCaptures == 0, "Reduced motion closes with zero captures")
                try? report.write(to: destination.appendingPathComponent("perch.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil); return
            }
            let trace = MotionTrace()
            collapseChat(); await settle()
            let beforeReopen = pet.genieCaptures
            motionTrace = trace; trace.begin("open"); showChat(); await settle()
            check((lastGenieTrace?.spriteShiftMax ?? .infinity) <= 1, "Opening keeps the presented pet fixed in screen coordinates")
            check(pet.genieCaptures > beforeReopen && lastGenieTrace?.path == "captured", "Opening captures the new entry instead of the old reading position")
            motionTrace = nil; trace.end()
            lastGenieTrace?.finish(settleMS: lastGenieTrace?.settleMS ?? 0, destination: destination.appendingPathComponent("motion-log.txt"))
            check(trace.lastLayouts == 0 && trace.lastFilters == 0, "Genie opening does not reflow or filter live content")
            motionTrace = trace; trace.begin("close"); collapseChat(); await settle()
            motionTrace = nil; trace.end()
            lastGenieTrace?.finish(settleMS: lastGenieTrace?.settleMS ?? 0, destination: destination.appendingPathComponent("motion-log.txt"))
            check(trace.lastLayouts == 0 && trace.lastFilters == 0, "Genie closing does not reflow or filter live content")
            check((lastGenieTrace?.spriteShiftMax ?? .infinity) <= 1, "Closing keeps the presented pet fixed in screen coordinates")
            GenieTrace.writer.sync {}
            trace.write(to: destination.appendingPathComponent("genie.tsv"))
            if CommandLine.arguments.contains("--ui-smoke-motion-only") { NSApp.terminate(nil); return }
            // Delay entry readiness across display ticks, rather than assuming the click's first layout is enough.
            if let host = pet.subviews.compactMap({ $0 as? GenieChatHost }).first {
                let prepare = host.prepareEntryViewport
                var ready = false
                host.prepareEntryViewport = { let laidOut = prepare?() ?? true; return ready && laidOut }
                showChat()
                try? await Task.sleep(nanoseconds: 80_000_000)
                check(pet.openingEntryPending && perchTransition?.start == .infinity,
                      "Opening waits for the entry layout before displaying its picture")
                // A close cancels a pending opening; a subsequent open gets its own readiness check.
                collapseChat(); await settle(); showChat()
                try? await Task.sleep(nanoseconds: 80_000_000)
                check(pet.openingEntryPending && perchTransition?.start == .infinity,
                      "Reopening after cancellation still waits for the current entry")
                ready = true
                await settle()
                host.prepareEntryViewport = prepare
                check(!pet.openingEntryPending && perchTransition == nil && liveContent(),
                      "A delayed entry starts its display clock and finishes with live content")
                collapseChat(); await settle()
            }
            let savedDisplayTick = pet.onDisplayTick
            pet.onDisplayTick = nil
            showChat(); await settle()
            check(perchTransition == nil && liveContent(), "Timer fallback finishes opening without display ticks")
            collapseChat(); await settle()
            check(perchTransition == nil && !chatExpanded && !pet.genieActive, "Timer fallback finishes closing without display ticks")
            var idleTicks = 0
            pet.onDisplayTick = { idleTicks += 1; savedDisplayTick?() }
            await settle()
            check(idleTicks == 0, "The completed transition has no idle display callbacks")
            pet.onDisplayTick = savedDisplayTick
            pet.resting = true
            showChat()
            check(perchTransition == nil && liveContent(), "Resting display opens immediately")
            collapseChat()
            check(perchTransition == nil && !chatExpanded && !pet.genieActive, "Resting display closes immediately")
            pet.resting = false
            showChat(); await settle()
            let preferredBeforeDrag = preferredChatSize
            pet.onDragMove?(CGPoint(x: placementTarget!.anchorOrigin.x, y: visible.minY-500))
            await settle()
            let lowDrag = placementTarget!
            check(lowDrag.bubbleBelow && lowDrag.globalBubble.height == PetLayout.minimumChatSize.height, "Dragging the open pet to the bottom keeps it perched at minimum height")
            check(abs(foot(lowDrag).minY-(lowDrag.globalBubble.maxY-PetLayout.perchOverlap)) < 0.001, "The dragged pet keeps its overlap with the top bar")
            check(lowDrag.globalBubble.minY >= visible.minY+12 && preferredChatSize == preferredBeforeDrag, "Bottom drag keeps the window on screen without overwriting preferred height")
            capturePerch(destination: destination.appendingPathComponent("bottom-pet-drag"))
            pet.onDragMove?(PetLayout.sprite(foot:CGPoint(x:visible.midX,y:restingY),scale:1).origin)
            await settle()
            check(placementTarget!.globalBubble.height == preferredBeforeDrag.height, "Raising the pet restores the preferred conversation height")
            for scale in [CGFloat(1),0.25,2] {
                applyPetSize(Double(scale*100))
                await settle()
                let p = placementTarget!
                check(!pet.thoughtDotsVisible,"Perched conversation has no thought dots")
                check(abs(foot(p).minY-restingY)<0.001,"Size control keeps the visible foot fixed")
                check(abs(foot(p).minY-(p.globalBubble.maxY-PetLayout.perchOverlap))<0.001,"Foot overlaps the 40pt header by 20pt at scale \(scale)")
                check(abs(foot(p).midX-p.globalBubble.midX)<0.001,"Visible artwork and conversation share their centre")
                capturePerch(destination:destination.appendingPathComponent("perch-\(Int(scale*100))"))
            }
            place(scale:1,y:restingY,below:true)
            await settle()
            let start = placementTarget!, pointer = CGPoint(x:start.globalBubble.midX,y:start.globalBubble.maxY-30)
            beginChatDrag(at:pointer)
            moveChatDrag(to:CGPoint(x:pointer.x,y:pointer.y+9999))
            endChatDrag()
            await settle()
            let high = placementTarget!
            check(abs(high.globalBubble.maxY-PetLayout.maximumHeader(visibleFrame:visible,screenFrame:screen.frame))<0.001,"Header reaches the menu bar")
            check(abs(high.effectiveScale-PetLayout.perchScale(userScale:1,header:high.globalBubble.maxY,screenFrame:screen.frame))<0.001,"Automatic scale follows the available height")
            check(pet.petScale==1,"Automatic scale leaves the user's scale unchanged")
            check((UserDefaults.standard.object(forKey:"petScale") as? Double)==storedScale,"Automatic scale does not write preferences")
            check(smokePosition["petAnchorY"]==Double(high.anchorOrigin.y),"Saved cell origin uses the user's scale")
            capturePerch(destination:destination.appendingPathComponent("menu-bar"))
            report += "window level: \(panel.level.rawValue), effective scale: \(high.effectiveScale)\n"
            var saved = smokePosition; saved["petScale"] = 100
            collapseChat(); await settle()
            restorePosition(from:saved)
            showChat(); await settle()
            check(abs(placementTarget!.globalBubble.maxY-high.globalBubble.maxY)<0.001,"Saved position restores the shrunken perch after folding")
            check(abs(placementTarget!.effectiveScale-high.effectiveScale)<0.001,"Reopening preserves automatic scale without changing preference")
            beginChatDrag(at:CGPoint(x:high.globalBubble.midX,y:high.globalBubble.maxY-30))
            moveChatDrag(to:CGPoint(x:high.globalBubble.midX,y:high.globalBubble.maxY-380))
            endChatDrag()
            await settle()
            check(abs(placementTarget!.effectiveScale-1)<0.001,"Lowering the header restores the user's scale")
            place(scale:1,y:restingY,below:true)
            await settle()
            let p = placementTarget!
            // Test the overlap in window coordinates, including transparent pixels next to the feet.
            var petHits = 0, headerHits = 0
            let overlap = pet.spriteRect.intersection(pet.placement!.bubbleRect)
            for y in stride(from:overlap.minY+1,to:overlap.maxY,by:2) {
                for x in stride(from:overlap.minX+1,to:overlap.maxX,by:2) {
                    let point = CGPoint(x:x,y:y)
                    let hit = pet.hitTest(pet.convert(point,to:pet.superview))
                    if pet.spriteContains(point) {
                        check(hit === pet,"An opaque sprite pixel receives the click")
                        petHits += 1
                    } else if PetLayout.resizeEdge(at:point,bubble:pet.placement!.bubbleRect,below:true).isEmpty {
                        check(hit !== pet,"A transparent sprite pixel leaves the header interactive")
                        headerHits += 1
                    }
                }
            }
            check(petHits>0 && headerHits>0,"Overlap exercises both pet and header hit targets")
            let tick = pet.onAnimationTick, displayTick = pet.onDisplayTick
            pet.onAnimationTick = nil; pet.onDisplayTick = nil
            for opening in [true,false] {
                // Sample the same timed transition deterministically; capture does not record the system menu bar.
                if opening { collapseChat(); showChat() } else { collapseChat() }
                try? await Task.sleep(nanoseconds: 100_000_000)
                for (index, fraction) in [0.18,0.45,0.75].enumerated() {
                    genieStartProgress = opening ? 0 : 1
                    perchAwaitingTick = false
                    perchTransition = (ProcessInfo.processInfo.systemUptime-fraction*ChatMorph.genieDuration,opening,p)
                    advancePlacement()
                    capturePerch(destination:destination.appendingPathComponent("\(opening ? "opening" : "closing")-\(index+1)"))
                    check(!pet.thoughtDotsVisible,"Perch opening and folding have no thought dots")
                    if let layer = pet.layer, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pet.bounds.width), pixelsHigh: Int(pet.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                       let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                        layer.render(in: context.cgContext)
                        let r = p.globalBubble.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
                        let foot = PetLayout.visibleSprite(in: p.globalSprite)
                        let aim = CGPoint(x: min(r.maxX, max(r.minX, foot.midX-panel.frame.minX)), y: p.bubbleBelow ? r.maxY : r.minY)
                        let strip = ChatMorph.genieStrip(r, target: aim, lower: 0.5, upper: 0.51, progress: pet.genieProgress, below: p.bubbleBelow)
                        let color = bitmap.colorAt(x: Int(strip.midX), y: Int(pet.bounds.height-strip.midY))
                        check((color?.alphaComponent ?? 0) > 0.9, "Genie picture pixels are drawn above the hidden live content")
                    } else { check(false, "Genie layer can be rendered") }
                    check(pet.genieHasBlurredImage && pet.genieBlur > 0 && pet.genieBlur < 1, "Genie blends a prepared blurred image")
                    let rect = pet.placement!.globalBubble
                    check(abs(rect.maxY-p.globalBubble.maxY)<0.001,"Transition keeps the perch fixed")
                    check(visible.contains(rect),"Transition stays on screen")
                }
                perchTransition = nil
                advancePlacement()
            }
            pet.onAnimationTick = tick; pet.onDisplayTick = displayTick
            showChat()
            place(scale:1,y:visible.minY+40,below:false)
            await settle()
            check(!placementTarget!.bubbleBelow,"Low anchor opens upward")
            capturePerch(destination:destination.appendingPathComponent("above"))
            check(pet.thoughtDotsVisible,"Upward conversation retains thought dots")
            collapseChat(); await settle()
            check(pet.thoughtDotsVisible,"Folded bubble retains thought dots")
            var times: [TimeInterval] = []
            let normalTick = pet.onAnimationTick
            pet.onAnimationTick = { [self] in
                if perchTransition != nil { times.append(ProcessInfo.processInfo.systemUptime) }
                normalTick?()
            }
            showChat(); await settle()
            let gaps = zip(times.dropFirst(),times).map { $0-$1 }
            report += "Genie duration: \(ChatMorph.genieDuration)s, frames: \(times.count), max interval ms: \((gaps.max() ?? 0)*1000), strips: \(pet.genieStripCount)\n"
            pet.onAnimationTick = normalTick
            check(!pet.genieActive && pet.chatShown,"Animation restores the live conversation")
            let header = CGPoint(x:pet.placement!.bubbleRect.minX+30,y:pet.placement!.bubbleRect.maxY-30)
            check(pet.hitTest(pet.convert(header,to:pet.superview)) != nil,"Live header is clickable after Genie")
            if !ChatView.reducesMotionForChecks {
                collapseChat(); try? await Task.sleep(nanoseconds: 100_000_000)
                let before = pet.genieProgress
                showChat()
                check(abs(pet.genieProgress-before) < 0.03, "Genie reverses from its current shape")
                await settle()
            }
            for _ in 0..<4 { collapseChat(); showChat() }
            await settle()
            check(!pet.genieActive && pet.chatShown,"Rapid toggles leave no snapshot or hidden conversation")
            collapseChat(); await settle()
            check(!pet.genieActive && !pet.chatShown,"Folding removes snapshot and live conversation")
            try? report.write(to:destination.appendingPathComponent("perch-checks.txt"),atomically:true,encoding:.utf8)
            NSApp.terminate(nil)
        }
    }
}
