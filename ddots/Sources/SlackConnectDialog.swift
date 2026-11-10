import AppKit
import SwiftUI

/// Only the secure field holds a copied credential; neither notices nor traces include its value.
final class SlackConnectDialog: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    let status = NSTextField(wrappingLabelWithString: "이 창을 열어 둔 채 토큰을 복사해 주세요.")
    private let clipboard: NSPasteboard
    private var lastChange: Int?
    private let guideInput = SecretInput()
    private var guide: AgentActionReply.Guide?

    init(connected: Bool, clipboard: NSPasteboard = .general, guideReply: AgentActionReply? = nil) {
        self.clipboard = clipboard
        super.init()
        alert.messageText = "슬랙 연결"
        alert.informativeText = "내 이름으로 슬랙 방을 읽고 답글을 답니다. 토큰은 연결 확인 뒤 이 Mac의 키체인에만 저장합니다."
        let manifest = Bundle.main.url(forResource: "slack-app-manifest", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let home = HermesLocator.shared.locate() ?? HermesLocator.shared.fallbackHome
        if let guideReply { guide = guideReply.guide }
        else if let manifest, let data = try? AgentConnectionCommand.run(executable: home.appendingPathComponent("bin/hermes-connections"),
            arguments: ["secret", "guide", "--profile", "default", "--connection", "ddots-slack", "--manifest-stdin", "--json"], input: manifest),
           let reply = try? AgentActionReply.decode(data) { guide = reply.guide }
        let instructions: NSView
        if let guide {
            instructions = NSHostingView(rootView: SlackInputGuide(guide: guide, input: guideInput))
        } else { instructions = NSTextField(wrappingLabelWithString: "연결 안내를 읽지 못했어요. Hermes 연결을 확인하고 다시 열어 주세요.") }
        let permissions = NSTextField(wrappingLabelWithString: "방·글·파일 읽기와 내 이름으로 쓰기 권한을 요청합니다. 매니페스트에 필요한 권한이 들어 있어요.")
        permissions.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissions.textColor = .secondaryLabelColor
        field.placeholderString = connected ? "연결됨 (바꿀 때만 입력)" : "xoxp-…"
        field.setAccessibilityLabel("슬랙 사용자 토큰")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.delegate = self
        let stack = NSStackView(views: [instructions, permissions, field, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 430)
        alert.accessoryView = stack
        alert.addButton(withTitle: "연결"); alert.addButton(withTitle: "취소")
        if connected { alert.addButton(withTitle: "연결 끊기") }
        alert.buttons.first?.isEnabled = false
        alert.window.initialFirstResponder = field
    }

    func fillCopiedToken() {
        guard lastChange != clipboard.changeCount else { return }
        lastChange = clipboard.changeCount
        if let token = SlackConnect.tokenCandidate(clipboard.string(forType: .string)) {
            field.stringValue = token
            guideInput.values = ["token": token]
            status.stringValue = guide?.error(guideInput.values) ?? "복사한 값을 확인했어요."
            alert.buttons.first?.isEnabled = guide != nil && guide?.error(guideInput.values) == nil
        }
    }
    func runModal() -> NSApplication.ModalResponse {
        fillCopiedToken()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.fillCopiedToken() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); guideInput.clear() }
        return alert.runModal()
    }
    func controlTextDidChange(_ notification: Notification) {
        guideInput.values = ["token": field.stringValue]
        status.stringValue = guide?.error(guideInput.values) ?? ""
        alert.buttons.first?.isEnabled = SlackConnect.tokenCandidate(field.stringValue) != nil && guide != nil && guide?.error(guideInput.values) == nil
    }
}

private struct SlackInputGuide: View {
    let guide: AgentActionReply.Guide
    @ObservedObject var input: SecretInput
    var body: some View { ConnectionGuideView(guide: guide, values: input.values).frame(width: 360) }
}
