import AppKit

/// Only the secure field holds a copied credential; neither notices nor traces include its value.
final class SlackConnectDialog: NSObject {
    let alert = NSAlert()
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    let status = NSTextField(wrappingLabelWithString: "이 창을 열어 둔 채 토큰을 복사해 주세요.")
    private let clipboard: NSPasteboard
    private var lastChange: Int?

    init(connected: Bool, clipboard: NSPasteboard = .general) {
        self.clipboard = clipboard
        super.init()
        alert.messageText = "슬랙 연결"
        alert.informativeText = "내 이름으로 슬랙 방을 읽고 답글을 답니다. 토큰은 연결 확인 뒤 이 Mac의 키체인에만 저장합니다."
        let steps = NSTextField(wrappingLabelWithString: "① 슬랙 앱 만들기 → 워크스페이스 고르기 → Create\n② Install to Workspace → 허용\n③ OAuth & Permissions → User OAuth Token 복사\n④ 이 창으로 돌아오면 자동으로 들어가요 → 연결")
        let make = NSButton(title: "슬랙 앱 만들기", target: self, action: #selector(makeApp))
        let permissions = NSTextField(wrappingLabelWithString: "방·글·파일 읽기와 내 이름으로 쓰기 권한을 요청합니다. 매니페스트에 필요한 권한이 들어 있어요.")
        permissions.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissions.textColor = .secondaryLabelColor
        field.placeholderString = connected ? "연결됨 (바꿀 때만 입력)" : "xoxp-…"
        field.setAccessibilityLabel("슬랙 사용자 토큰")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [steps, make, permissions, field, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 270)
        alert.accessoryView = stack
        alert.addButton(withTitle: "연결"); alert.addButton(withTitle: "취소")
        if connected { alert.addButton(withTitle: "연결 끊기") }
        alert.window.initialFirstResponder = field
    }

    func fillCopiedToken() {
        guard lastChange != clipboard.changeCount else { return }
        lastChange = clipboard.changeCount
        if let token = SlackConnect.tokenCandidate(clipboard.string(forType: .string)) {
            field.stringValue = token
            status.stringValue = "복사한 토큰을 넣었어요. [연결]을 누르세요"
        }
    }
    func runModal() -> NSApplication.ModalResponse {
        fillCopiedToken()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.fillCopiedToken() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        return alert.runModal()
    }
    @objc private func makeApp() {
        let manifest = Bundle.main.url(forResource: "slack-app-manifest", withExtension: "json").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let manifest { clipboard.clearContents(); clipboard.setString(manifest, forType: .string) }
        status.stringValue = "매니페스트를 복사했어요. 필요하면 From a manifest → ⌘V를 누르세요."
        NSWorkspace.shared.open(SlackConnect.manifestURL(manifest))
    }
}
