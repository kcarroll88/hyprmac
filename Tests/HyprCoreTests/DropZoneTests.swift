import Testing
import CoreGraphics
@testable import HyprCore

@Suite("Drop zones") struct DropZoneTests {
    let f = CGRect(x: 100, y: 100, width: 800, height: 600)
    @Test func zones() {
        #expect(DropZone.zone(for: CGPoint(x: 500, y: 400), in: f) == .center)
        #expect(DropZone.zone(for: CGPoint(x: 120, y: 400), in: f) == .left)
        #expect(DropZone.zone(for: CGPoint(x: 880, y: 400), in: f) == .right)
        #expect(DropZone.zone(for: CGPoint(x: 500, y: 110), in: f) == .top)
        #expect(DropZone.zone(for: CGPoint(x: 500, y: 690), in: f) == .bottom)
        // a corner goes to the dominant axis
        #expect(DropZone.zone(for: CGPoint(x: 110, y: 130), in: f) == .left)
    }
    @Test func previewsAreHalves() {
        #expect(DropZone.left.preview(in: f) == CGRect(x: 100, y: 100, width: 400, height: 600))
        #expect(DropZone.bottom.preview(in: f) == CGRect(x: 100, y: 400, width: 800, height: 300))
        #expect(DropZone.center.preview(in: f) == f)
    }
    @Test func moveBesideSplitsTheTarget() {
        var ws = Workspace(index: 1)
        let a = SurfaceID(1), b = SurfaceID(2), c = SurfaceID(3)
        ws.insert(a, splitting: nil, axis: .horizontal); ws.insert(b, splitting: a, axis: .horizontal); ws.insert(c, splitting: b, axis: .horizontal)
        let area = CGRect(x: 0, y: 0, width: 1200, height: 600); let gaps = Gaps(inner: 0, outer: 0)
        ws.move(a, beside: c, axis: .vertical, first: false)     // a goes under c
        let fr = ws.frames(in: area, gaps: gaps)
        #expect(fr[a]!.minY > fr[c]!.minY && fr[a]!.minX == fr[c]!.minX && fr[a]!.width == fr[c]!.width)
        ws.move(a, beside: b, axis: .horizontal, first: true)   // a goes left of b
        let fr2 = ws.frames(in: area, gaps: gaps)
        #expect(fr2[a]!.maxX <= fr2[b]!.minX && fr2[a]!.minY == fr2[b]!.minY)
    }
    // A screen of 1000×1000: a full-height tile on the left, two half-height tiles stacked on the right.
    let L = SurfaceID(10), TR = SurfaceID(11), BR = SurfaceID(12)
    var tiles: [SurfaceID: CGRect] {
        [L: CGRect(x: 0, y: 0, width: 500, height: 1000),
         TR: CGRect(x: 500, y: 0, width: 500, height: 500),
         BR: CGRect(x: 500, y: 500, width: 500, height: 500)]
    }
    func hit(_ w: CGRect, without id: SurfaceID, pushedUp: Bool = false) -> (id: SurfaceID, zone: DropZone)? {
        DropZone.hit(window: w, over: tiles.filter { $0.key != id }, pushedUp: pushedUp)
    }
    @Test func aHalfHeightWindowSlidingDownAFullHeightTile() {
        // The top-right window dragged onto the left column at several heights. The
        // band is ±0.3 of the tile's half-height either side of its middle, so each
        // zone is wide and the window's own size never lands it on a boundary.
        func at(_ top: CGFloat) -> DropZone? { hit(CGRect(x: 0, y: top, width: 500, height: 500), without: TR)?.zone }
        #expect(at(0) == .top)
        #expect(at(50) == .top)
        #expect(at(150) == .center)
        #expect(at(250) == .center)       // aligned with the tile's middle: a swap
        #expect(at(350) == .center)
        #expect(at(450) == .bottom)
        #expect(at(500) == .bottom)       // visibly sitting in the lower half
        #expect(hit(CGRect(x: 0, y: 450, width: 500, height: 500), without: TR)?.id == L)
    }
    @Test func aWindowTheSizeOfItsTargetCanStillReachAHalf() {
        // The regression this rule was written for. Judged by how much of each half
        // the window covered, a window the size of its target had to be hauled a
        // quarter of the screen before either half won a 65/35 majority — which put
        // the halves out of reach, and two windows is exactly the case where each
        // one is half the screen. The centre moves point for point with the drag:
        // a fifth of the tile is enough.
        func at(_ top: CGFloat) -> DropZone? { hit(CGRect(x: 500, y: top, width: 500, height: 500), without: L)?.zone }
        #expect(at(0) == .center)         // square on it: a swap
        #expect(at(50) == .center)
        #expect(at(100) == .bottom)
        #expect(at(150) == .bottom)
        #expect(at(-100) == .top)
    }
    @Test func twoWindowsBecomeHalvesOfTheScreen() {
        // What this is all for: two windows, drop one on the other's side, and each
        // is half the screen. Through the whole path — the zone, then the move — so
        // a drop that reads right but lands wrong cannot pass.
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let gaps = Gaps(inner: 0, outer: 0)
        var ws = Workspace(index: 1)
        let a = SurfaceID(1), b = SurfaceID(2)
        ws.insert(a, splitting: nil, axis: .vertical); ws.insert(b, splitting: a, axis: .vertical)
        let stacked = ws.frames(in: screen, gaps: gaps)
        #expect(stacked[a] == CGRect(x: 0, y: 0, width: 1000, height: 500))
        // Drag a down over b and a fifth of the screen to the left: "that side of it".
        let dragged = stacked[a]!.offsetBy(dx: -200, dy: 500)
        let landing = DropZone.hit(window: dragged, over: [b: stacked[b]!])
        #expect(landing?.id == b && landing?.zone == .left)
        ws.move(a, beside: b, axis: landing!.zone.axis!, first: landing!.zone.placesFirst)
        let halves = ws.frames(in: screen, gaps: gaps)
        #expect(halves[a] == CGRect(x: 0, y: 0, width: 500, height: 1000))
        #expect(halves[b] == CGRect(x: 500, y: 0, width: 500, height: 1000))
    }
    @Test func theTargetIsTheTileCoveredMost() {
        // The tile is chosen by what the window covers — never by the pointer, which
        // rides the title bar and is routinely over the tile above the one meant.
        #expect(hit(CGRect(x: 500, y: 200, width: 500, height: 500), without: L)?.id == TR)
        #expect(hit(CGRect(x: 500, y: 400, width: 500, height: 500), without: L)?.id == BR)
        // Straddling exactly: the tile holding the centre.
        #expect(hit(CGRect(x: 500, y: 250, width: 500, height: 500), without: L)?.id == BR)
    }
    @Test func pinnedUnderTheMenuBarStillReachesAbove() {
        // A full-height window over the right column covers the top-right tile whole
        // on both axes: neither can name a side, so it is a swap — unless the pointer
        // is up in the menu bar, which is the one way to say "above".
        let tall = CGRect(x: 500, y: -17, width: 500, height: 1000)
        #expect(hit(tall, without: L)?.id == TR)
        #expect(hit(tall, without: L)?.zone == .center)
        let pushed = hit(tall, without: L, pushedUp: true)
        #expect(pushed?.id == TR && pushed?.zone == .top)
        // Pushing up over a tile that has another above it means nothing.
        let low = CGRect(x: 500, y: 500, width: 500, height: 500)
        #expect(hit(low, without: L, pushedUp: true)?.zone == .center)
    }
    @Test func offEveryTileFallsBackToTheNearestWithinReach() {
        // Hanging off the bottom: the centre is past the tile, so the clamp puts it
        // on the far edge and the drop reads as below.
        #expect(hit(CGRect(x: 0, y: 780, width: 500, height: 500), without: TR)?.id == L)
        #expect(hit(CGRect(x: 0, y: 780, width: 500, height: 500), without: TR)?.zone == .bottom)
        // Clear of everything by more than the reach: no target at all.
        #expect(hit(CGRect(x: 0, y: 1100, width: 500, height: 500), without: TR) == nil)
    }
    @Test func besideWhereItAlreadyIsIsANoOp() {
        // a over b: putting a above b again changes nothing, so a drop there reads
        // as a swap instead — the backstop for a drop that would leave things as
        // they are, whatever the zone rule made of it.
        var ws = Workspace(index: 1)
        let a = SurfaceID(1), b = SurfaceID(2)
        ws.insert(a, splitting: nil, axis: .vertical); ws.insert(b, splitting: a, axis: .vertical)
        let root = ws.root!
        #expect(root.splits(a, then: b, along: .vertical))
        #expect(!root.splits(b, then: a, along: .vertical))
        #expect(!root.splits(a, then: b, along: .horizontal))
        ws.move(a, beside: b, axis: .vertical, first: true)
        #expect(ws.root == root)
        #expect(ws.root!.swapping(a, b) != root)
    }
}
