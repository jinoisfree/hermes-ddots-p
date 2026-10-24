import AppKit
import SwiftUI

extension AppDelegate {
    func verifyRelayPortraits(destination: URL) {
        Task { @MainActor [self] in
            let result = await Task.detached(priority: .utility) {
                let home = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-portrait-smoke-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: home) }
                let file = home.appendingPathComponent("portraits.json")
                let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(red: 0.1, green: 0.7, blue: 0.55, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
                var avatar = ProfileAvatar(); avatar.thumbnail = context.makeImage()
                var frame = RelayFrame(op: "state")
                frame.characters = [RelayFrame.Character(id: "kept-cow", name: "SNS담당")]
                frame.avatars = ["kept-cow": RelayFrame.Avatar(avatar)]
                RelayPortraits(url: file).receive(frame, fromRelay: true)
                let source = HermesBridge(home: home.appendingPathComponent("empty")).poll(unreadSince: nil)
                precondition(source.avatars.isEmpty && source.characters.isEmpty)
                return RelayPortraits(url: file).merging(source)
            }.value
            applyChat(nil, portraits: result)
            let profile = SlackSpeakers.profile("SNS담당", characters: slack.characters)
            smokeCheck(profile == "kept-cow" && chat.avatars[profile]?.image != nil, "Cached characters resolve the Slack sender to a cached picture")
            smokeCheck(storedMessages.isEmpty && chat.typing.isEmpty, "Portrait recovery does not recover conversations or typing")
            let room = SlackRoom(id: "CPORTRAITS", name: "보관 사진 검사", direct: false)
            let message = ChatMessage(id: "kept-picture", fromUser: false, speaker: "SNS담당", body: "연결 없이 보관한 합성 사진을 표시합니다.", date: Date(), profile: profile)
            slack.model.onSend = nil; slack.model.onOpen = { _ in }
            slack.model.rooms = [room]; slack.model.selected = room.id; slack.model.source = .slack
            slack.model.threads = [SlackThread(id: "kept-thread", room: room.id, ts: "1.0", root: message, replies: [], replyCount: 0, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)]
            try? await Task.sleep(nanoseconds: 700_000_000)
            capture(destination: destination.appendingPathComponent("cached-sender"))
            try? "PASS: no local profiles or relay connection; saved character name resolves a saved PNG; no chat restored\n".write(to: destination.appendingPathComponent("portraits.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
