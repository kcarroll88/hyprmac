import AppKit
import HyprCore

/// Watches for a modifier pressed twice on its own.
///
/// Modifier-only gestures cannot be Carbon hotkeys, so this listens to
/// `flagsChanged` globally — keyboard events, unlike trackpad gestures, do reach
/// a global monitor — and counts a tap as one press-and-release of exactly the
/// configured modifiers with no other key pressed while they were held. Two taps
/// within `window` fire the dispatcher; a tap that was really the start of
/// `ALT+H` is cancelled by the H.
final class ModifierTapMonitor {
    private let taps: [DoubleTap]
    private let dispatch: (Dispatcher) -> Void
    private var monitors: [Any] = []
    private let window: TimeInterval = 0.4

    private var held: Modifiers = []
    private var heldKey: UInt16 = 0
    private var heldSince: Date?
    private var heldWasClean = true
    private var lastTap: (modifiers: Modifiers, key: UInt16, at: Date)?

    private func matches(_ tap: DoubleTap, _ modifiers: Modifiers, _ key: UInt16) -> Bool {
        tap.modifiers == modifiers && (tap.keyCode == nil || tap.keyCode == key)
    }

    init(taps: [DoubleTap], dispatch: @escaping (Dispatcher) -> Void) {
        self.taps = taps
        self.dispatch = dispatch
    }

    func start() {
        guard !taps.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] event in self?.flagsChanged(event) }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.heldWasClean = false }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: keys) as Any)
        // Our own windows do not deliver to a global monitor.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in flags(event); return event } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in keys(event); return event } as Any)
    }

    /// A hotkey fired while a modifier was held: whatever is held is not a tap,
    /// and the release to come must not count as one.
    func hotkeyFired() {
        heldWasClean = false
        lastTap = nil
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func flagsChanged(_ event: NSEvent) {
        var now: Modifiers = []
        if event.modifierFlags.contains(.option)  { now.insert(.option) }
        if event.modifierFlags.contains(.command) { now.insert(.command) }
        if event.modifierFlags.contains(.control) { now.insert(.control) }
        if event.modifierFlags.contains(.shift)   { now.insert(.shift) }

        if held.isEmpty, !now.isEmpty {
            // Press. A press of more than one modifier at once is not a tap.
            held = now
            heldKey = event.keyCode
            heldSince = Date()
            heldWasClean = true
        } else if !held.isEmpty, now.isEmpty {
            // Release. A tap is a clean, short hold of exactly one configured set.
            let duration = heldSince.map { Date().timeIntervalSince($0) } ?? 1
            let released = held
            let key = heldKey
            held = []
            guard heldWasClean, duration < 0.35, taps.contains(where: { matches($0, released, key) }) else {
                lastTap = nil
                return
            }
            if let last = lastTap, last.modifiers == released, last.key == key, Date().timeIntervalSince(last.at) < window {
                lastTap = nil
                if let tap = taps.first(where: { matches($0, released, key) }) { dispatch(tap.dispatcher) }
            } else {
                lastTap = (released, key, Date())
            }
        } else if !held.isEmpty, now != held {
            // Another modifier joined or left mid-hold: not a tap.
            heldWasClean = false
            held = now
        }
    }
}
