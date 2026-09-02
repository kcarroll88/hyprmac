import Testing
@testable import HyprCore

@Suite struct RichestTreeTests {
    let full = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(SurfaceID(3013)), second: .leaf(SurfaceID(7598)))

    @Test func aOneLeafRecordLosesToTheFullTree() {
        // 7598 returns second; its own record is a lone leaf, the slot has the pair.
        let best = Tile.richest(of: [.leaf(SurfaceID(7598)), full], containing: SurfaceID(7598), present: [SurfaceID(3013), SurfaceID(7598)])
        #expect(best == full)
    }

    @Test func aTreeWithoutTheWindowIsNoCandidate() {
        #expect(Tile.richest(of: [.leaf(SurfaceID(3013))], containing: SurfaceID(7598), present: [SurfaceID(7598)]) == nil)
    }

    @Test func nothingSurvivingMeansNil() {
        #expect(Tile.richest(of: [nil, nil], containing: SurfaceID(1), present: [SurfaceID(1)]) == nil)
    }
}
