import AppKit
import ApplicationServices

/// An app's own menu bar, pressed over Accessibility — the way a person would,
/// and so in the app's running instance. `open -na` was the alternative and it
/// launched a second copy of the app per call, each with a Dock icon.
public enum AppMenus {
    /// Press `item` under the top-level `menu` of the app with this pid.
    @discardableResult
    public static func press(menu: String, item: String, in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = app.attribute(kAXMenuBarAttribute),
              let tops: [AXUIElement] = bar.attribute(kAXChildrenAttribute) else { return false }
        guard let top = tops.first(where: { ($0.attribute(kAXTitleAttribute) as String?) == menu }),
              let menus: [AXUIElement] = top.attribute(kAXChildrenAttribute), let list = menus.first,
              let items: [AXUIElement] = list.attribute(kAXChildrenAttribute),
              let target = items.first(where: { ($0.attribute(kAXTitleAttribute) as String?) == item }) else { return false }
        target.perform(kAXPressAction)
        return true
    }
}

/// Keystrokes delivered to one process, not to whatever is in front.
public enum Keys {
    /// Type text into the app with this pid, then Return if it ends in a newline.
    public static func type(_ text: String, into pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        var body = text
        let enter = body.hasSuffix("\n")
        if enter { body.removeLast() }
        // A keyboard event carries up to 20 UTF-16 units of text.
        var units = Array(body.utf16)
        while !units.isEmpty {
            let chunk = Array(units.prefix(20)); units.removeFirst(chunk.count)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.postToPid(pid)
            }
        }
        if enter {
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)
            }
        }
    }

    /// One key by its code — Return (36) sent apart from a text burst, Escape (53)
    /// to clear a composer. A Return inside the burst is coalesced into a paste by
    /// the terminal, and a pasted newline is a newline, not a submit: two prompts
    /// were found stacked in an agent's composer, typed and never sent.
    public static func press(_ virtualKey: CGKeyCode, into pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down)?.postToPid(pid)
        }
    }
}
