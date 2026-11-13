import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys that work even when Isle isn't the active app.
///
///   ⌃ Space       — toggle the island
final class GlobalHotkeys {
    private var toggleID = EventHotKeyID(signature: fourCC("isle"), id: 1)
    private var toggleRef: EventHotKeyRef?

    var onToggle: (() -> Void)?

    private var handlerRef: EventHandlerRef?

    func register() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        // ⌃ Space
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey), toggleID,
                            GetApplicationEventTarget(), 0, &toggleRef)
    }

    func unregister() {
        if let ref = toggleRef { UnregisterEventHotKey(ref); toggleRef = nil }
    }
}

/// Carbon event callback: dispatches to the right closure.
private func hotKeyHandler(_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()

    var hotkeyID = EventHotKeyID()
    GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)

    switch hotkeyID.id {
    case 1: hotkeys.onToggle?()
    default: break
    }
    return noErr
}

private func fourCC(_ s: String) -> OSType {
    let bytes = Array(s.utf8)
    return OSType(bytes[0]) << 24 | OSType(bytes[1]) << 16 | OSType(bytes[2]) << 8 | OSType(bytes[3])
}
