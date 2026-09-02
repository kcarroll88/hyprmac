import Testing
@testable import HyprCore

@Suite("Gesture conflict") struct GestureConflictTests {
    @Test func theStoredValueIsAModeNotAFlag() {
        #expect(GestureConflict.isThreeFinger(2))       // three fingers: the clash
        #expect(!GestureConflict.isThreeFinger(1))      // four fingers: already out of the way
        #expect(!GestureConflict.isThreeFinger(0))      // off
        #expect(!GestureConflict.isThreeFinger(nil))    // never set
    }

    @Test func oneDesktopHidesTheHorizontalClash() {
        // The machine hyprmac is written on: the swipe is on, but there is nowhere
        // for macOS to swipe to, so it looks like it works perfectly.
        let quiet = GestureConflict(horizontal: true, vertical: false, desktops: 1)
        #expect(quiet.any)          // still worth offering to fix
        #expect(!quiet.visible)     // but nothing is going wrong yet
        let loud = GestureConflict(horizontal: true, vertical: false, desktops: 3)
        #expect(loud.visible)
        #expect(loud.summary.contains("3 desktops"))
    }

    @Test func missionControlShowsWhateverTheDesktopCount() {
        let vertical = GestureConflict(horizontal: false, vertical: true, desktops: 1)
        #expect(vertical.visible)
        #expect(vertical.summary.contains("Mission Control"))
    }

    @Test func offOnDiskAndStillRunningIsWorthSaying() {
        // Written after login: the file says off, the window server says otherwise.
        let pending = GestureConflict(horizontal: false, vertical: false, desktops: 2, pendingLogout: true)
        #expect(pending.any)
        #expect(pending.onlyNeedsLogout)
        #expect(pending.summary.contains("log out"))
        // Once the session has caught up there is nothing left to say.
        let settled = GestureConflict(horizontal: false, vertical: false, desktops: 2, pendingLogout: false)
        #expect(!settled.any)
    }

    @Test func theFasterWayOutIsOfferedWhenDesktopsAreTheReason() {
        // One desktop: the logout is the only thing left to say.
        let single = GestureConflict(horizontal: false, vertical: false, desktops: 1, pendingLogout: true)
        #expect(single.summary.contains("log out"))
        #expect(!single.summary.contains("Mission Control"))
        // More than one: closing them works now, where the logout is later.
        let many = GestureConflict(horizontal: false, vertical: false, desktops: 3, pendingLogout: true)
        #expect(many.summary.contains("close the other 2 desktops"))
        let two = GestureConflict(horizontal: false, vertical: false, desktops: 2, pendingLogout: true)
        #expect(two.summary.contains("close the other 1 desktop"))
        #expect(!two.summary.contains("desktops in Mission"))
    }

    @Test func nothingOnIsNothingToSay() {
        let clear = GestureConflict(horizontal: false, vertical: false, desktops: 4)
        #expect(!clear.any && !clear.visible)
        #expect(clear.summary.contains("hyprmac's alone"))
    }
}
