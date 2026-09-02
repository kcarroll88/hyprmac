import Testing
import Foundation
@testable import HyprCore

/// A workspace arranged with care must come back the same after a restart. The
/// session used to remember only which workspace a window lived on, and the
/// tree was rebuilt in discovery order — a different shape every launch.
@Suite("Layout restore")
struct LayoutRestoreTests {
    private let saved: Tile = .split(axis: .horizontal, ratio: 0.6,
                                     first: .leaf(1),
                                     second: .split(axis: .vertical, ratio: 0.3, first: .leaf(2), second: .leaf(3)))

    @Test func treeSurvivesJSON() throws {
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(Tile.self, from: data) == saved)
    }

    @Test func pruningKeepsShapeAndRatios() {
        // Window 2 has not been discovered yet: its sibling is promoted, and the
        // outer split keeps its ratio exactly.
        let partial = saved.pruned(keeping: [1, 3])
        #expect(partial == .split(axis: .horizontal, ratio: 0.6, first: .leaf(1), second: .leaf(3)))
    }

    @Test func discoveryInAnyOrderConvergesOnTheSavedTree() {
        // Every arrival rebuilds from the saved tree pruned to what is present, so
        // the order windows are found in cannot matter.
        for order in [[1, 2, 3], [3, 1, 2], [2, 3, 1]] {
            var present: Set<SurfaceID> = []
            var tree: Tile?
            for raw in order {
                present.insert(SurfaceID(UInt64(raw)))
                tree = saved.pruned(keeping: present)
            }
            #expect(tree == saved, "order \(order)")
        }
    }

    @Test func pruningEverythingIsNil() {
        #expect(saved.pruned(keeping: [9]) == nil)
    }

    @Test func aSessionWrittenBeforeLayoutsExistedStillLoads() throws {
        let legacy = """
        {"activeWorkspace": 3, "windows": [{"id": 7, "bundleID": "x", "title": "t", "workspace": 2}]}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(SessionState.self, from: legacy)
        #expect(state.activeWorkspace == 3)
        #expect(state.windows.count == 1)
        #expect(state.layouts.isEmpty)
    }

    @Test func layoutsRoundTrip() throws {
        let state = SessionState(windows: [], activeWorkspace: 1,
                                 layouts: [1: WorkspaceLayout(root: saved, floating: [9: CGRect(x: 1, y: 2, width: 3, height: 4)])])
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SessionState.self, from: data) == state)
    }
}
