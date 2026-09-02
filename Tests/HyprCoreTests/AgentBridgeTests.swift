import Testing
import Foundation
@testable import HyprCore

/// The typed half of the agent bridge: config surface plus the grammar it leans on.
///
/// `VoiceGrammar` already had `.tellAgent` and tests for it, but nothing consumed the
/// case. These cover the parts that make it reachable — registering an agent and binding
/// a key to the prompt.
@Suite("Agent bridge")
struct AgentBridgeTests {

    @Test func registersAgentsByName() {
        let (config, diagnostics) = ConfigParser.parse("""
        agent {
            wisper = wisper://ask?q=
        }
        """)
        #expect(config.agents["wisper"] == "wisper://ask?q=")
        #expect(diagnostics.isEmpty)
    }

    @Test func agentNamesAreCaseInsensitive() {
        // The grammar lowercases what it parses out of an utterance, so the registry has
        // to match on the same footing or "ask Wisper" would find nothing.
        let (config, _) = ConfigParser.parse("""
        agent {
            Wisper = wisper://ask?q=
        }
        """)
        #expect(config.agents["wisper"] != nil)
    }

    @Test func severalAgentsCoexist() {
        let (config, _) = ConfigParser.parse("""
        agent {
            wisper = wisper://ask?q=
            notes  = things://add?title=
        }
        """)
        #expect(config.agents.count == 2)
        #expect(config.agents["notes"] == "things://add?title=")
    }

    @Test func bindsToTheAskDispatcher() {
        let (config, _) = ConfigParser.parse("""
        $mod = ALT
        bind = $mod, P, askagent
        """)
        #expect(config.binds.first?.dispatcher == .askAgent)
    }

    @Test func askIsAcceptedAsAnAlias() {
        #expect(Dispatcher.parse("ask", "") == .askAgent)
        #expect(Dispatcher.parse("askagent", "") == .askAgent)
    }

    @Test func askAgentAppearsInTheCheatsheet() {
        // Every dispatcher has to carry a label and a category or it silently vanishes
        // from the ⌥/ sheet, which is the only discoverability the binding has.
        #expect(Dispatcher.askAgent.label == "Ask an agent")
        #expect(Dispatcher.askAgent.category == "Launch")
    }

    @Test func theGrammarSplitsNameFromMessage() {
        // What the prompt feeds the grammar: the typed text with an "ask " opener, so
        // typed and spoken input converge on one path.
        #expect(VoiceGrammar.parse("ask " + "wisper why is my disk full")
                == .tellAgent(name: "wisper", message: "why is my disk full"))
    }

    @Test func anUnknownSectionIsStillRejected() {
        // The `agent.` prefix opens a namespace; it must not turn every typo into a
        // silently accepted setting.
        let (_, diagnostics) = ConfigParser.parse("""
        agnet {
            wisper = wisper://ask?q=
        }
        """)
        #expect(!diagnostics.isEmpty)
    }
}
