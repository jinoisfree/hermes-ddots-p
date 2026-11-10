import Carbon
import SwiftUI

private typealias InputSourceState = SwiftUI.State<Bool>

/// Input-source guidance only. Never changes the keyboard source or reads the typed value.
struct ConnectionInputField: View {
    let label: String
    let secure: Bool
    @Binding var text: String
    @FocusState private var focused: Bool
    @InputSourceState private var asciiCapable = ConnectionInputField.currentSourceIsASCIICapable()

    static let inputSourceHint = "지금 한글 입력 상태예요. 비밀번호는 영문(ABC)으로 바꿔 입력해 주세요."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if secure { SecureField(label, text: $text) }
                else { TextField(label, text: $text) }
            }.textFieldStyle(.roundedBorder).focused($focused).accessibilityLabel(label)
            if secure && focused && !asciiCapable {
                Text(Self.inputSourceHint).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: focused) { focused in if focused { asciiCapable = Self.currentSourceIsASCIICapable() } }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)).receive(on: RunLoop.main)) { _ in
                asciiCapable = Self.currentSourceIsASCIICapable()
            }
    }

    private static func currentSourceIsASCIICapable() -> Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return true }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(property).takeUnretainedValue())
    }
}
