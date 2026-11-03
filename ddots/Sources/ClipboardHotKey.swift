import Carbon
import Foundation

/// Carbon's hot-key registration needs no event-tap or accessibility permission.
final class ClipboardHotKey {
    typealias Registration = (UInt32, UInt32, UnsafeMutablePointer<EventHotKeyRef?>) -> OSStatus
    private let register: Registration
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var installed: (UInt32, UInt32)?
    var activate: (() -> Void)?
    private(set) var registrationStatus: OSStatus = noErr
    init(registration: @escaping Registration = { code, modifiers, reference in
        RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x64646F74, id: 1), GetApplicationEventTarget(), 0, reference)
    }) {
        self.register = registration
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ClipboardHotKey>.fromOpaque(data).takeUnretainedValue()
            owner.activate?(); return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func configure(enabled: Bool, code: UInt32, modifiers: UInt32) {
        if enabled && installed?.0 == code && installed?.1 == modifiers { return }
        disable()
        guard enabled else { return }
        registrationStatus = register(code, modifiers, &reference)
        if registrationStatus == noErr { installed = (code, modifiers) }
    }
    func disable() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil; installed = nil; registrationStatus = noErr
    }
    var isRegistered: Bool { reference != nil }
    deinit { disable(); if let handler { RemoveEventHandler(handler) } }
}
