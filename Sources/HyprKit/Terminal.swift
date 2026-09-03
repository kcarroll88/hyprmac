import AppKit
import ApplicationServices

/// An app's own menu bar, pressed over Accessibility — the way a person would,
/// and so in the app's running instance. `open -na` was the alternative and it
/// launched a second copy of the app per call, each with a Dock icon.
public enum AppMenus {
    /// Press the item under `menu` whose title begins with this — an ellipsis is
    /// one character in some menus and three dots in others, and the difference is
    /// invisible to read and fatal to match.
    @discardableResult
    public static func press(menu: String, startingWith prefix: String, in pid: pid_t) -> Bool {
        press(menu: menu, item: nil, startingWith: prefix, in: pid)
    }

    /// Press `item` under the top-level `menu` of the app with this pid.
    @discardableResult
    public static func press(menu: String, item: String, in pid: pid_t) -> Bool {
        press(menu: menu, item: item, startingWith: nil, in: pid)
    }

    /// Whether a text field holds keyboard focus in this app: the rename prompt is
    /// open, rather than a terminal sitting at its shell. Typing into the second by
    /// mistake runs the words as a command.
    public static func textFieldFocused(in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let field: AXUIElement = app.attribute(kAXFocusedUIElementAttribute),
              let role: String = field.attribute(kAXRoleAttribute) else { return false }
        return role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
    }

    private static func press(menu: String, item: String?, startingWith prefix: String?, in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = app.attribute(kAXMenuBarAttribute),
              let tops: [AXUIElement] = bar.attribute(kAXChildrenAttribute) else { return false }
        guard let top = tops.first(where: { ($0.attribute(kAXTitleAttribute) as String?) == menu }),
              let menus: [AXUIElement] = top.attribute(kAXChildrenAttribute), let list = menus.first,
              let items: [AXUIElement] = list.attribute(kAXChildrenAttribute),
              let target = items.first(where: { element in
                  let title = (element.attribute(kAXTitleAttribute) as String?) ?? ""
                  if let item { return title == item }
                  if let prefix { return title.hasPrefix(prefix) }
                  return false
              }) else { return false }
        target.perform(kAXPressAction)
        return true
    }
}

/// Keystrokes delivered to one process, not to whatever is in front.
public enum Keys {
    /// Keystrokes through System Events, for the apps that take no other kind:
    /// Electron drops both per-pid events and session-level posts from a
    /// background process, and takes these — measured on Discord's switcher, which
    /// opened and stayed empty through both, then filled through this. Slower (an
    /// Apple event per call), so only used where the others fail.
    public static func typeViaSystemEvents(_ text: String, into app: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        runOSA("tell application \"System Events\" to tell process \"\(app)\" to keystroke \"\(escaped)\"")
    }
    public static func pressViaSystemEvents(_ keyCode: Int, into app: String, command: Bool = false) {
        let using = command ? " using command down" : ""
        runOSA("tell application \"System Events\" to tell process \"\(app)\" to key code \(keyCode)\(using)")
    }
    private static func runOSA(_ script: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try? task.run(); task.waitUntilExit()
    }

    /// Type text into the app with this pid, then Return if it ends in a newline.
    /// `session` posts at the session level instead of to the pid: Electron apps
    /// (Discord, Slack) drop text posted to their pid the way they drop chords —
    /// the switcher opened and the name never went in — while native apps take
    /// either. Only used once the window is known to hold focus.
    public static func type(_ text: String, into pid: pid_t, session: Bool = false) {
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
                if session { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
            }
        }
        if enter {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down) else { continue }
                if session { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
            }
        }
    }

    /// One key by its code — Return (36) sent apart from a text burst, Escape (53)
    /// to clear a composer. A Return inside the burst is coalesced into a paste by
    /// the terminal, and a pasted newline is a newline, not a submit: two prompts
    /// were found stacked in an agent's composer, typed and never sent.
    public static func press(_ virtualKey: CGKeyCode, into pid: pid_t, command: Bool = false, session: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { continue }
            if session && !command { event.post(tap: .cghidEventTap); continue }
            if command {
                // A modifier chord posted to a pid is dropped by Electron; the same
                // chord posted at the session level reaches the focused window —
                // which is why the window is focused first and this is only used
                // once it holds focus.
                event.flags = .maskCommand
                event.post(tap: .cghidEventTap)
            } else {
                event.postToPid(pid)
            }
        }
    }
}
