import Testing
@testable import HyprCore

@Suite struct TileShorthandTests {
    @Test func leafIsItsId() {
        #expect(Tile.leaf(SurfaceID(7)).shorthand == "7")
    }

    @Test func splitsReadLeftToRightAndTopToBottom() {
        let stack = Tile.split(axis: .vertical, ratio: 0.5, first: .leaf(SurfaceID(2)), second: .leaf(SurfaceID(3)))
        let tree = Tile.split(axis: .horizontal, ratio: 0.5, first: .leaf(SurfaceID(1)), second: stack)
        #expect(tree.shorthand == "1 | (2 / 3)")
    }
}
