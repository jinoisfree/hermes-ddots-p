import AppKit

extension AppDelegate {
    /// The folded bubble is put away from the start, the count moves beside the pet, and an alert brings the bubble back.
    func verifyBubbleReveal(destination: URL) {
        pet.unreadCount = 3
        // Where the pointer is said to be, so the checks do not go by where the user's happens to rest.
        let real = pet.pointerLocation, away = NSPoint(x: -5000, y: -5000)
        pet.pointerLocation = { away }
        DispatchQueue.main.asyncAfter(deadline: .now() + BubbleReveal.alertStay + 0.6) { [self] in
            let bubble = pet.placement!.bubbleRect
            smokeCheck(!pet.bubbleShown, "The bubble is put away with nothing to show it for ")
            smokeCheck(pet.bubbleStowed, "Faded out, the bubble is off the screen altogether")
            smokeCheck(pet.petBadgeVisible && pet.spriteRect.contains(pet.petBadgeRect), "The count of unread answers sits beside the pet, inside its own square: \(pet.petBadgeRect) in \(pet.spriteRect)")
            smokeCheck(pet.hitTest(CGPoint(x: bubble.midX, y: bubble.midY)) == nil || bubble.intersects(pet.spriteRect.insetBy(dx: -12, dy: -12)), "A bubble that is put away takes no clicks")
            pet.revealBubble()
            smokeCheck(pet.bubbleShown && !pet.petBadgeVisible, "An alert brings the bubble out, and the count goes back into it")
            // The glass does not go by what a drawing into a picture sees, so this is looked at on the screen itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in showChat() }
            func onScreen(_ rect: CGRect) -> NSPoint { let there = panel.convertToScreen(pet.convert(rect, to: nil)); return NSPoint(x: there.midX, y: there.midY) }
            func head() -> NSPoint { onScreen(pet.atlas.interactionRect(in: pet.spriteRect)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                smokeCheck(chatExpanded && pet.bubbleShown && !pet.bubbleStowed, "The open conversation is drawn on the bubble's glass")
                // Folded by pressing the pet: the pointer is left resting on it.
                pet.pointerLocation = { head() }
                collapseChat()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
                smokeCheck(!chatExpanded && !pet.bubbleShown && pet.bubbleStowed, "Folded, the conversation leaves no bubble behind though the pointer rests on the pet")
                pet.pointerLocation = { away }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) { [self] in
                smokeCheck(!pet.bubbleShown, "With the pointer away it stays put away")
                pet.pointerLocation = { head() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [self] in
                smokeCheck(pet.bubbleShown, "Coming back onto the pet brings the bubble out")
                let bubble = onScreen(pet.placement!.bubbleRect)
                pet.pointerLocation = { bubble }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) { [self] in
                smokeCheck(pet.bubbleShown, "The pointer can cross over to the bubble it brought out")
                pet.pointerLocation = { away }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                smokeCheck(!pet.bubbleShown && pet.bubbleStowed, "It goes when the pointer leaves")
                let bubble = onScreen(pet.placement!.bubbleRect)
                pet.pointerLocation = { bubble }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.3) { [self] in
                smokeCheck(!pet.bubbleShown, "Where the bubble would be does not bring it out; only the pet does")
                pet.pointerLocation = real
                pet.bubbleAlwaysShown = true; pet.unreadCount = 0
                smokeCheck(pet.bubbleShown && !pet.petBadgeVisible, "With the bubble kept out, nothing is put away")
                NSApp.terminate(nil)
            }
        }
    }
}
