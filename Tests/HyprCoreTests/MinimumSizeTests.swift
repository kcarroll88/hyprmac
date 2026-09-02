import Testing
import CoreGraphics
@testable import HyprCore

@Suite("Minimum sizes") struct MinimumSizeTests {
    let discord = SurfaceID(1), ghostty = SurfaceID(2)

    @Test func aWindowThatShrinksSaysNothing() {
        var m = MinimumSizes()
        let same = m.note(ghostty, asked: CGSize(width: 400, height: 300), got: CGSize(width: 400, height: 300))
        #expect(same == false)
        #expect(m.minimum(for: ghostty) == nil)
        #expect(m.fits(ghostty, in: CGSize(width: 10, height: 10)))
        // Rounding to the app's own grid is not a refusal.
        let rounded = m.note(ghostty, asked: CGSize(width: 400, height: 300), got: CGSize(width: 403, height: 302))
        #expect(rounded == false)
    }

    @Test func aWindowThatKeepsMoreThanItWasGivenNamesItsFloor() {
        var m = MinimumSizes()
        // Discord asked for a 412×251 tile, kept 800×500.
        let refused = m.note(discord, asked: CGSize(width: 412, height: 251), got: CGSize(width: 800, height: 500))
        #expect(refused)
        #expect(m.minimum(for: discord) == CGSize(width: 800, height: 500))
        #expect(!m.fits(discord, in: CGSize(width: 412, height: 251)))
        #expect(!m.fits(discord, in: CGSize(width: 780, height: 900)))
        // Within the slack counts as fitting: a couple of points is rounding.
        #expect(m.fits(discord, in: CGSize(width: 797, height: 498)))
        #expect(m.fits(discord, in: CGSize(width: 800, height: 500)))
        #expect(m.fits(discord, in: CGSize(width: 1678, height: 1042)))
    }

    @Test func onlyTheAxisItRefusedOnCounts() {
        var m = MinimumSizes()
        // Given a tile too narrow but tall enough: it keeps its width, takes the height.
        let tooNarrow = m.note(discord, asked: CGSize(width: 200, height: 900), got: CGSize(width: 800, height: 900))
        #expect(tooNarrow)
        #expect(m.minimum(for: discord) == CGSize(width: 800, height: 0))
        // Tall enough is still tall enough — the height was never a floor.
        #expect(m.fits(discord, in: CGSize(width: 900, height: 120)))
        #expect(!m.fits(discord, in: CGSize(width: 300, height: 900)))
        // Later, a tile too short teaches the other axis.
        let tooShort = m.note(discord, asked: CGSize(width: 900, height: 100), got: CGSize(width: 900, height: 500))
        #expect(tooShort)
        #expect(m.minimum(for: discord) == CGSize(width: 800, height: 500))
    }

    @Test func aFloorOnlyEverGrows() {
        var m = MinimumSizes()
        _ = m.note(discord, asked: CGSize(width: 100, height: 100), got: CGSize(width: 800, height: 500))
        _ = m.note(discord, asked: CGSize(width: 100, height: 100), got: CGSize(width: 600, height: 400))
        #expect(m.minimum(for: discord) == CGSize(width: 800, height: 500))
        m.forget(discord)
        #expect(m.minimum(for: discord) == nil)
    }
}
