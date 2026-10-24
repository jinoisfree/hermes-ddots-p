import AppKit

extension AppDelegate {
    @MainActor func verifyConnectOffer(destination: URL) {
        let suite = "ddots-offer-smoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        connectOffer = ConnectOffer(defaults: defaults)
        connectOfferSmokeInput = ConnectOffer.Input(hermesDecided: false, relayConfigured: false, localHermesFound: true,
            slackConnected: false, slackAppInstalled: true, isSmoke: false)
        updatePet()
        smokeCheck(currentConnectOffer == .slack && bubbleAlert == "offer:slack", "Slack is offered first")
        smokeCheck(pet.headline == "슬랙을 연결할까요?" && pet.subtitle == "안내대로 토큰만 복사하면 돼요", "Slack offer explains setup")
        smokeCheck(pet.actions == ["토큰 넣기", "괜찮아요"] && bubbleActions.map(\.kind) == [.connectSlack, .declineOffer], "Slack offers token entry and refusal")
        capture(destination: destination.appendingPathComponent("slack-offer"))
        connectOffer.resolve(.slack)
        connectOfferSmokeInput?.slackConnected = true
        updatePet()
        smokeCheck(currentConnectOffer == .hermes && bubbleAlert == "offer:hermes", "Synthetic discovery raises the Hermes offer")
        smokeCheck(pet.headline == "Hermes를 찾았어요" && pet.subtitle == "슬랙에 캐릭터 이름·사진을 붙일까요?", "Hermes offers character metadata after Slack connects")
        smokeCheck(pet.actions == ["연결", "괜찮아요"], "Connection offer has connect and decline buttons")
        smokeCheck(bubbleActions.map(\.kind) == [.connectHermes, .declineOffer], "Connection offer buttons target their own actions")
        capture(destination: destination.appendingPathComponent("hermes-offer"))
        showChat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            smokeCheck(slack.model.source == .slack && !slack.connected && chat.scrollView == nil && !chat.canSend, "An unconnected chat shows Slack setup without an iMessage switch")
            capture(destination: destination.appendingPathComponent("slack-unconnected"))
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let copied = "xoxp-" + String(repeating: "a", count: 30)
            board.setString(copied, forType: .string)
            let dialog = SlackConnectDialog(connected: false, clipboard: board)
            dialog.fillCopiedToken()
            smokeCheck(dialog.field.stringValue == copied && dialog.status.stringValue.contains("복사한 토큰을 넣었어요"), "An existing copied user token fills the secure field")
            dialog.field.stringValue = "직접 입력 중"; dialog.fillCopiedToken()
            smokeCheck(dialog.field.stringValue == "직접 입력 중", "An unchanged clipboard leaves manual typing alone")
            board.clearContents(); board.setString("invalid", forType: .string); dialog.fillCopiedToken()
            smokeCheck(dialog.field.stringValue == "직접 입력 중", "Unrelated copied text cannot replace the token")
            smokeCheck(Bundle.main.url(forResource: "slack-app-manifest", withExtension: "json") != nil, "The Slack manifest is bundled")
            try? "PASS: synthetic Slack offer then Hermes character offer, expected buttons, Slack-only unconnected chat and secure clipboard fill; no modal, connection or messages\n"
                .write(to: destination.appendingPathComponent("connect-offer.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
