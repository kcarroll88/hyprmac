import Testing
import CoreGraphics
@testable import HyprCore

@Suite("Divider hit-testing")
struct DividerTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let gaps = Gaps(inner: 12, outer: 16)

    private let twoColumns = Tile.split(axis: .horizontal, ratio: 0.5,
                                        first: .leaf(1), second: .leaf(2))

    @Test func findsTheDividerInTheGap() {
        let frames = twoColumns.frames(in: screen, gaps: gaps)
        let middle = (frames[1]!.maxX + frames[2]!.minX) / 2
        let hit = twoColumns.divider(at: CGPoint(x: middle, y: 400), in: screen, gaps: gaps)
        #expect(hit?.axis == .horizontal)
        #expect(hit?.path == [])
    }

    @Test func missesWhenWellInsideATile() {
        #expect(twoColumns.divider(at: CGPoint(x: 200, y: 400), in: screen, gaps: gaps) == nil)
        #expect(twoColumns.divider(at: CGPoint(x: 800, y: 400), in: screen, gaps: gaps) == nil)
    }

    @Test func missesOutsideTheSplitsOwnBand() {
        // The vertical divider only exists across the rows it separates.
        let nested = Tile.split(axis: .vertical, ratio: 0.5,
                                first: .leaf(1),
                                second: .split(axis: .horizontal, ratio: 0.5,
                                               first: .leaf(2), second: .leaf(3)))
        let frames = nested.frames(in: screen, gaps: gaps)
        let innerX = (frames[2]!.maxX + frames[3]!.minX) / 2
        // In the bottom half: hits. In the top half: that divider isn't there.
        #expect(nested.divider(at: CGPoint(x: innerX, y: 600), in: screen, gaps: gaps)?.path == [true])
        #expect(nested.divider(at: CGPoint(x: innerX, y: 100), in: screen, gaps: gaps) == nil)
    }

    @Test func prefersTheDeepestDivider() {
        // Where an inner and outer divider nearly coincide, dragging should move
        // the inner one — the one you can actually see under the cursor.
        let nested = Tile.split(axis: .horizontal, ratio: 0.5,
                                first: .leaf(1),
                                second: .split(axis: .vertical, ratio: 0.5,
                                               first: .leaf(2), second: .leaf(3)))
        let frames = nested.frames(in: screen, gaps: gaps)
        let innerY = (frames[2]!.maxY + frames[3]!.minY) / 2
        let hit = nested.divider(at: CGPoint(x: 800, y: innerY), in: screen, gaps: gaps)
        #expect(hit?.path == [true])
        #expect(hit?.axis == .vertical)
    }

    @Test func draggingSetsTheRatioWithinTheSplitsOwnBounds() {
        let hit = twoColumns.divider(at: CGPoint(x: 508, y: 400), in: screen, gaps: gaps)!
        // Drag to 30% across the split's bounds, not the screen.
        let ratio = (0.3 * hit.bounds.width) / hit.bounds.width
        let resized = twoColumns.settingRatio(at: hit.path, to: ratio)
        let frames = resized.frames(in: screen, gaps: gaps)
        #expect(frames[1]!.width < frames[2]!.width)
    }

    @Test func ratioIsClampedSoATileCannotVanish() {
        let resized = twoColumns.settingRatio(at: [], to: -5)
        let frames = resized.frames(in: screen, gaps: gaps)
        #expect(frames[1]!.width > 0)
        #expect(frames[2]!.width > 0)
    }

    @Test func aLoneWindowHasNoDividers() {
        #expect(Tile.leaf(1).divider(at: CGPoint(x: 500, y: 400), in: screen, gaps: gaps) == nil)
    }
}
