import Foundation

/// Modifier flags, named the way hyprland's config names them.
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift   = Modifiers(rawValue: 1 << 0)
    public static let control = Modifiers(rawValue: 1 << 1)
    public static let option  = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    /// Rendered the way macOS writes shortcuts, in Apple's canonical order.
    public var symbolic: String {
        var out = ""
        if contains(.control) { out += "\u{2303}" }
        if contains(.option)  { out += "\u{2325}" }
        if contains(.shift)   { out += "\u{21E7}" }
        if contains(.command) { out += "\u{2318}" }
        return out
    }

    /// Accepts SUPER/MOD4/CMD, ALT/MOD1/OPT, CTRL, SHIFT — space or `+` separated.
    public static func parse(_ text: String) -> Modifiers {
        var result: Modifiers = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "+" }) {
            switch token.uppercased() {
            case "SUPER", "MOD4", "CMD", "COMMAND", "WIN", "LOGO": result.insert(.command)
            case "ALT", "MOD1", "OPT", "OPTION":                   result.insert(.option)
            case "CTRL", "CONTROL":                                result.insert(.control)
            case "SHIFT":                                          result.insert(.shift)
            default: break
            }
        }
        return result
    }
}

/// Maps hyprland-style key names onto macOS virtual key codes.
public enum KeyCode {
    private static let table: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "equal": 24, "minus": 27, "bracketright": 30, "bracketleft": 33,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "apostrophe": 39, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "period": 47,
        "grave": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "backspace": 51, "delete": 117, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Hyprland uses X11 keysym names; accept those plus the obvious aliases.
    private static let aliases: [String: String] = [
        "esc": "escape", "ret": "return", "bracketleft": "bracketleft",
        "left_bracket": "bracketleft", "right_bracket": "bracketright",
        "prior": "pageup", "next": "pagedown",
    ]

    public static func parse(_ name: String) -> UInt32? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return table[aliases[key] ?? key]
    }

    /// How macOS would print this key in a menu.
    public static func symbol(for code: UInt32) -> String {
        if let glyph = glyphs[code] { return glyph }
        guard let name = table.first(where: { $0.value == code })?.key else { return "?" }
        return name.count == 1 ? name.uppercased() : name.capitalized
    }

    private static let glyphs: [UInt32: String] = [
        36: "\u{21A9}",   // return
        48: "\u{21E5}",   // tab
        49: "Space",
        51: "\u{232B}",   // backspace
        53: "\u{238B}",   // escape
        117: "\u{2326}",  // forward delete
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        115: "\u{2196}", 119: "\u{2198}", 116: "\u{21DE}", 121: "\u{21DF}",
    ]
}
