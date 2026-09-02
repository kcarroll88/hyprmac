import CoreGraphics
import Foundation

/// What a keybind does. Names match hyprland's dispatchers so muscle memory and
/// existing configs carry over.
public enum Dispatcher: Equatable, Sendable {
    case exec(String)
    case killActive
    case closeWindow
    case moveFocus(Direction)
    case moveWindow(Direction)
    case swapWindow(Direction)
    case resizeActive(dx: CGFloat, dy: CGFloat)
    case toggleFloating
    case toggleFullscreen
    case toggleSplit
    case workspace(Int)
    case moveToWorkspace(Int)
    /// Relative hop, wrapping at the ends: `workspace, +1`.
    case workspaceRelative(Int)
    /// Addressed by name rather than number, so a bind survives renumbering.
    case workspaceNamed(String)
    case moveToWorkspaceNamed(String)
    case cycleNext
    case cyclePrev
    case renameWorkspace
    /// Open a prompt whose text is routed to a named agent window rather than run as a
    /// command — the consumer for `VoiceGrammar`'s `.tellAgent`, driven by the keyboard
    /// instead of a microphone.
    case askAgent
    /// Every workspace at once, to jump straight to one.
    case workspaceOverview
    /// Move the current workspace along in the ordering, taking its windows and
    /// its name with it.
    case moveWorkspace(Int)
    case cheatsheet
    /// A new window in the running terminal, not a new instance of it.
    case terminal
    case reload
    case exit

    /// Human label for the keybinding sheet.
    public var label: String {
        switch self {
        case .exec(let command):       return command
        case .killActive, .closeWindow: return "Close window"
        case .moveFocus(let d):        return "Focus \(d.rawValue)"
        case .moveWindow(let d):       return "Move window \(d.rawValue)"
        case .swapWindow(let d):       return "Swap with \(d.rawValue)"
        case .resizeActive(let x, let y):
            if x != 0 { return x > 0 ? "Grow width" : "Shrink width" }
            return y > 0 ? "Grow height" : "Shrink height"
        case .toggleFloating:          return "Toggle floating"
        case .toggleFullscreen:        return "Toggle fullscreen"
        case .toggleSplit:             return "Toggle split direction"
        case .workspace(let n):             return "Workspace \(n)"
        case .moveToWorkspace(let n):       return "Move to workspace \(n)"
        case .workspaceRelative(let d):     return d > 0 ? "Next workspace" : "Previous workspace"
        case .workspaceNamed(let name):     return "Workspace \(name)"
        case .moveToWorkspaceNamed(let n):  return "Move to \(n)"
        case .cycleNext:               return "Cycle windows"
        case .cyclePrev:               return "Cycle windows back"
        case .renameWorkspace:         return "Rename workspace"
        case .askAgent:                return "Ask an agent"
        case .workspaceOverview:       return "Workspace overview"
        case .moveWorkspace(let d):    return d > 0 ? "Move workspace right" : "Move workspace left"
        case .cheatsheet:              return "Show keybindings"
        case .terminal:                return "New terminal window"
        case .reload:                  return "Reload config"
        case .exit:                    return "Quit hyprmac"
        }
    }

    /// Grouping for the keybinding sheet.
    public var category: String {
        switch self {
        case .exec, .askAgent, .terminal:               return "Launch"
        case .moveFocus, .cycleNext, .cyclePrev:        return "Focus"
        case .moveWindow, .swapWindow:                  return "Move"
        case .resizeActive:                             return "Resize"
        case .workspace, .moveToWorkspace, .renameWorkspace, .workspaceRelative,
             .workspaceOverview, .moveWorkspace,
             .workspaceNamed, .moveToWorkspaceNamed:    return "Workspaces"
        case .killActive, .closeWindow, .toggleFloating,
             .toggleFullscreen, .toggleSplit:           return "Window"
        case .cheatsheet, .reload, .exit:               return "Session"
        }
    }

