import Foundation

/// Whether macOS's own trackpad gestures are competing with hyprmac's.
///
/// hyprmac reads the trackpad through MultitouchSupport, which *observes* fingers
/// and never consumes an event, so macOS's handler in the WindowServer runs on the
/// same swipe. Three fingers sideways is "switch desktops" and three fingers up is
/// Mission Control; hyprmac uses both for workspaces and the overview. Nothing in
/// the app can intercept that — the only cure is to turn the system's copy off.
///
/// The value macOS stores is a mode, not a flag: 0 is off, 2 means three fingers,
/// 1 means four. So a key set to 2 is precisely the conflict, and a key set to 1
/// has already moved out of the way.
public struct GestureConflict: Equatable, Sendable {
    /// macOS's three-finger horizontal swipe is on: it changes desktop.
    public let horizontal: Bool
    /// macOS's three-finger vertical swipe is on: it opens Mission Control.
    public let vertical: Bool
    /// How many desktops (Spaces) the busiest display has. One desktop means the
    /// horizontal swipe has nowhere to go and the clash is invisible — which is
    /// why this can be missed entirely on the machine hyprmac is written on.
    public let desktops: Int

    /// The settings have been changed since this login session began, so macOS is
    /// still running the old ones. The window server reads them once, at login:
    /// measured here, a session started on 27 August against preferences written on
    /// 1 September — off on disk, still switching desktops on screen. Without this,
    /// hyprmac reads the file, sees the gesture is off, offers nothing, and the user
    /// is left swiping into two window managers with no explanation.
    public let pendingLogout: Bool

    public init(horizontal: Bool, vertical: Bool, desktops: Int, pendingLogout: Bool = false) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.desktops = desktops
        self.pendingLogout = pendingLogout
    }

    /// The mode macOS stores means three fingers when it is 2.
    public static func isThreeFinger(_ mode: Int?) -> Bool { mode == 2 }

    /// Something is worth saying: macOS holds the gesture, or it has been handed
    /// over and the hand-over has not taken effect yet *and* there is a second
    /// desktop for it to still be switching to. A pending change on a Mac with one
    /// desktop changes nothing anybody can see, and saying so every launch until the
    /// user happens to log out is nagging about a problem they do not have.
    public var any: Bool { horizontal || vertical || (pendingLogout && desktops > 1) }

    /// Nothing left to change on disk — the only thing outstanding is the logout.
    public var onlyNeedsLogout: Bool { pendingLogout && !horizontal && !vertical }

    /// Whether the user would actually see something go wrong today. A single
    /// desktop hides the horizontal clash completely; Mission Control shows up
    /// whatever the desktop count.
    public var visible: Bool { vertical || (horizontal && desktops > 1) }

    /// What to tell them, in their terms rather than the setting's.
    public var summary: String {
        if onlyNeedsLogout {
            let base = "macOS has been told to let the three-finger swipe go, but it reads that "
                     + "setting only when you log in — so until you log out and back in, a swipe "
                     + "still changes desktop as well as workspace."
            // The logout is the fix, but there is a faster one when the desktops are
            // the reason it shows: a sideways swipe with nowhere to go does nothing,
            // and hyprmac's workspaces are what those desktops were for.
            guard desktops > 1 else { return base }
            return base + " Or close the other \(desktops - 1) desktop\(desktops > 2 ? "s" : "") "
                 + "in Mission Control — hyprmac's workspaces replace them, and that works at once."
        }
        switch (horizontal, vertical) {
        case (true, true):
            return desktops > 1
                ? "Right now a three-finger swipe does two things at once: hyprmac changes workspace, and macOS changes desktop or opens Mission Control. You have \(desktops) desktops, so you will see both."
                : "A three-finger swipe up opens Mission Control as well as hyprmac's overview, and sideways would change desktop too if you ever add one."
        case (true, false):
            return desktops > 1
                ? "A three-finger swipe sideways changes macOS desktop as well as hyprmac's workspace, and you have \(desktops) desktops."
                : "A three-finger swipe sideways would change macOS desktop as well as hyprmac's workspace, the moment you add a second one."
        case (false, true):
            return "A three-finger swipe up opens Mission Control as well as hyprmac's overview."
        case (false, false):
            return "macOS is not using the three-finger swipe: it is hyprmac's alone."
        }
    }
}
