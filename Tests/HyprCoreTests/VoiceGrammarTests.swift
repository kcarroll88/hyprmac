import Testing
@testable import HyprCore

@Suite("Voice grammar")
struct VoiceGrammarTests {

    // MARK: Commands

    @Test func directionalCommands() {
        #expect(VoiceGrammar.parse("focus left") == .dispatch(.moveFocus(.left)))
        #expect(VoiceGrammar.parse("go right") == .dispatch(.moveFocus(.right)))
        #expect(VoiceGrammar.parse("move window up") == .dispatch(.moveWindow(.up)))
        #expect(VoiceGrammar.parse("move down") == .dispatch(.moveWindow(.down)))
        #expect(VoiceGrammar.parse("swap left") == .dispatch(.swapWindow(.left)))
    }

    @Test func punctuationAndCasingAreIgnored() {
        // Recognisers punctuate unpredictably; the same words must parse the same.
        #expect(VoiceGrammar.parse("Focus left.") == .dispatch(.moveFocus(.left)))
        #expect(VoiceGrammar.parse("  FOCUS   LEFT  ") == .dispatch(.moveFocus(.left)))
        #expect(VoiceGrammar.parse("focus, left!") == .dispatch(.moveFocus(.left)))
    }

    @Test func workspaceNumbersInEveryForm() {
        #expect(VoiceGrammar.parse("workspace 3") == .dispatch(.workspace(3)))
        #expect(VoiceGrammar.parse("workspace three") == .dispatch(.workspace(3)))
        // "two" is routinely transcribed as "to".
        #expect(VoiceGrammar.parse("workspace to") == .dispatch(.workspace(2)))
        #expect(VoiceGrammar.parse("switch to workspace nine") == .dispatch(.workspace(9)))
    }

    @Test func workspaceAsTypedIntoWisper() {
        // Typed, not spoken: a capital, a full stop, "me", "please" — Wisper routes
        // typed asks through the grammar too, so these must not reach the model.
        #expect(VoiceGrammar.parse("Switch me to Workspace 3.") == .dispatch(.workspace(3)))
        #expect(VoiceGrammar.parse("take me to workspace 2") == .dispatch(.workspace(2)))
        #expect(VoiceGrammar.parse("go to workspace 4 please") == .dispatch(.workspace(4)))
        #expect(VoiceGrammar.parse("switch workspace 5") == .dispatch(.workspace(5)))
        #expect(VoiceGrammar.parse("move me to workspace 1") == .dispatch(.workspace(1)))
        // "move to workspace" still moves the window, not the person.
        #expect(VoiceGrammar.parse("move to workspace 1") == .dispatch(.moveToWorkspace(1)))
        // A question about workspaces is still a question.
        #expect(VoiceGrammar.parse("what workspace am I on") == .unrecognized("what workspace am I on"))
    }

    @Test func longerPrefixWinsOverShorter() {
        // "move to workspace 2" must not be read as move-window with target "to…".
        #expect(VoiceGrammar.parse("move to workspace 2") == .dispatch(.moveToWorkspace(2)))
        #expect(VoiceGrammar.parse("send to workspace 5") == .dispatch(.moveToWorkspace(5)))
    }

    @Test func windowActions() {
        #expect(VoiceGrammar.parse("zoom") == .dispatch(.toggleFullscreen))
        #expect(VoiceGrammar.parse("blow up") == .dispatch(.toggleFullscreen))
        #expect(VoiceGrammar.parse("back to grid") == .dispatch(.toggleFullscreen))
        #expect(VoiceGrammar.parse("close window") == .dispatch(.killActive))
        #expect(VoiceGrammar.parse("float") == .dispatch(.toggleFloating))
        #expect(VoiceGrammar.parse("wider") == .dispatch(.resizeActive(dx: 60, dy: 0)))
        #expect(VoiceGrammar.parse("shorter") == .dispatch(.resizeActive(dx: 0, dy: -60)))
    }

    // MARK: Agent routing

    @Test func tellAgentWithToSeparator() {
        #expect(VoiceGrammar.parse("tell backend to run the tests")
                == .tellAgent(name: "backend", message: "run the tests"))
        // A multi-word agent name is only recoverable via " to ".
        #expect(VoiceGrammar.parse("tell the api server to restart")
                == .tellAgent(name: "the api server", message: "restart"))
    }

    @Test func askAgentWithoutSeparator() {
        #expect(VoiceGrammar.parse("ask nvim what changed")
                == .tellAgent(name: "nvim", message: "what changed"))
    }

    @Test func agentPhraseNeedsBothHalves() {
        #expect(VoiceGrammar.parse("tell") == .unrecognized("tell"))
        #expect(VoiceGrammar.parse("tell backend") == .unrecognized("tell backend"))
    }

    // MARK: Modes

    @Test func modeSwitching() {
        #expect(VoiceGrammar.parse("start dictation") == .setMode(.dictation))
        #expect(VoiceGrammar.parse("stop dictation", mode: .dictation) == .setMode(.command))
        #expect(VoiceGrammar.parse("command mode", mode: .dictation) == .setMode(.command))
    }

    @Test func dictationModePassesTextThroughVerbatim() {
        // Casing and punctuation must survive — this is text being typed.
        #expect(VoiceGrammar.parse("Focus left.", mode: .dictation) == .dictate("Focus left."))
        #expect(VoiceGrammar.parse("git commit -m \"fix\"", mode: .dictation)
                == .dictate("git commit -m \"fix\""))
    }

    @Test func youCanAlwaysTalkYourWayOutOfDictation() {
        // Otherwise dictation is a trap with no voice exit.
        #expect(VoiceGrammar.parse("stop typing", mode: .dictation) == .setMode(.command))
        #expect(VoiceGrammar.parse("cancel", mode: .dictation) == .cancel)
    }

    @Test func unrecognisedSpeechIsReportedNotGuessed() {
        // Silently doing nothing is fine; silently doing the wrong thing is not.
        #expect(VoiceGrammar.parse("the quick brown fox") == .unrecognized("the quick brown fox"))
        #expect(VoiceGrammar.parse("") == .unrecognized(""))
    }

    @Test func goingToAWorkspaceHoweverItIsSaid() {
        // The QA sweep's phrasings, 2 September: two of six hit the old prefix list.
        let ways = ["go to workspace 3", "workspace three", "take me to 3", "switch over to the third workspace",
                    "uh can you put me on workspace 3", "jump to three", "hop over to 3", "can you flip me to the third one",
                    "workspace 3 please", "let's head to space 3"]
        for said in ways { #expect(VoiceGrammar.parse(said) == .dispatch(.workspace(3)), Comment(rawValue: said)) }
        // A window being moved is not the person going; a question is not a command.
        #expect(VoiceGrammar.parse("send this window to workspace 3") == .dispatch(.moveToWorkspace(3)))
        #expect(VoiceGrammar.parse("what workspace am i on") != .dispatch(.workspace(3)))
    }
}
