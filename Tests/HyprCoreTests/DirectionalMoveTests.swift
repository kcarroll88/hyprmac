import Testing
import CoreGraphics
@testable import HyprCore

@Suite("Directional move")
struct DirectionalMoveTests {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    let gaps = Gaps(inner: 12, outer: 16)

    /// The layout that prompted this: the left half is two full-height columns,
    /// the right half is stacked. Nothing sits below `claude`, so a plain
    /// neighbour lookup finds nothing and the old code did nothing at all.
    private let cliamp: SurfaceID = 1163
    private let claude: SurfaceID = 208
    private let safari: SurfaceID = 1127

    private var realLayout: Tile {
        .split(axis: .horizontal, ratio: 0.5,
               first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1163), second: .leaf(208)),
               second: .split(axis: .vertical, ratio: 0.5,
                              first: .leaf(1127),
                              second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1149), second: .leaf(1174))))
    }

    @Test func noTileBelowIsNotANoOp() {
        // The bug: claude spans full height, so nothing is under it.
        #expect(realLayout.neighbor(of: claude, .down, in: screen, gaps: gaps) == nil)
        #expect(realLayout.moving(claude, .down, in: screen, gaps: gaps) != realLayout)
    }

    @Test func movingDownStacksWithTheSibling() {
        let moved = realLayout.moving(claude, .down, in: screen, gaps: gaps)
        let frames = moved.frames(in: screen, gaps: gaps)
        let top = frames[cliamp]!
        let bottom = frames[claude]!

        // Both still occupy the left half...
        #expect(top.maxX < frames[safari]!.minX)
        #expect(bottom.maxX < frames[safari]!.minX)
        // ...now stacked, claude underneath, sharing the same column width.
        #expect(bottom.minY > top.minY)
        #expect(top.width == bottom.width)
        #expect(top.minX == bottom.minX)
    }

    @Test func movingUpStacksTheOtherWay() {
        let moved = realLayout.moving(claude, .up, in: screen, gaps: gaps)
        let frames = moved.frames(in: screen, gaps: gaps)
        #expect(frames[claude]!.minY < frames[cliamp]!.minY)
    }

    @Test func reorientingPreservesEveryoneElse() {
        let moved = realLayout.moving(claude, .down, in: screen, gaps: gaps)
        #expect(Set(moved.surfaces) == Set(realLayout.surfaces))
        // The right-hand half is untouched.
        let before = realLayout.frames(in: screen, gaps: gaps)
        let after = moved.frames(in: screen, gaps: gaps)
        #expect(after[safari] == before[safari])
        #expect(after[1149] == before[1149])
    }

    @Test func aRealNeighbourStillWinsOverReorienting() {
        // safari has tiles below it, so this is an ordinary move, not a flip.
        let moved = realLayout.moving(safari, .down, in: screen, gaps: gaps)
        let frames = moved.frames(in: screen, gaps: gaps)
        #expect(frames[safari]!.minY > frames[1149]!.minY)
    }

    @Test func reorientingIsReversible() {
        // With nothing beside them, a stacked pair pushed sideways becomes columns
        // again — the same rule running in the other direction.
        let stacked = Tile.split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let columns = stacked.moving(2, .right, in: screen, gaps: gaps)
        let frames = columns.frames(in: screen, gaps: gaps)
        #expect(frames[2]!.minX > frames[1]!.minX)
        #expect(frames[2]!.height == frames[1]!.height)
    }

    @Test func aRealNeighbourBeatsReorientingWhenBothArePossible() {
        // Once claude is stacked under cliamp there IS a half-screen to its right,
        // so `right` moves it there rather than flipping the pair back. Moving
        // towards something that exists always wins.
        let stacked = realLayout.moving(claude, .down, in: screen, gaps: gaps)
        let moved = stacked.moving(claude, .right, in: screen, gaps: gaps)
        let frames = moved.frames(in: screen, gaps: gaps)
        #expect(frames[claude]!.minX > frames[cliamp]!.minX)
        // cliamp is left alone with the whole left half.
        #expect(frames[cliamp]!.height > frames[claude]!.height)
    }

    @Test func atTheEdgeItEscapesTheContainer() {
        // Two stacked tiles; pushing the bottom one further down has nowhere to go
        // inside the container, so it spans the whole layout along that edge.
        let tile = Tile.split(axis: .horizontal, ratio: 0.5,
                              first: .split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2)),
                              second: .leaf(3))
        let moved = tile.moving(2, .down, in: screen, gaps: gaps)
        let frames = moved.frames(in: screen, gaps: gaps)
        #expect(frames[2]!.width > frames[1]!.width)
        #expect(frames[2]!.minY > frames[3]!.minY)
    }

    /// Two stacked columns on the left, a single window owning the whole right
    /// half — the layout where the side-by-side default felt wrong.
    private var oneWindowOnTheRight: Tile {
        .split(axis: .horizontal, ratio: 0.5,
               first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1163), second: .leaf(208)),
               second: .leaf(1127))
    }

    @Test func landingInATallHalfStacksRatherThanSplittingItIntoSlivers() {
        // The right half is 1258x1378 — taller than wide. Moving claude into it
        // must stack (two full-width tiles), not carve it into 623pt slivers,
        // even though the push was sideways.
        let moved = oneWindowOnTheRight.moving(claude, .right, in: screen, gaps: gaps)
        let frames = moved.frames(in: screen, gaps: gaps)
        #expect(frames[claude]!.width == frames[safari]!.width)
        #expect(frames[claude]!.width > 1000)
        #expect(frames[claude]!.minY != frames[safari]!.minY)
    }

    @Test func landingInAWideTileStillSplitsSideBySide() {
        // The mirror case: a short wide tile divides into columns. Once the right
        // half already holds a stack, its tiles are wide, so arriving there gives
        // columns — the shape decides, not the direction.
        let moved = realLayout.moving(claude, .right, in: screen, gaps: gaps)
        let frames = moved.frames(in: screen, gaps: gaps)
        #expect(frames[claude]!.height == frames[safari]!.height)
    }

    @Test func neighbourChoiceIsDeterministicWhenDistancesTie() {
        // Every tile in the next column begins at the same edge, so distances tie
        // constantly. The result must not depend on dictionary ordering.
        let answers = Set((0..<50).map { _ in
            realLayout.neighbor(of: claude, .right, in: screen, gaps: gaps)
        })
        #expect(answers.count == 1)
    }

    @Test func tiesBreakTowardsTheTileOnTheSameRow() {
        // A full-height tile on the left, three stacked on the right, all starting
        // at the same x. Moving right should land on the one sharing your top edge
        // rather than whichever the layout happened to enumerate first.
        let tile = Tile.split(axis: .horizontal, ratio: 0.5,
                              first: .leaf(1),
                              second: .split(axis: .vertical, ratio: 0.33,
                                             first: .leaf(2),
                                             second: .split(axis: .vertical, ratio: 0.5,
                                                            first: .leaf(3), second: .leaf(4))))
        #expect(tile.neighbor(of: 1, .right, in: screen, gaps: gaps) == 2)
    }

    @Test func aLoneWindowCannotMove() {
        #expect(Tile.leaf(1).moving(1, .down, in: screen, gaps: gaps) == .leaf(1))
    }

    @Test func movingAnUnknownSurfaceIsIgnored() {
        #expect(realLayout.moving(9999, .down, in: screen, gaps: gaps) == realLayout)
    }
}

