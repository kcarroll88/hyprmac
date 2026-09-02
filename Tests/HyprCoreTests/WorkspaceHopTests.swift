import Testing
@testable import HyprCore

@Suite("Relative workspace hops")
struct WorkspaceHopTests {
    // The count is a constant now, so these run against the five workspaces the
    // WM actually has rather than a count no config can produce.
    private let c = Config()

    @Test func thereAreFiveWorkspaces() {
        #expect(c.workspaceCount == 5)
    }

    @Test func stepsForwardAndBack() {
        #expect(c.workspace(from: 3, offset: 1) == 4)
        #expect(c.workspace(from: 3, offset: -1) == 2)
    }

    @Test func wrapsAtBothEnds() {
        // Neither bracket key should ever dead-end.
        #expect(c.workspace(from: 5, offset: 1) == 1)
        #expect(c.workspace(from: 1, offset: -1) == 5)
    }

    @Test func wrapsRepeatedly() {
        // More than a full lap in each direction.
        #expect(c.workspace(from: 1, offset: 12) == 3)
        #expect(c.workspace(from: 1, offset: -12) == 4)
    }

    @Test func signDistinguishesRelativeFromAbsolute() {
        let (parsed, diagnostics) = ConfigParser.parse("""
        bind = ALT, bracketright, workspace, +1
        bind = ALT, bracketleft, workspace, -1
        bind = ALT, 3, workspace, 3
        """)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(parsed.binds[0].dispatcher == .workspaceRelative(1))
        #expect(parsed.binds[1].dispatcher == .workspaceRelative(-1))
        // A bare number stays absolute — "+3" and "3" must not mean the same thing.
        #expect(parsed.binds[2].dispatcher == .workspace(3))
    }

    @Test func aZeroHopIsRejectedRatherThanBoundToNothing() {
        let (_, diagnostics) = ConfigParser.parse("bind = ALT, X, workspace, +0")
        #expect(diagnostics.count == 1)
    }

    @Test func gestureSettingsParse() {
        let (parsed, diagnostics) = ConfigParser.parse("""
        gestures {
            enabled = true
            fingers = 4
            threshold = 0.2
            natural = false
        }
        """)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(parsed.gestureFingers == 4)
        #expect(parsed.gestureThreshold == 0.2)
        // `natural = false` means the swipe direction is inverted.
        #expect(parsed.gestureInverted == true)
    }
}
