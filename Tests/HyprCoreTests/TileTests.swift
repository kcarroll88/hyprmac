import Testing
import CoreGraphics
@testable import HyprCore

@Suite("Dwindle layout")
struct TileTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let noGaps = Gaps(inner: 0, outer: 0)

    // MARK: Frames

    @Test func singleWindowFillsScreenMinusOuterGap() {
        let frames = Tile.leaf(1).frames(in: screen, gaps: Gaps(inner: 0, outer: 10))
        #expect(frames[1] == CGRect(x: 10, y: 10, width: 980, height: 780))
    }

    @Test func horizontalSplitDividesWidth() {
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let frames = tile.frames(in: screen, gaps: noGaps)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(frames[2] == CGRect(x: 500, y: 0, width: 500, height: 800))
    }

    @Test func verticalSplitDividesHeight() {
        let tile = Tile.split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let frames = tile.frames(in: screen, gaps: noGaps)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 400))
        #expect(frames[2] == CGRect(x: 0, y: 400, width: 1000, height: 400))
    }

    @Test func innerGapIsSplitBetweenNeighbours() {
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let frames = tile.frames(in: screen, gaps: Gaps(inner: 10, outer: 0))
        // 5pt comes off each side of the shared edge, leaving one 10pt channel.
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 495, height: 800))
        #expect(frames[2]!.minX - frames[1]!.maxX == 10)
    }

    @Test func framesNeverOverlap() {
        var tile = Tile.leaf(1)
        for id in 2...8 {
            tile = tile.inserting(SurfaceID(UInt64(id)), splitting: SurfaceID(UInt64(id - 1)),
                                  axis: id.isMultiple(of: 2) ? .horizontal : .vertical)
        }
        let rects = Array(tile.frames(in: screen, gaps: Gaps(inner: 4, outer: 8)).values)
        for i in rects.indices {
            for j in (i + 1)..<rects.count {
                #expect(rects[i].intersection(rects[j]).isEmpty, "\(rects[i]) overlaps \(rects[j])")
            }
        }
    }

    @Test func everyTileStaysInsideTheScreen() {
        var tile = Tile.leaf(1)
        for id in 2...10 { tile = tile.inserting(SurfaceID(UInt64(id)), splitting: nil, axis: .horizontal) }
        for (id, rect) in tile.frames(in: screen, gaps: Gaps(inner: 6, outer: 12)) {
            #expect(screen.contains(rect), "\(id) at \(rect) escapes the screen")
        }
    }

    // MARK: Insertion and removal

    @Test func dwindleInsertSplitsTheFocusedTile() {
        #expect(Tile.leaf(1).inserting(2, splitting: 1, axis: .horizontal)
                == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)))
    }

    @Test func insertWithNoTargetAppendsToLastLeaf() {
        let tile = Tile.leaf(1)
            .inserting(2, splitting: nil, axis: .horizontal)
            .inserting(3, splitting: nil, axis: .vertical)
        #expect(tile.surfaces == [1, 2, 3])
    }

    @Test func staleFocusStillAddsTheWindow() {
        #expect(Tile.leaf(1).inserting(2, splitting: 99, axis: .horizontal).contains(2))
    }

    @Test func removePromotesSibling() {
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        #expect(tile.removing(1) == .leaf(2))
    }

    @Test func removingLastSurfaceEmptiesTree() {
        #expect(Tile.leaf(1).removing(1) == nil)
    }

    @Test func removeKeepsRemainingLayoutValid() {
        var tile = Tile.leaf(1)
        for id in 2...5 { tile = tile.inserting(SurfaceID(UInt64(id)), splitting: nil, axis: .horizontal) }
        let pruned = tile.removing(3)
        #expect(pruned?.surfaces == [1, 2, 4, 5])
        #expect(pruned?.contains(3) == false)
    }

    @Test func swapExchangesPositionsNotShape() {
        let tile = Tile.split(axis: .horizontal, ratio: 0.3, first: .leaf(1), second: .leaf(2))
        #expect(tile.swapping(1, 2) == .split(axis: .horizontal, ratio: 0.3, first: .leaf(2), second: .leaf(1)))
    }

    // MARK: Resize

    @Test func resizeGrowsTheFocusedTile() {
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let frames = tile.adjustingRatio(containing: 1, axis: .horizontal, by: 0.1).frames(in: screen, gaps: noGaps)
        #expect(frames[1]!.width == 600)
        #expect(frames[2]!.width == 400)
    }

    @Test func resizingSecondChildGrowsThatChild() {
        // Growing the right-hand tile must move the divider left, not right.
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let frames = tile.adjustingRatio(containing: 2, axis: .horizontal, by: 0.1).frames(in: screen, gaps: noGaps)
        #expect(frames[2]!.width == 600)
        #expect(frames[1]!.width == 400)
    }

    @Test func resizeIsClampedSoNoTileVanishes() {
        var tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        for _ in 0..<20 { tile = tile.adjustingRatio(containing: 1, axis: .horizontal, by: -0.5) }
        let frames = tile.frames(in: screen, gaps: noGaps)
        #expect(frames[1]!.width > 0)
        #expect(frames[2]!.width > 0)
    }

    @Test func resizeOnLoneWindowIsNoOp() {
        #expect(Tile.leaf(1).adjustingRatio(containing: 1, axis: .horizontal, by: 0.2) == .leaf(1))
    }

    @Test func resizeSkipsAncestorsOfTheWrongAxis() {
        // 1 sits inside a vertical split; a horizontal resize must walk up to the
        // horizontal ancestor rather than doing nothing.
        let tile = Tile.split(axis: .horizontal, ratio: 0.5,
                              first: .split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2)),
                              second: .leaf(3))
        let frames = tile.adjustingRatio(containing: 1, axis: .horizontal, by: 0.1).frames(in: screen, gaps: noGaps)
        #expect(frames[3]!.width == 400)
    }

    @Test func toggleSplitFlipsOrientation() {
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        #expect(tile.togglingSplit(containing: 1)
                == .split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2)))
    }

    // MARK: Directional focus

    /// 1 | 2
    /// -----
    /// 3 | 4
    private var grid: Tile {
        .split(axis: .vertical, ratio: 0.5,
               first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)),
               second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(3), second: .leaf(4)))
    }

    @Test func neighborInEachDirection() {
        let gaps = Gaps(inner: 4, outer: 4)
        #expect(grid.neighbor(of: 1, .right, in: screen, gaps: gaps) == 2)
        #expect(grid.neighbor(of: 2, .left, in: screen, gaps: gaps) == 1)
        #expect(grid.neighbor(of: 1, .down, in: screen, gaps: gaps) == 3)
        #expect(grid.neighbor(of: 3, .up, in: screen, gaps: gaps) == 1)
        #expect(grid.neighbor(of: 4, .left, in: screen, gaps: gaps) == 3)
    }

    @Test func noNeighborAtTheScreenEdge() {
        let gaps = Gaps(inner: 4, outer: 4)
        #expect(grid.neighbor(of: 1, .left, in: screen, gaps: gaps) == nil)
        #expect(grid.neighbor(of: 1, .up, in: screen, gaps: gaps) == nil)
        #expect(grid.neighbor(of: 4, .down, in: screen, gaps: gaps) == nil)
    }

    @Test func neighborRequiresPerpendicularOverlap() {
        // 1 spans the full height on the left; 2 over 3 on the right.
        let tile = Tile.split(axis: .horizontal, ratio: 0.5,
                              first: .leaf(1),
                              second: .split(axis: .vertical, ratio: 0.5, first: .leaf(2), second: .leaf(3)))
        #expect(tile.neighbor(of: 2, .up, in: screen, gaps: noGaps) == nil)
        #expect(tile.neighbor(of: 2, .down, in: screen, gaps: noGaps) == 3)
        #expect(tile.neighbor(of: 3, .left, in: screen, gaps: noGaps) == 1)
    }

    @Test func neighborPicksTheNearestCandidate() {
        // Three columns: from 1, moving right must land on 2, never 3.
        let tile = Tile.split(axis: .horizontal, ratio: 0.33,
                              first: .leaf(1),
                              second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(2), second: .leaf(3)))
        #expect(tile.neighbor(of: 1, .right, in: screen, gaps: noGaps) == 2)
    }
}