@Suite("Move preserves size")
struct MoveSizeTests {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    let gaps = Gaps(inner: 12, outer: 16)

    @Test func escapingTheContainerKeepsRoughlyTheSameWidth() {
        // Ghostty at half the left half, pushed left past the edge. It should come
        // out about the width it went in at, not some fixed fraction.
        let tile = Tile.split(axis: .horizontal, ratio: 0.5,
                              first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)),
                              second: .leaf(3))
        let before = tile.frames(in: screen, gaps: gaps)[1]!.width
        let moved = tile.moving(1, .left, in: screen, gaps: gaps)
        let after = moved.frames(in: screen, gaps: gaps)[1]!.width
        #expect(abs(after - before) < 40, "went in at \(before), came out at \(after)")
    }

    @Test func escapingKeepsHeightWhenMovingVertically() {
        let tile = Tile.split(axis: .vertical, ratio: 0.5,
                              first: .split(axis: .vertical, ratio: 0.5, first: .leaf(1), second: .leaf(2)),
                              second: .leaf(3))
        let before = tile.frames(in: screen, gaps: gaps)[1]!.height
        let after = tile.moving(1, .up, in: screen, gaps: gaps).frames(in: screen, gaps: gaps)[1]!.height
        #expect(abs(after - before) < 40)
    }

    @Test func repeatedMovesDoNotShrinkAWindowAway() {
        // The actual complaint: rearrange a few times and one window ends up a
        // sliver. Bounce it back and forth and it must stay usable.
        var tile = Tile.split(axis: .horizontal, ratio: 0.5,
                              first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2)),
                              second: .leaf(3))
        for _ in 0..<6 {
            tile = tile.moving(1, .left, in: screen, gaps: gaps)
            tile = tile.moving(1, .right, in: screen, gaps: gaps)
        }
        let width = tile.frames(in: screen, gaps: gaps)[1]!.width
        #expect(width > 400, "collapsed to \(width)")
    }

    @Test func anExtremeStartingSizeIsClamped() {
        // A window already at 5% should not escape into a 5% sliver either.
        let tile = Tile.split(axis: .horizontal, ratio: 0.05, first: .leaf(1), second: .leaf(2))
        let moved = tile.moving(1, .left, in: screen, gaps: gaps)
        let width = moved.frames(in: screen, gaps: gaps)[1]!.width
        #expect(width > screen.width * 0.15)
    }
}

