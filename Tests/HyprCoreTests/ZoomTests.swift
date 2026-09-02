import Testing
import CoreGraphics
@testable import HyprCore

@Suite("Zoom")
struct ZoomTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let gaps = Gaps(inner: 10, outer: 20)

    private func workspace() -> Workspace {
        var w = Workspace(index: 1)
        w.insert(1, splitting: nil, axis: .horizontal)
        w.insert(2, splitting: 1, axis: .horizontal)
        w.insert(3, splitting: 2, axis: .vertical)
        return w
    }

    @Test func zoomGivesTheWholeAreaToOneSurface() {
        var w = workspace()
        w.toggleZoom(2)
        let frames = w.frames(in: screen, gaps: gaps)
        #expect(frames.count == 1)
        #expect(frames[2] == screen.inset(by: gaps.outer))
    }

    @Test func unzoomRestoresTheExactGrid() {
        var w = workspace()
        let before = w.frames(in: screen, gaps: gaps)
        w.toggleZoom(2)
        w.toggleZoom(2)
        #expect(w.frames(in: screen, gaps: gaps) == before)
    }

    @Test func zoomingAnotherSurfaceSwitchesRatherThanStacks() {
        var w = workspace()
        w.toggleZoom(2)
        w.toggleZoom(3)
        #expect(w.zoomed == 3)
        #expect(w.frames(in: screen, gaps: gaps).keys.first == 3)
    }

    @Test func aNewWindowDropsOutOfZoom() {
        var w = workspace()
        w.toggleZoom(2)
        w.insert(4, splitting: 2, axis: .horizontal)
        #expect(w.zoomed == nil)
        #expect(w.frames(in: screen, gaps: gaps).count == 4)
    }

    @Test func closingTheZoomedWindowDropsOutOfZoom() {
        var w = workspace()
        w.toggleZoom(2)
        w.remove(2)
        #expect(w.zoomed == nil)
        #expect(w.frames(in: screen, gaps: gaps).count == 2)
    }

    @Test func zoomIsIgnoredForASurfaceNotHere() {
        var w = workspace()
        w.zoomed = 99
        #expect(w.frames(in: screen, gaps: gaps).count == 3)
    }
}