    public static func parse(_ name: String, _ argument: String) -> Dispatcher? {
        let arg = argument.trimmingCharacters(in: .whitespaces)
        switch name.lowercased() {
        case "exec":            return .exec(arg)
        case "killactive":      return .killActive
        case "closewindow":     return .closeWindow
        case "movefocus":       return direction(arg).map(Dispatcher.moveFocus)
        case "movewindow":      return direction(arg).map(Dispatcher.moveWindow)
        case "swapwindow":      return direction(arg).map(Dispatcher.swapWindow)
        case "resizeactive":
            let parts = arg.split(separator: " ").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return .resizeActive(dx: CGFloat(parts[0]), dy: CGFloat(parts[1]))
        case "togglefloating":   return .toggleFloating
        case "fullscreen":       return .toggleFullscreen
        case "togglesplit":      return .toggleSplit
        case "workspace":
            // A leading sign means relative; a bare number is absolute.
            if arg.hasPrefix("+") || arg.hasPrefix("-"), let delta = Int(arg) {
                return delta == 0 ? nil : .workspaceRelative(delta)
            }
            if let index = Int(arg) { return .workspace(index) }
            return arg.isEmpty ? nil : .workspaceNamed(arg)
        case "movetoworkspace":
            if let index = Int(arg) { return .moveToWorkspace(index) }
            return arg.isEmpty ? nil : .moveToWorkspaceNamed(arg)
        case "cyclenext":        return arg == "prev" ? .cyclePrev : .cycleNext
        case "renameworkspace":  return .renameWorkspace
        case "askagent", "ask":  return .askAgent
        case "overview", "workspaceoverview": return .workspaceOverview
        case "moveworkspace":
            guard let delta = Int(arg), delta != 0 else { return nil }
            return .moveWorkspace(delta)
        case "cheatsheet":       return .cheatsheet
        case "terminal": return .terminal
        case "reload":           return .reload
        case "exit":             return .exit
        default:                 return nil
        }
    }

    /// hyprland spells directions `l r u d`; accept the long names too.
    private static func direction(_ text: String) -> Direction? {
        switch text.lowercased() {
        case "l", "left":  return .left
        case "r", "right": return .right
        case "u", "up":    return .up
        case "d", "down":  return .down
        default:           return nil
        }
    }
}

/// A modifier pressed twice on its own — `doubletap = ALT, exec, open wisper://listen`.
/// No key, so not a hotkey the system can register; hyprmac watches modifier
/// changes for it. Two isolated presses within a short window, with nothing else
/// pressed while the modifier was down, so `ALT+H` can never count as a tap.
public struct DoubleTap: Equatable, Sendable {
    public let modifiers: Modifiers
    /// One side only — `RCTRL`, `LALT` — as the modifier key's own key code, the
    /// way a `flagsChanged` event reports it. Nil means either side.
    public let keyCode: UInt16?
    public let dispatcher: Dispatcher

    public init(modifiers: Modifiers, keyCode: UInt16? = nil, dispatcher: Dispatcher) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.dispatcher = dispatcher
    }

    /// `SUPER` is either ⌘; `RSUPER` is the right one. ⌘ on its own was a bad tap:
    /// two quick presses while reaching for C or V brought Wisper up and took the
    /// paste. Right control is a key nobody taps by accident.
    public static let sided: [String: (Modifiers, UInt16)] = [
        "LCTRL": (.control, 59), "LCONTROL": (.control, 59), "RCTRL": (.control, 62), "RCONTROL": (.control, 62),
        "LSUPER": (.command, 55), "LCMD": (.command, 55), "RSUPER": (.command, 54), "RCMD": (.command, 54),
        "LALT": (.option, 58), "LOPT": (.option, 58), "RALT": (.option, 61), "ROPT": (.option, 61),
        "LSHIFT": (.shift, 56), "RSHIFT": (.shift, 60),
    ]

    public static func parseModifier(_ text: String) -> (modifiers: Modifiers, keyCode: UInt16?) {
        let token = text.trimmingCharacters(in: .whitespaces).uppercased()
        if let side = sided[token] { return (side.0, side.1) }
        return (Modifiers.parse(text), nil)
    }
}

public struct Bind: Equatable, Sendable {
    public let modifiers: Modifiers
    public let keyCode: UInt32
    public let dispatcher: Dispatcher
}

/// What the canvas paints behind the tiles.
public enum WallpaperSource: Equatable, Sendable {
    /// The picture macOS is already showing. Keeps the desktop looking like the
    /// user's desktop rather than something we imposed.
    case system
    case color(UInt32)
    case file(String)
}