@Suite("A move must not rearrange windows you did not touch")
struct MoveContainmentTests {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    let gaps = Gaps(inner: 12, outer: 16)

    /// Two stacked on the left, one full-height column on the right — the layout
    /// that collapsed into a single vertical stack.
    private let claude: SurfaceID = 1272
    private let safari: SurfaceID = 1127
    private let ghostty: SurfaceID = 208

    private var layout: Tile {
        .split(axis: .horizontal, ratio: 0.5,
               first: .split(axis: .vertical, ratio: 0.5, first: .leaf(1272), second: .leaf(1127)),
               second: .leaf(208))
    }

    /// True when every tile shares a column or every tile shares a row.
    private func isColinear(_ tile: Tile, in rect: CGRect) -> Bool {
        let frames = Array(tile.frames(in: rect, gaps: gaps).values)
        guard frames.count > 2 else { return false }
        let sameColumn = frames.allSatisfy { abs($0.minX - frames[0].minX) < 1 }
        let sameRow = frames.allSatisfy { abs($0.minY - frames[0].minY) < 1 }
        return sameColumn || sameRow
    }

    @Test func movingAColumnVerticallyDoesNotStackEverything() {
        for direction in [Direction.down, .up] {
            let moved = layout.moving(ghostty, direction, in: screen, gaps: gaps)
            #expect(!isColinear(moved, in: screen),
                    "moving \(direction.rawValue) collapsed the layout into one axis")
        }
    }

    @Test func untouchedWindowsKeepTheirShape() {
        // The heart of the complaint: moving one window resized two others. Claude
        // and Safari own the left half; moving Ghostty must leave them there.
        let before = layout.frames(in: screen, gaps: gaps)
        for direction in [Direction.down, .up] {
            let after = layout.moving(ghostty, direction, in: screen, gaps: gaps)
                .frames(in: screen, gaps: gaps)
            #expect(after[claude]?.width == before[claude]?.width,
                    "moving \(direction.rawValue) resized claude")
            #expect(after[safari]?.width == before[safari]?.width,
                    "moving \(direction.rawValue) resized safari")
        }
    }

    @Test func flippingAGenuinePairIsStillAllowed() {
        // Claude and Safari are a real pair, so un-stacking them into columns
        // stays available — that is the escape hatch, not a bug.
        let moved = layout.moving(safari, .left, in: screen, gaps: gaps)
        let frames = moved.frames(in: screen, gaps: gaps)
        #expect(frames[safari]!.height == frames[claude]!.height)
        #expect(frames[safari]!.minX < frames[claude]!.minX)
        // And Ghostty keeps the right half throughout.
        #expect(frames[ghostty]!.width == layout.frames(in: screen, gaps: gaps)[ghostty]!.width)
    }

    @Test func windowsYouDidNotTouchKeepTheirRelativeOrder() {
        // Moving Ghostty must never reorder Claude above/below Safari.
        let before = layout.frames(in: screen, gaps: gaps)
        for direction in Direction.allCases {
            let after = layout.moving(ghostty, direction, in: screen, gaps: gaps)
                .frames(in: screen, gaps: gaps)
            guard let c = after[claude], let s = after[safari] else { continue }
            #expect((before[claude]!.minY < before[safari]!.minY) == (c.minY < s.minY),
                    "moving \(direction.rawValue) swapped two untouched windows")
        }
    }

    @Test func everySurfaceSurvivesEveryMove() {
        for id in [claude, safari, ghostty] {
            for direction in Direction.allCases {
                let moved = layout.moving(id, direction, in: screen, gaps: gaps)
                #expect(Set(moved.surfaces) == Set(layout.surfaces))
            }
        }
    }
}
