import SwiftUI
import Carbon

struct ClipboardSettingsView: View {
    @ObservedObject var library: ClipboardLibrary
    var persist: Bool
    private func setting<T>(_ path: WritableKeyPath<ClipboardSettings, T>) -> Binding<T> {
        Binding(get: { library.settings[keyPath: path] }, set: { value in
            var settings = library.settings; settings[keyPath: path] = value; library.changeSettings(settings, persist: persist)
        })
    }
    var body: some View {
        Form {
            Toggle("클립보드 보관함 켜기", isOn: setting(\.enabled))
            Text("끄면 복사 기록을 모으지 않고 펫에 클립보드가 나타나지 않습니다. 저장된 항목은 지워지지 않습니다.").font(.caption).foregroundStyle(.secondary)
            Picker("자동 삭제", selection: setting(\.days)) {
                Text("1일").tag(1); Text("7일").tag(7); Text("30일").tag(30); Text("끄기").tag(0)
            }
            Picker("최대 일반 항목", selection: setting(\.count)) {
                Text("50개").tag(50); Text("100개").tag(100); Text("200개").tag(200)
            }
            Toggle("이미지·영상 데이터 보관", isOn: setting(\.media))
            Toggle("이미지 속 글자 인식 검색", isOn: setting(\.ocr))
            if library.semantic.available { Toggle("AI 검색", isOn: setting(\.semanticSearch)) }
            else { Text("AI 검색: 이 맥에서는 쓸 수 없어요").font(.caption).foregroundStyle(.secondary) }
            Toggle("복사 알림 표시", isOn: setting(\.copyNotifications))
            Toggle("단축키로 보관함 열기", isOn: setting(\.hotKeyEnabled))
            ClipboardShortcutRecorder(code: setting(\.hotKeyCode), modifiers: setting(\.hotKeyModifiers))
                .frame(height: 24)
            if library.hotKeyError { Text("다른 앱에서 쓰는 단축키예요. 다른 키를 골라 주세요.").foregroundStyle(.orange) }
            Picker("보관함 크기", selection: setting(\.fitsContents)) {
                Text("고정(직접 조절)").tag(false); Text("내용에 맞춤").tag(true)
            }
            Button("크기 기본값으로") {
                if persist { ClipboardDrawer.save(ClipboardDrawer.defaultSize) }
                library.shelfWidth = ClipboardDrawer.defaultSize.width; library.onResetSize?()
            }
            HStack {
                Text("보관함 투명도")
                Slider(value: Binding(get: { library.opacityPercent }, set: {
                    library.opacityPercent = BubbleOpacity.clamped($0)
                    if persist { UserDefaults.standard.set(library.opacityPercent, forKey: ClipboardDrawer.opacityKey) }
                }), in: BubbleOpacity.range)
                Text("\(Int(library.opacityPercent))%")
            }
            Text("제외 앱 (앱 식별자를 줄마다 하나씩)").font(.caption)
            TextEditor(text: Binding(get: { library.settings.excludedApps.joined(separator: "\n") }, set: { text in
                var settings = library.settings
                settings.excludedApps = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                library.changeSettings(settings, persist: persist)
            })).font(.system(.caption, design: .monospaced)).frame(height: 80).border(Color.secondary.opacity(0.3))
            if library.permissionNeeded {
                Text("다른 앱에서 붙여넣기 허용이 필요해요").foregroundColor(.orange)
                Button("설정 열기", action: ClipboardLibrary.openSettings)
            }
            Text("비밀번호도 기기에 암호화해 보관합니다. 고정·마음대로 탭 항목은 자동 삭제에서 제외합니다. 파일은 위치만 기록하며 원본을 지우지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

private struct ClipboardShortcutRecorder: NSViewRepresentable {
    @Binding var code: UInt32
    @Binding var modifiers: UInt32
    func makeNSView(context: Context) -> ClipboardShortcutButton { ClipboardShortcutButton() }
    func updateNSView(_ button: ClipboardShortcutButton, context: Context) {
        button.title = "단축키 변경 · " + ClipboardShortcutButton.label(code: code, modifiers: modifiers); button.setAccessibilityLabel("보관함 단축키 변경")
        button.changed = { code = $0; modifiers = $1 }
    }
}
private final class ClipboardShortcutButton: NSButton {
    var changed: ((UInt32, UInt32) -> Void)?
    static func label(code: UInt32, modifiers: UInt32) -> String {
        let keys: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",25:"9",26:"7",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",36:"↩",48:"⇥",49:"스페이스",51:"⌫",123:"←",124:"→",125:"↓",126:"↑"]
        var prefix = ""
        for (mask, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(mask) != 0 { prefix += symbol }
        }
        return prefix + (keys[code] ?? "선택한 키")
    }
    override init(frame: CGRect) { super.init(frame: frame); bezelStyle = .rounded; target = self; action = #selector(record) }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    @objc private func record() { title = "새 단축키를 누르세요 (Esc 취소)"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.control) else { NSSound.beep(); return }
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        changed?(UInt32(event.keyCode), mask); window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event)
    }
}