public struct Config: Sendable {
    public var gaps = Gaps(inner: 12, outer: 16)
    public var borderSize: CGFloat = 1
    /// macOS window corner radius. Tile slots match it so the canvas lines up
    /// with the real windows sitting on top.
    public var rounding: CGFloat = 12
    /// Use the user's own accent colour from System Settings for the focused tile.
    /// Nothing reads more native than the colour they already picked.
    public var activeBorderUsesAccent = true
    public var activeBorderColor: UInt32 = 0xFF89B4FA
    public var inactiveBorderColor: UInt32 = 0x30FFFFFF
    /// Draw the canvas behind windows at all. Off makes this a plain tiling WM.
    public var canvasEnabled = true
    public var canvasOpacity: CGFloat = 1.0
    public var wallpaper: WallpaperSource = .system
    /// Optional wallpaper dimming, 0...1. Off by default: someone chose that
    /// background, and washing it out to flatter our own tiles is not our call.
    public var wallpaperDim: CGFloat = 0
    /// Keep Finder's desktop icons visible by sitting below them.
    public var showDesktopIcons = true
    /// Shadow under each tile slot, matching the shadow macOS gives a real window.
    public var slotShadow = true
    /// Three-finger swipe to change workspace.
    public var gesturesEnabled = true
    public var gestureFingers = 3
    /// Fraction of the trackpad the hand must travel before it counts.
    public var gestureThreshold: CGFloat = 0.06
    /// Whether the up-and-down swipe opens the overview. On: the overview is how
    /// you find a window here, and it is the one that can — Mission Control does not
    /// look in the screen corner where parked windows live. `ALT+\`` does the same.
    public var gestureOverview = true
    public var gestureInverted = false
    /// Crossfade through the desktop on a workspace switch. Nothing public can
    /// fade another app's window, so this fades an overlay of our own instead;
    /// see `WorkspaceTransition`. Skipped when the system asks for reduced motion.
    public var animationsEnabled = true
    /// Whole switch, in and out, in seconds.
    public var animationDuration: TimeInterval = 0.25
    /// Menu bar workspace indicator.
    public var menuBarIndicator = true
    /// Brief HUD on workspace change, in the style of the system volume overlay.
    public var workspaceHUD = true
    /// Fixed, deliberately. hyprland grows workspaces on demand because a Linux
    /// desktop has nowhere else to put them; macOS already has Spaces, and a WM
    /// that lets you mint a tenth workspace with no key bound to it just produces
    /// dead hotkeys and workspaces you can only reach by stepping. Five, all
    /// bound, all reachable.
    public let workspaceCount = 5
    /// Optional names, keyed by workspace index. Turns "workspace 3" into
    /// "backend" everywhere it is shown.
    public var workspaceNames: [Int: String] = [:]
    /// Apps that should always float, by bundle id.
    /// Agents reachable by name, mapped to the URL prefix a message is appended to.
    /// `agent { wisper = wisper://ask?q= }` makes "ask wisper why is my disk full" open
    /// `wisper://ask?q=why%20is%20my%20disk%20full`. Any app that registers a URL scheme
    /// can be added; nothing here is specific to Wisper.
    public var agents: [String: String] = [:]

    public var floatingBundleIDs: Set<String> = []
    /// Apps the window manager leaves entirely alone: not tiled, not parked, not
    /// listed. Wisper is here by default — as an overlay she sits above the
    /// desktop while you are talking to her and is gone otherwise, which is not a
    /// thing a tile does.
    public var ignoredBundleIDs: Set<String> = ["dev.keenancarroll.wisper"]
    public var binds: [Bind] = []
    public var doubleTaps: [DoubleTap] = []

    public init() {}

    /// What to show for a workspace: its name if it has one, else its number.
    public func workspaceLabel(_ index: Int) -> String {
        workspaceNames[index] ?? "\(index)"
    }

    /// Step `offset` workspaces from `current`, wrapping at both ends so the
    /// gesture and the bracket keys never dead-end.
    public func workspace(from current: Int, offset: Int) -> Int {
        let count = workspaceCount
        let zeroBased = (current - 1 + offset) % count
        return (zeroBased + count) % count + 1
    }

