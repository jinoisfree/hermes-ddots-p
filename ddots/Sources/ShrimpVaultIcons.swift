import AppKit
import SwiftUI

enum ShrimpVaultIcons {
    static let symbols = ["경로 줘": "folder", "파일오픈": "arrow.up.forward.square", "다운로드": "arrow.down.circle",
                          "표": "tablecells", "수정": "pencil", "종결": "checkmark"]
    static func name(_ action: String) -> String { action == "경로 줘" ? "파일경로" : action }
    @ViewBuilder static func label(_ action: String, disabled: Bool) -> some View {
        if let symbol = symbols[action] {
            Image(systemName: symbol).accessibilityHidden(true)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(disabled ? .secondary : .white)
                .frame(width: 28, height: 24)
                .background(Capsule().fill(disabled ? Color.primary.opacity(0.10) : Color.accentColor))
        } else {
            Text(name(action)).font(.system(size: 11, weight: .semibold)).fixedSize()
                .foregroundColor(disabled ? .secondary : .white)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(Capsule().fill(disabled ? Color.primary.opacity(0.10) : Color.accentColor))
        }
    }
}

extension AppDelegate {
    func verifyVaultIcons(destination: URL) {
        Task { @MainActor [self] in
            for symbol in ShrimpVaultIcons.symbols.values {
                smokeCheck(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "Available SF Symbol: " + symbol)
            }
            let names = ["경로 줘": "파일경로", "파일오픈": "파일오픈", "다운로드": "다운로드",
                         "표": "표", "수정": "수정", "종결": "종결"]
            for (action, name) in names {
                smokeCheck(ShrimpVaultIcons.symbols[action] != nil, "Action has an icon: " + action)
                smokeCheck(ShrimpVaultIcons.name(action) == name, "Korean button label: " + name)
            }
            smokeCheck(ShrimpVaultIcons.symbols["종결"] == "checkmark", "Finish uses checkmark")
            smokeCheck(ShrimpVaultIcons.symbols["새 동작"] == nil && ShrimpVaultIcons.name("새 동작") == "새 동작",
                       "Unknown actions retain their text label")
            let model = slack.model
            model.vaultOverride = ShrimpVault(root: FileManager.default.temporaryDirectory.path)
            model.vaultOpen = { _ in nil }; model.vaultReveal = { _ in nil }; model.onSend = { _, _, _, _ in }
            model.query = ""; model.draft = ""; model.replyTo = nil; model.picked = nil
            var choice = ChatMessage(id: "icon-choice", fromUser: false, speaker: "새우튀김",
                body: "선택: 가짜표.xlsx → 시험 시트 → 김가짜\n- 이름: 김가짜\n- id: FAKE-ID\n- pw: 0012", date: Date(), profile: "fried-shrimp")
            choice.slackUserID = ShrimpVault.defaultBot
            var fallback = choice; fallback.id = "icon-fallback"
            fallback.body = "경로 줘 · 열어줘 · 다운로드 · 표 · 수정 · 종결 — 글로 보내도 됩니다"
            let thread = SlackThread(id: "icon-thread", room: "CCOW", ts: "4", root: choice, replies: [fallback],
                                     replyCount: 1, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
            model.threads = [thread]; model.open = [thread.id]; model.reply(thread)
            var rows: [[String: Any]] = []
            for state in ["enabled", "disabled", "missing-folder"] {
                if state == "disabled" {
                    let selection = model.vaultSelection(thread)!
                    model.vaultAction("경로 줘", thread: thread, selection: selection)
                    model.vaultAction("다운로드", thread: thread, selection: selection)
                }
                if state == "missing-folder" {
                    model.objectWillChange.send()
                    model.vaultOverride = ShrimpVault(root: nil)
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                let actions = model.vaultSelection(thread)!.actions
                let frames = actions.compactMap { chat.smokeFrames["vault-" + $0 + "-" + choice.id] }
                smokeCheck(frames.count == 6 && frames.allSatisfy { $0.width > 0 }, "Six preview buttons are measurable")
                smokeCheck(frames.map(\.midY).max()! - frames.map(\.midY).min()! < 2, "Six preview buttons stay on one row")
                let span = frames.map(\.maxX).max()! - frames.map(\.minX).min()!
                smokeCheck(span <= 188 && span <= chat.viewportWidth, "Icon row fits default width")
                smokeCheck(frames.allSatisfy { $0.width == 28 && $0.height == 24 }, "Icons retain 28 x 24 point buttons")
                rows.append(["state": state, "span": span, "viewport": chat.viewportWidth,
                             "buttons": zip(actions, frames).map { ["action": $0.0, "width": $0.1.width, "height": $0.1.height] as [String: Any] }])
                capture(destination: destination.appendingPathComponent(state))
            }
            try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("design.json"))
            NSApp.terminate(nil)
        }
    }
}
