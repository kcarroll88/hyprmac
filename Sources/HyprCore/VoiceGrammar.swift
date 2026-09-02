import Foundation

public enum VoiceMode: Sendable, Equatable {
    /// Utterances are parsed as window-manager commands.
    case command
    /// Utterances are typed into whatever has focus.
    case dictation
}

/// What an utterance turned out to mean.
public enum VoiceIntent: Equatable, Sendable {
    /// A window-manager action, indistinguishable from one a keybind produced.
    case dispatch(Dispatcher)
    /// Free text destined for the focused window.
    case dictate(String)
    /// A message routed to a named agent window.
    case tellAgent(name: String, message: String)
    case setMode(VoiceMode)
    case cancel
    case unrecognized(String)
}

/// Turns a transcript into an intent.
///
/// Deliberately pure and free of AppleKit or audio, so the whole command
/// vocabulary is unit tested without a microphone. Speech recognisers are
/// unreliable enough that the grammar has to be the part you can trust.
public enum VoiceGrammar {
    public static func parse(_ transcript: String, mode: VoiceMode = .command) -> VoiceIntent {
        let text = normalize(transcript)
        guard !text.isEmpty else { return .unrecognized(transcript) }

        // Mode switches and cancellation are recognised in every mode, or you can
        // talk yourself into dictation with no way back out.
        if matches(text, ["cancel", "never mind", "nevermind", "stop that", "forget it"]) {
            return .cancel
        }
        if matches(text, ["stop dictation", "stop typing", "command mode", "stop dictating"]) {
            return .setMode(.command)
        }
        if matches(text, ["start dictation", "start typing", "dictation mode", "dictate"]) {
            return .setMode(.dictation)
        }
        if mode == .dictation {
            return .dictate(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Commands are checked first: "send to workspace 5" shares its opening
        // words with the agent form ("send to backend ..."), and the fixed command
        // vocabulary is the more specific match.
        if let dispatcher = parseCommand(text) { return .dispatch(dispatcher) }
        if let agent = parseAgent(text) { return agent }
        return .unrecognized(transcript)
    }

    // MARK: Agent routing

    /// "tell backend to run the tests" / "ask nvim what changed"
    private static func parseAgent(_ text: String) -> VoiceIntent? {
        let openers = ["tell ", "ask ", "send to ", "message "]
        guard let opener = openers.first(where: { text.hasPrefix($0) }) else { return nil }
        let rest = String(text.dropFirst(opener.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }

        // " to " separates a multi-word agent name from the message. Without it,
        // assume the name is a single word.
        if let separator = rest.range(of: " to ") {
            let name = String(rest[rest.startIndex..<separator.lowerBound])
            let message = String(rest[separator.upperBound...])
            guard !name.isEmpty, !message.isEmpty else { return nil }
            return .tellAgent(name: name, message: message)
        }
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return .tellAgent(name: String(parts[0]), message: String(parts[1]))
    }

    // MARK: Window-manager commands

    private static func parseCommand(_ text: String) -> Dispatcher? {
        // Typed asks are polite where spoken ones are not, and "3 please" is not a number.
        let text = text.hasSuffix(" please") ? String(text.dropLast(" please".count)) : text
        if let rest = strip(text, prefixes: ["focus ", "go "]), let d = direction(rest) {
            return .moveFocus(d)
        }
        if let rest = strip(text, prefixes: ["move window ", "move "]), let d = direction(rest) {
            return .moveWindow(d)
        }
        if let rest = strip(text, prefixes: ["swap ", "exchange "]), let d = direction(rest) {
            return .swapWindow(d)
        }
        if let rest = strip(text, prefixes: ["send to workspace ", "move to workspace ",
                                            "send this to workspace "]),
           let n = number(rest) {
            return .moveToWorkspace(n)
        }
        // Spoken forms first; then the ways people type it into Wisper's box, which
        // now comes through here too. "switch me to workspace 3" typed once cost a
        // whole model turn because this list did not have it.
        if let rest = strip(text, prefixes: ["workspace ", "go to workspace ", "switch to workspace ",
                                            "switch me to workspace ", "switch workspace ", "take me to workspace ",
                                            "put me on workspace ", "jump to workspace ", "change to workspace ",
                                            "move me to workspace "]),
           let n = number(rest) {
            return .workspace(n)
        }

        switch true {
        case matches(text, ["zoom", "fullscreen", "full screen", "maximize", "blow up", "expand"]):
            return .toggleFullscreen
        case matches(text, ["unzoom", "restore", "grid", "back to grid", "shrink"]):
            return .toggleFullscreen
        case matches(text, ["close", "close window", "kill", "close this"]):
            return .killActive
        case matches(text, ["float", "toggle float", "unfloat", "floating"]):
            return .toggleFloating
        case matches(text, ["split", "toggle split", "flip split", "rotate"]):
            return .toggleSplit
        case matches(text, ["next window", "next", "cycle"]):
            return .cycleNext
        case matches(text, ["previous window", "previous", "back"]):
            return .cyclePrev
        case matches(text, ["wider", "grow", "grow wider"]):
            return .resizeActive(dx: 60, dy: 0)
        case matches(text, ["narrower", "shrink width", "thinner"]):
            return .resizeActive(dx: -60, dy: 0)
        case matches(text, ["taller", "grow taller"]):
            return .resizeActive(dx: 0, dy: 60)
        case matches(text, ["shorter", "shrink height"]):
            return .resizeActive(dx: 0, dy: -60)
        case matches(text, ["reload", "reload config", "reload configuration"]):
            return .reload
        case matches(text, ["keybindings", "show keybindings", "help", "shortcuts"]):
            return .cheatsheet
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// Lowercase, strip punctuation, collapse whitespace. Recognisers punctuate
    /// unpredictably — "focus left." and "Focus left" must be the same command.
    private static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.punctuationCharacters.contains(scalar) ? " " : Character(scalar)
        }
        return String(stripped)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    private static func matches(_ text: String, _ options: [String]) -> Bool {
        options.contains(text)
    }

    private static func strip(_ text: String, prefixes: [String]) -> String? {
        // Longest first, so "move to workspace" wins over "move ".
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return nil
    }

    private static func direction(_ text: String) -> Direction? {
        switch text {
        case "left", "west":            return .left
        case "right", "east":           return .right
        case "up", "north", "above":    return .up
        case "down", "south", "below":  return .down
        default:                        return nil
        }
    }

    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "won": 1, "to": 2, "too": 2, "tree": 3, "for": 4, "fore": 4, "ate": 8,
    ]

    /// Recognisers render digits as words about half the time, and homophones the
    /// rest ("workspace to"), so accept all three.
    private static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        return numberWords[text]
    }
}