    /// Index of the workspace whose name matches, case-insensitively. Lets a
    /// project be addressed by name rather than by remembering its number.
    public func workspaceIndex(named name: String) -> Int? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return workspaceNames.first { $0.value.lowercased() == wanted }?.key
    }
}

/// Parser for the hyprland.conf dialect: `key = value`, `section { ... }`,
/// `$variables`, and `bind = MODS, KEY, dispatcher, args`.
public enum ConfigParser {
    public struct Diagnostic: Equatable, Sendable {
        public let line: Int
        public let message: String
    }

    struct BindError: Error { let message: String }

    public static func parse(_ source: String) -> (config: Config, diagnostics: [Diagnostic]) {
        var config = Config()
        var diagnostics: [Diagnostic] = []
        var variables: [String: String] = [:]
        var section: [String] = []

        for (index, rawLine) in source.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line == "}" {
                if section.isEmpty {
                    diagnostics.append(.init(line: lineNumber, message: "unmatched '}'"))
                } else {
                    section.removeLast()
                }
                continue
            }
            if line.hasSuffix("{") {
                section.append(String(line.dropLast()).trimmingCharacters(in: .whitespaces).lowercased())
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                diagnostics.append(.init(line: lineNumber, message: "expected 'key = value'"))
                continue
            }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            value = expand(value, variables)

            if key.hasPrefix("$") {
                variables[String(key.dropFirst())] = value
                continue
            }

            if key.lowercased() == "bind" {
                switch parseBind(value) {
                case .success(let bind): config.binds.append(bind)
                case .failure(let error): diagnostics.append(.init(line: lineNumber, message: error.message))
                }
                continue
            }
            if key.lowercased() == "doubletap" {
                let parts = value.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let (modifiers, keyCode) = parts.count > 0 ? DoubleTap.parseModifier(parts[0]) : ([], nil)
                let dispatcher = parts.count > 1 ? Dispatcher.parse(parts[1], parts.count > 2 ? parts[2] : "") : nil
                if modifiers.isEmpty {
                    diagnostics.append(.init(line: lineNumber, message: "doubletap needs a modifier: ALT, SUPER, CTRL, SHIFT — or one side, like RCTRL or LALT"))
                } else if let dispatcher {
                    config.doubleTaps.append(DoubleTap(modifiers: modifiers, keyCode: keyCode, dispatcher: dispatcher))
                } else {
                    diagnostics.append(.init(line: lineNumber, message: "doubletap needs MOD, dispatcher[, args]"))
                }
                continue
            }

            let path = (section + [key.lowercased()]).joined(separator: ".")
            if let reason = retired[path] {
                diagnostics.append(.init(line: lineNumber, message: "'\(path)' was removed \u{2014} \(reason)"))
                continue
            }
            if !apply(path: path, value: value, to: &config) {
                diagnostics.append(.init(line: lineNumber, message: "unknown setting '\(path)'"))
            }
        }

