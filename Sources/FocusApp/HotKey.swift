import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey via Carbon's RegisterEventHotKey. Works from any app and needs
/// no Accessibility permission (it doesn't read other keystrokes, it only claims one combo).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Only one hotkey is registered, so the C callback can find it through this.
    nonisolated(unsafe) private static var action: (() -> Void)?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x46435553), id: 1)   // 'FCUS'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil   // another app already owns this combination
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
