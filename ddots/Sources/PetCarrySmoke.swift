import AppKit

extension AppDelegate {
    /// The pet at the top of the screen, carried with the conversation open under it: the bottom edge stays and the
    /// height follows the pet, down shorter at once, and held past the top, taller downward.
    func verifyPetCarry(destination: URL) {
        Task { @MainActor [self] in
            var report = ""
            func check(_ condition: Bool, _ message: String) {
                report += (condition ? "PASS: " : "FAIL: ") + message + "\n"
                if !condition {
                    try? report.write(to: destination.appendingPathComponent("pet-carry.txt"), atomically: true, encoding: .utf8)
                    smokeFailed(message)
                }
            }
            func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            func mouse(_ type: NSEvent.EventType, _ global: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: global), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            showChat(); await settle(1)
            guard chatExpanded, let screen = panel.screen else { smokeFailed("Pet carry needs an open conversation") }
            let room = PetLayout.maximumHeader(visibleFrame: screen.visibleFrame, screenFrame: screen.frame) - screen.visibleFrame.minY - 12
            preferredChatSize.height = room - 100
            resizedBelow = true
            placePet(at: PetLayout.sprite(foot: CGPoint(x: screen.visibleFrame.midX, y: screen.frame.maxY + 500), scale: pet.petScale).origin)
            await settle()
            guard let start = placementTarget, start.bubbleBelow else { smokeFailed("The conversation opens under the pet at the top") }
            let bottom = start.globalBubble.minY, height = start.globalBubble.height
            check(bottom > screen.visibleFrame.minY + 50, "At the top the conversation stops short of the screen's bottom: \(bottom)")
            // Somewhere the pet is really drawn, so the press picks the pet up and not the conversation.
            let sprite = pet.spriteRect
            let local = stride(from: sprite.maxY - 4, to: sprite.minY, by: -2).lazy.flatMap { y in
                stride(from: sprite.minX + 2, to: sprite.maxX, by: 2).lazy.map { CGPoint(x: $0, y: y) }
            }.first { pet.spriteContains($0) && !pet.placement!.bubbleRect.contains($0) }
            guard let local else { smokeFailed("The pet has a place to hold") }
            let grip = panel.convertPoint(toScreen: pet.convert(local, to: nil))
            var pointer = grip
            pet.pointerLocation = { pointer }
            defer { pet.pointerLocation = { NSEvent.mouseLocation } }
            pet.mouseDown(with: mouse(.leftMouseDown, grip))
            pointer = CGPoint(x: grip.x, y: grip.y - 40)
            pet.mouseDragged(with: mouse(.leftMouseDragged, pointer))
            let down = placementTarget!.globalBubble
            check(abs(down.minY - bottom) < 1 && abs(down.height - (height - 40)) < 1,
                  "Carried down 40 from the top, the bottom stays and it is 40 shorter: \(down) from \(start.globalBubble)")
            pointer = CGPoint(x: grip.x, y: grip.y + 40)
            pet.mouseDragged(with: mouse(.leftMouseDragged, pointer))
            let up = placementTarget!.globalBubble
            check(abs(up.minY - (bottom - 40)) < 1 && abs(up.height - (height + 40)) < 1,
                  "Held 40 past the top, it grows 40 downward: \(up) from \(start.globalBubble)")
            pet.mouseUp(with: mouse(.leftMouseUp, pointer))
            await settle()
            check(petDragBottom == nil && abs(layoutChatSize.height - (height + 40)) < 1, "Set down, the new height is kept: \(layoutChatSize.height)")
            try? report.write(to: destination.appendingPathComponent("pet-carry.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