        if !section.isEmpty {
            diagnostics.append(.init(line: 0, message: "unclosed section '\(section.joined(separator: "."))'"))
        }
        return (config, diagnostics)
    }

    /// Settings that used to exist. Named here so an old config gets told what
    /// happened instead of "unknown setting", which reads like a typo in a line
    /// the user never typed \u{2014} every config written before this shipped has one.
    private static let retired: [String: String] = [
        "workspaces.count": "hyprmac has five workspaces, and the count is no longer configurable",
    ]

    private static func expand(_ value: String, _ variables: [String: String]) -> String {
        guard value.contains("$") else { return value }
        var out = value
        // Longest names first, so $mod doesn't clobber $modifier.
        for name in variables.keys.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: "$" + name, with: variables[name]!)
        }
        return out
    }

    private static func apply(path: String, value: String, to config: inout Config) -> Bool {
        // `workspaces { 3 = backend }` — a numeric key inside the section names it.
        if path.hasPrefix("workspaces."),
           let index = Int(path.dropFirst("workspaces.".count)) {
            let name = value.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                config.workspaceNames[index] = nil
            } else {
                config.workspaceNames[index] = name
            }
            return true
        }
        switch path {
        case "general.gaps_in":              config.gaps.inner = CGFloat(Double(value) ?? 5)
        case "general.gaps_out":             config.gaps.outer = CGFloat(Double(value) ?? 12)
        case "general.border_size":          config.borderSize = CGFloat(Double(value) ?? 1)
        case "general.rounding":             config.rounding = CGFloat(Double(value) ?? 12)
        case "general.col.active_border":
            // `accent` tracks System Settings instead of pinning a colour.
            if value.lowercased() == "accent" {
                config.activeBorderUsesAccent = true
            } else {
                config.activeBorderUsesAccent = false
                config.activeBorderColor = color(value) ?? config.activeBorderColor
            }
        case "general.col.inactive_border":  config.inactiveBorderColor = color(value) ?? config.inactiveBorderColor
        case "canvas.enabled":               config.canvasEnabled = boolean(value)
        case "canvas.opacity":               config.canvasOpacity = CGFloat(Double(value) ?? 1)
        case "canvas.wallpaper":
            switch value.lowercased() {
            case "system", "": config.wallpaper = .system
            default:
                config.wallpaper = color(value).map(WallpaperSource.color)
                    ?? .file((value as NSString).expandingTildeInPath)
            }
        case "canvas.dim":                   config.wallpaperDim = min(1, max(0, CGFloat(Double(value) ?? 0)))
        case "canvas.desktop_icons":         config.showDesktopIcons = boolean(value)
        case "canvas.slot_shadow":           config.slotShadow = boolean(value)
        case "canvas.menu_bar_indicator":    config.menuBarIndicator = boolean(value)
        case "canvas.workspace_hud":         config.workspaceHUD = boolean(value)
        case "gestures.enabled":             config.gesturesEnabled = boolean(value)
        case "gestures.fingers":             config.gestureFingers = Int(value) ?? 3
        case "gestures.threshold":           config.gestureThreshold = CGFloat(Double(value) ?? 0.06)
        case "gestures.overview":            config.gestureOverview = boolean(value)
        case "gestures.natural":             config.gestureInverted = !boolean(value)
        case "animations.enabled":           config.animationsEnabled = boolean(value)
        case "animations.duration":
            // Milliseconds, the unit people actually think in for this. Clamped so a
            // typo cannot leave the screen covered for a second.
            config.animationDuration = min(1.0, max(0, (Double(value) ?? 250) / 1000))
        case "windowrule.float":             config.floatingBundleIDs.insert(value)
        case "windowrule.ignore":            config.ignoredBundleIDs.insert(value)
        default:
            // `agent.<name> = <url prefix>` — an open namespace, so adding an agent is a
            // config line rather than a code change.
            if path.hasPrefix("agent."), case let name = String(path.dropFirst("agent.".count)), !name.isEmpty {
                config.agents[name.lowercased()] = value
                return true
            }
            return false
        }
        return true
    }

    private static func boolean(_ value: String) -> Bool {
        ["true", "yes", "1", "on"].contains(value.lowercased())
    }

    /// Accepts `0xAARRGGBB` and `rgba(rrggbbaa)` / `rgb(rrggbb)`.
    private static func color(_ value: String) -> UInt32? {
        var text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("rgba(") || text.hasPrefix("rgb(") {
            let opaque = text.hasPrefix("rgb(")
            text = text.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" }).description
            guard let raw = UInt32(text, radix: 16) else { return nil }
            // rgba() is RGBA in source order; we store ARGB.
            return opaque ? (0xFF00_0000 | raw) : (raw >> 8) | (raw << 24)
        }
        if text.hasPrefix("0x") { text = String(text.dropFirst(2)) }
        return UInt32(text, radix: 16)
    }

    private static func parseBind(_ value: String) -> Result<Bind, BindError> {
        // MODS, KEY, dispatcher[, args...] — args may themselves contain commas.
        let parts = value.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return .failure(BindError(message: "bind needs at least MODS, KEY, dispatcher")) }

        guard let keyCode = KeyCode.parse(parts[1]) else { return .failure(BindError(message: "unknown key '\(parts[1])'")) }
        let argument = parts.count > 3 ? parts[3] : ""
        guard let dispatcher = Dispatcher.parse(parts[2], argument) else {
            return .failure(BindError(message: "unknown dispatcher '\(parts[2])'"))
        }
        return .success(Bind(modifiers: Modifiers.parse(parts[0]), keyCode: keyCode, dispatcher: dispatcher))
    }
}