@Suite("Move versus swap")
struct MoveTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let noGaps = Gaps(inner: 0, outer: 0)

    /// 1 spans the left; 2 over 3 on the right.
    private var layout: Tile {
        .split(axis: .horizontal, ratio: 0.5,
               first: .leaf(1),
               second: .split(axis: .vertical, ratio: 0.5, first: .leaf(2), second: .leaf(3)))
    }

    @Test func insertPlacesOnTheRequestedSide() {
        #expect(Tile.leaf(1).inserting(2, splitting: 1, axis: .horizontal, placeFirst: true)
                == .split(axis: .horizontal, ratio: 0.5, first: .leaf(2), second: .leaf(1)))
        #expect(Tile.leaf(1).inserting(2, splitting: 1, axis: .horizontal, placeFirst: false)
                == .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)))
    }

    @Test func swapTradesPlacesAndKeepsShape() {
        // 1 takes the whole left column, 2 drops into the top-right cell.
        let swapped = layout.swapping(1, 2)
        let frames = swapped.frames(in: screen, gaps: noGaps)
        #expect(frames[2] == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(frames[1] == CGRect(x: 500, y: 0, width: 500, height: 400))
    }

    @Test func moveRelocatesRatherThanTrading() {
        // Moving 1 right should put it beside 2 — and, unlike a swap, leave nothing
        // of 1 in the left column: 3 grows to claim the vacated space.
        let pruned = layout.removing(1)!
        let moved = pruned.inserting(1, splitting: 2, axis: .horizontal, placeFirst: false)
        #expect(moved.surfaces.count == 3)
        let frames = moved.frames(in: screen, gaps: noGaps)
        // 3 now owns the full bottom half rather than a quarter.
        #expect(frames[3]!.width == 1000)
        // 1 sits to the right of 2, not on top of where it used to be.
        #expect(frames[1]!.minX > frames[2]!.minX)
    }

    @Test func moveLeftLandsOnTheLeftOfTheNeighbour() {
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let moved = tile.removing(2)!.inserting(2, splitting: 1, axis: .horizontal, placeFirst: true)
        let frames = moved.frames(in: screen, gaps: noGaps)
        #expect(frames[2]!.minX < frames[1]!.minX)
    }

    // MARK: Point-accurate resize

    @Test func resizeMovesTheDividerByTheRequestedPoints() {
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let frames = tile.adjustingSplit(containing: 1, axis: .horizontal, byPoints: 60,
                                         in: screen, gaps: noGaps).frames(in: screen, gaps: noGaps)
        #expect(frames[1]!.width == 560)
    }

    @Test func resizeIsAccurateInsideANestedSplit() {
        // 2 lives in the right half, so its governing split is 500pt wide, not 1000.
        // The old ratio-of-the-screen maths moved this divider 30pt for a 60pt ask.
        let frames = layout.adjustingSplit(containing: 2, axis: .vertical, byPoints: 60,
                                           in: screen, gaps: noGaps).frames(in: screen, gaps: noGaps)
        #expect(frames[2]!.height == 460)
    }

    @Test func resizeAcrossTheWrongAxisFindsTheRightAncestor() {
        let frames = layout.adjustingSplit(containing: 2, axis: .horizontal, byPoints: 100,
                                           in: screen, gaps: noGaps).frames(in: screen, gaps: noGaps)
        // 2 is the `second` child horizontally, so growing it eats into 1.
        #expect(frames[1]!.width == 400)
        #expect(frames[2]!.width == 600)
    }

    @Test func resizeWithNoMatchingAncestorIsANoOp() {
        // Two side-by-side windows have no vertical split to adjust; asking for a
        // height change must leave the tree untouched rather than corrupt it.
        let tile = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        #expect(tile.adjustingSplit(containing: 1, axis: .vertical, byPoints: 60,
                                    in: screen, gaps: noGaps) == tile)
    }
}
