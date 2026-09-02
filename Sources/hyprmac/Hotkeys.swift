import AppKit
import Carbon.HIToolbox
import HyprCore

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Chosen over a CGEventTap deliberately: the Carbon API needs no extra
/// permission beyond what we already hold, cannot drop events under load, and
/// consumes the keystroke so `ALT+H` never reaches the focused app as a stray
/// character.
final class HotkeyManager {
    private var actions: [UInt32: () -> Void] = [:]
    /// Called for every hotkey that fires, before its action. Carbon consumes the
    /// keystroke, so nothing downstream ever sees the key — including the
    /// modifier-tap monitor, to which ALT+H would otherwise look like a clean tap
    /// of ALT. Measured: ALT+H followed by one tap of ALT fired the double-tap.
    var onAnyHotkey: (() -> Void)?
    private var registered: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    /// Carbon's signature is a FourCC; any unique value works.
    private static let signature: OSType = 0x6D687970  // 'mhyp'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            manager.onAnyHotkey?()
            manager.actions[hotKeyID.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(modifiers: Modifiers, keyCode: UInt32, action: @escaping () -> Void) -> Bool {
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonFlags(modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        actions[nextID] = action
        registered.append(ref)
        nextID += 1
        return true
    }

    /// Drops every binding, so a config reload starts from a clean slate.
    func unregisterAll() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        actions.removeAll()
    }

    private func carbonFlags(_ modifiers: Modifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.shift)   { flags |= UInt32(shiftKey) }
        if modifiers.contains(.option)  { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }
}
