import Testing
@testable import HyprCore

@Suite("Focus resolution")
struct FocusTargetTests {
    private func workspace(_ ids: [SurfaceID]) -> Workspace {
        var w = Workspace(index: 1)
        for id in ids { w.insert(id, splitting: w.focused, axis: .horizontal) }
        return w
    }

    @Test func usesTheRecordedFocusWhenItIsActuallyHere() {
        var w = workspace([1, 2, 3])
        w.focused = 2
        #expect(w.resolvedFocus == 2)
    }

    @Test func aFocusPointingElsewhereIsNotTrusted() {
        // The bug behind "it moved a window I can't see": an AX notification named
        // a window on another workspace and it became the command target.
        var w = workspace([1, 2, 3])
        w.focused = 99
        #expect(w.resolvedFocus != 99)
        #expect(w.resolvedFocus == 1)
    }

    @Test func fallsBackWhenNothingIsRecorded() {
        var w = workspace([4, 5])
        w.focused = nil
        #expect(w.resolvedFocus == 4)
    }

    @Test func anEmptyWorkspaceHasNoTarget() {
        var w = Workspace(index: 1)
        w.focused = 7
        #expect(w.resolvedFocus == nil)
    }

    @Test func aFloatingWindowCanStillBeTheTarget() {
        var w = Workspace(index: 1)
        w.setFloating(9, .init(x: 0, y: 0, width: 100, height: 100))
        #expect(w.resolvedFocus == 9)
    }

    @Test func removingTheFocusedWindowLeavesAValidTarget() {
        var w = workspace([1, 2, 3])
        w.focused = 2
        w.remove(2)
        let target = w.resolvedFocus
        #expect(target != nil)
        #expect(w.contains(target!))
    }
}
