import Testing
@testable import HyprCore

@Suite("Workspace names")
struct WorkspaceNameTests {
    @Test func numericKeysInsideTheSectionNameWorkspaces() {
        let (config, diagnostics) = ConfigParser.parse("""
        workspaces {
            1 = wisp
            2 = notes
            4 = scratch
        }
        """)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(config.workspaceNames == [1: "wisp", 2: "notes", 4: "scratch"])
    }

    @Test func theRetiredCountKeyExplainsItselfRatherThanReadingAsATypo() {
        // Every config written before the count was fixed still has this line, so
        // it has to say what happened — not "unknown setting", which sounds like
        // the user mistyped something they never typed.
        let (config, diagnostics) = ConfigParser.parse("workspaces {\n count = 9\n}")
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("was removed") == true)
        #expect(config.workspaceCount == 5, "a stale count must not raise the real one")
    }

    @Test func namesMayContainSpaces() {
        let (config, _) = ConfigParser.parse("workspaces {\n 3 = client work\n}")
        #expect(config.workspaceNames[3] == "client work")
    }

    @Test func anEmptyNameClearsRatherThanStoringBlank() {
        let (config, _) = ConfigParser.parse("workspaces {\n 3 = wisp\n 3 = \n}")
        #expect(config.workspaceNames[3] == nil)
    }

    @Test func labelFallsBackToTheNumber() {
        var config = Config()
        config.workspaceNames = [2: "notes"]
        #expect(config.workspaceLabel(2) == "notes")
        #expect(config.workspaceLabel(7) == "7")
    }

    @Test func lookupByNameIsCaseInsensitive() {
        var config = Config()
        config.workspaceNames = [1: "Wisp", 2: "notes"]
        #expect(config.workspaceIndex(named: "wisp") == 1)
        #expect(config.workspaceIndex(named: "  NOTES ") == 2)
        #expect(config.workspaceIndex(named: "nothing") == nil)
    }

    @Test func bindsAcceptEitherANumberOrAName() {
        let (config, diagnostics) = ConfigParser.parse("""
        bind = ALT, 1, workspace, 1
        bind = ALT, B, workspace, backend
        bind = ALT SHIFT, B, movetoworkspace, backend
        """)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(config.binds[0].dispatcher == .workspace(1))
        #expect(config.binds[1].dispatcher == .workspaceNamed("backend"))
        #expect(config.binds[2].dispatcher == .moveToWorkspaceNamed("backend"))
    }

    @Test func aBindWithNoWorkspaceArgumentIsRejected() {
        let (_, diagnostics) = ConfigParser.parse("bind = ALT, B, workspace")
        #expect(diagnostics.count == 1)
    }
}
