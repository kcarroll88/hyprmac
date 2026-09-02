import ApplicationServices
import AppKit
import HyprCore

/// Private but SIP-safe: maps an AX window to the CGWindowID everything else on
/// the system uses. yabai and AeroSpace both rely on this; it has been stable for
/// a decade and needs no code injection.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

public enum Accessibility {
    /// Whether we're allowed to drive other apps' windows.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts once, opening System Settings on the Accessibility pane.
    /// The grant only takes effect for a fresh process, so the caller should exit.
    @discardableResult
    public static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Whether an application is hidden, read live from the application itself.
    ///
    /// `NSRunningApplication.hide()` and `.unhide()` return **false** even when
    /// they work, and `.isHidden` is notification-backed — it never changes
    /// without a run loop turn. This attribute is the live truth.
    public static func isHidden(pid: pid_t) -> Bool? {
        (AXUIElementCreateApplication(pid).attribute(kAXHiddenAttribute) as NSNumber?)?.boolValue
    }

    /// Block until the app has gone off screen, or `timeout` elapses. `hide()` is
    /// a request the app services on its own run loop; measured at 0-17ms.
    @discardableResult
    public static func waitUntilHidden(pid: pid_t, timeout: TimeInterval = 0.15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isHidden(pid: pid) == true { return true }
            usleep(500)
        }
        return isHidden(pid: pid) == true
    }

    /// Every on-screen window's place in the stack, front to back: a lower number
    /// is nearer the front. Parked windows are on screen as far as the
    /// WindowServer is concerned, so they are in here too — which is what lets a
    /// sliver be placed under a tile that is *known* to be above it, rather than
    /// one guessed to be.
    public static func stackingOrder() -> [CGWindowID: Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, info) in list.enumerated() {
            if let number = info[kCGWindowNumber as String] as? CGWindowID { order[number] = index }
        }
        return order
    }

    /// The topmost ordinary window at a screen point, whoever owns it.
    ///
    /// Cheaper than asking Accessibility — one call to the window server, no round
    /// trip into another app's main thread — and, unlike hyprmac's own registry, it
    /// sees windows hyprmac does not manage: floating panels, dialogs, and the
    /// picture-in-picture window that used to start a drag of whatever tiled window
    /// happened to lie beneath it. Layer 0 is the ordinary window layer; the menu bar,
    /// the Dock and hyprmac's own canvas are not in it.
    public static func windowUnderPointer(_ point: CGPoint) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            if CGRect(x: x, y: y, width: w, height: h).contains(point) {
                return info[kCGWindowNumber as String] as? CGWindowID
            }
        }
        return nil
    }

    /// Every ordinary window the window server currently has on screen.
    /// Nil means the window server would not answer. An *empty set* is a real answer
    /// and a common one: on a workspace holding a single app, every other app is
    /// hidden, so when that app hides its own window there is genuinely nothing on
    /// screen. Conflating the two — treating empty as "no evidence" — is what stopped
    /// hyprmac letting go of a window it had correctly spotted as hidden, twice.
    public static func onScreenWindowIDs() -> Set<CGWindowID>? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return Set(list.compactMap { info in
            (info[kCGWindowLayer as String] as? Int) == 0 ? info[kCGWindowNumber as String] as? CGWindowID : nil
        })
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }
}

// MARK: - Typed attribute access

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    func point(_ name: String) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var out = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &out) else { return nil }
        return out
    }

    func size(_ name: String) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var out = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &out) else { return nil }
        return out
    }

    @discardableResult
    func set(_ name: String, _ p: CGPoint) -> Bool {
        var v = p
        guard let value = AXValueCreate(.cgPoint, &v) else { return false }
        return AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    @discardableResult
    func set(_ name: String, _ s: CGSize) -> Bool {
        var v = s
        guard let value = AXValueCreate(.cgSize, &v) else { return false }
        return AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    @discardableResult
    func set(_ name: String, _ b: Bool) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, b as CFBoolean) == .success
    }

    func isSettable(_ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    func perform(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }
}

/// Apps that advertise `AXEnhancedUserInterface` (anything AppKit-based with
/// accessibility features on, plus every Electron app) animate programmatic frame
/// changes, which makes tiling visibly lag and can land the window in the wrong
/// place. Suppressing it around a batch of writes is the standard fix.
final class EnhancedUserInterfaceSuppression {
    private let app: AXUIElement
    private let wasEnabled: Bool

    init(pid: pid_t) {
        app = AXUIElementCreateApplication(pid)
        wasEnabled = (app.attribute("AXEnhancedUserInterface") as NSNumber?)?.boolValue ?? false
        if wasEnabled { app.set("AXEnhancedUserInterface", false) }
    }

    deinit {
        if wasEnabled { app.set("AXEnhancedUserInterface", true) }
    }
}
