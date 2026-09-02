import Testing
import CoreGraphics
@testable import HyprCore

@Suite("Drag to swap") struct DragSwapTests {
    @Test func tileUnderAPoint() {
        var ws = Workspace(index: 1)
        let a = SurfaceID(1), b = SurfaceID(2)
        ws.insert(a, splitting: nil, axis: .horizontal)
        ws.insert(b, splitting: a, axis: .horizontal)
        let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frames = ws.frames(in: area, gaps: Gaps(inner: 12, outer: 16))
        let inA = CGPoint(x: frames[a]!.midX, y: frames[a]!.midY), inB = CGPoint(x: frames[b]!.midX, y: frames[b]!.midY)
        #expect(ws.tile(at: inA, in: area, gaps: Gaps(inner: 12, outer: 16)) == a)
        #expect(ws.tile(at: inB, in: area, gaps: Gaps(inner: 12, outer: 16), excluding: b) == nil)   // the dragged window is not a target
        #expect(ws.tile(at: CGPoint(x: -5, y: -5), in: area, gaps: Gaps(inner: 12, outer: 16)) == nil)
    }

    @Test func swappingKeepsTheShape() {
        var ws = Workspace(index: 1)
        let a = SurfaceID(1), b = SurfaceID(2), c = SurfaceID(3)
        ws.insert(a, splitting: nil, axis: .horizontal); ws.insert(b, splitting: a, axis: .horizontal); ws.insert(c, splitting: b, axis: .vertical)
        let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let before = ws.frames(in: area, gaps: Gaps(inner: 12, outer: 16))
        ws.root = ws.root?.swapping(a, c)
        let after = ws.frames(in: area, gaps: Gaps(inner: 12, outer: 16))
        #expect(after[a] == before[c] && after[c] == before[a] && after[b] == before[b])
    }
}
