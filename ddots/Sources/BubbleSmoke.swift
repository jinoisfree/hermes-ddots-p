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

extension AppDelegate {
    func verifyApprovalBubble(destination: URL) {
        Task { @MainActor [self] in
            isPreview = false; model.tasks = []; model.paused = false
            chat.typing = []; pet.bubbleAlwaysShown = false
            pet.pointerLocation = { NSPoint(x: -5000, y: -5000) }
            collapseChat()
            var snapshot = SlackBridge.Snapshot()
            snapshot.status = .connected
            snapshot.rooms = [SlackRoom(id: "SYNTH", name: "합성 요청")]
            var request = ChatMessage(id: "slack:SYNTH:100.1", fromUser: false, speaker: "진단담당",
                body: "점검 결과를 반영할까요?", date: Date())
            request.hermesReplyState = .asking
            request.hermesButtons = ["반영해", "보류"]
            let thread = SlackThread(id: request.id, room: "SYNTH", ts: "100.1", root: request,
                replies: [], replyCount: 0, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
            var notification = thread
            notification.root.body = "배운 일하는 방법 3건이야"
            notification.root.hermesButtons = []
            notification.root.hermesReplyState = .asking
            notification.root.hermesReplyEvidence = HermesReplyEvidence(statusText: "알림", hasStatus: true, hasControls: false, color: SlackNotice.questionColor)
            snapshot.threads["SYNTH"] = [notification]
            slack.model.source = .slack; slack.model.selected = "SYNTH"
            slack.acceptSnapshot(snapshot)
            updatePet()
            smokeCheck(!slack.model.needsPetApproval && approvalBubbleMessageID == nil && pet.state != .waiting,
                "A red learning notification neither waves the phone nor pins a reply bubble")
            snapshot.threads["SYNTH"] = [thread]
            slack.model.source = .slack; slack.model.selected = "SYNTH"
            slack.acceptSnapshot(snapshot)
            updatePet()
            smokeCheck(pet.state == .waiting && pet.subtitle == request.body, "Phone reason matches the pending request")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            smokeCheck(pet.bubbleShown && !pet.bubbleStowed, "Approval bubble stays visible beyond the alert timer without hover")
            capture(destination: destination.appendingPathComponent("approval-held"))
            pet.onClick?(1)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            smokeCheck(chatExpanded && slack.model.focusThread == thread.id && slack.model.open.contains(thread.id), "Click opens the pending request thread")
            collapseChat()
            request.hermesReplyState = .working
            snapshot.threads["SYNTH"]![0].root = request
            slack.acceptSnapshot(snapshot)
            updatePet()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            smokeCheck(!slack.model.needsPetApproval && approvalBubbleMessageID == nil, "Answered request clears phone target")
            smokeCheck(!pet.bubbleShown, "Answered request releases the persistent bubble")
            try? "PASS: reason, persistent bubble, thread click, answered cleanup\n".write(to: destination.appendingPathComponent("approval-checks.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
