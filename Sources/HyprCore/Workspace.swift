import CoreGraphics

/// One workspace: a dwindle tree plus any surfaces that opted out of tiling.
public struct Workspace: Sendable {
    public let index: Int
    public var root: Tile?
    public var floating: [SurfaceID: CGRect] = [:]
    public var focused: SurfaceID?
    /// One surface blown up to fill the workspace. The rest keep their tiles and
    /// simply sit underneath, so dropping back out is a single relayout with
    /// nothing to reconstruct.
    public var zoomed: SurfaceID?

    public init(index: Int) { self.index = index }

    public var isEmpty: Bool { root == nil && floating.isEmpty }
    public var tiled: [SurfaceID] { root?.surfaces ?? [] }
    public var all: [SurfaceID] { tiled + Array(floating.keys) }

    /// The surface a command should act on. Falls back rather than returning a
    /// stale id: focus records drift, and acting on a window that is not here is
    /// worse than acting on the wrong one that is.
    public var resolvedFocus: SurfaceID? {
        if let focused, contains(focused) { return focused }
        return tiled.first ?? floating.keys.first
    }

    public func contains(_ id: SurfaceID) -> Bool {
        root?.contains(id) == true || floating[id] != nil
    }

    // MARK: Mutation

    public mutating func insert(_ id: SurfaceID, splitting target: SurfaceID?, axis: Axis) {
        // A new window means you want to see it, so drop out of zoom.
        zoomed = nil
        guard let root else {
            self.root = .leaf(id)
            focused = id
            return
        }
        self.root = root.inserting(id, splitting: target ?? focused, axis: axis)
        focused = id
    }

    /// Take a tiled window out of its slot and put it beside another, on the side
    /// asked for — a drop on a tile's edge.
    public mutating func move(_ id: SurfaceID, beside target: SurfaceID, axis: Axis, first: Bool) {
        guard id != target, let root, root.contains(id), root.contains(target) else { return }
        guard let without = root.removing(id) else { return }
        self.root = without.inserting(id, splitting: target, axis: axis, placeFirst: first)
        focused = id
    }

    public mutating func remove(_ id: SurfaceID) {
        if zoomed == id { zoomed = nil }
        if floating.removeValue(forKey: id) != nil {
            if focused == id { focused = all.first }
            return
        }
        guard root?.contains(id) == true else { return }
        // Pick the successor before mutating, so focus lands somewhere adjacent
        // rather than jumping to the front of the tree.
        let order = tiled
        let successor = order.firstIndex(of: id).map { index -> SurfaceID? in
            let remaining = order.filter { $0 != id }
            guard !remaining.isEmpty else { return nil }
            return remaining[min(index, remaining.count - 1)]
        } ?? nil

        root = root?.removing(id)
        if focused == id { focused = successor ?? floating.keys.first }
    }

    public mutating func setFloating(_ id: SurfaceID, _ rect: CGRect) {
        root = root?.removing(id)
        floating[id] = rect
    }

    public mutating func setTiled(_ id: SurfaceID, axis: Axis) {
        guard floating.removeValue(forKey: id) != nil else { return }
        insert(id, splitting: focused, axis: axis)
    }

    /// Frames for everything on this workspace. Floating surfaces keep their own
    /// geometry and sit outside the tile field.
    ///
    /// While zoomed this returns only the zoomed surface: the others are left
    /// exactly where they were rather than being moved somewhere and moved back,
    /// which is what makes the return to the grid instant and lossless.
    /// The tiled window whose tile contains the point — for a drop.
    public func tile(at point: CGPoint, in rect: CGRect, gaps: Gaps, excluding: SurfaceID? = nil) -> SurfaceID? {
        frames(in: rect, gaps: gaps).first { id, frame in id != excluding && frame.contains(point) }?.key
    }

    public func frames(in rect: CGRect, gaps: Gaps) -> [SurfaceID: CGRect] {
        if let zoomed, contains(zoomed) {
            return [zoomed: rect.inset(by: gaps.outer)]
        }
        var out = root?.frames(in: rect, gaps: gaps) ?? [:]
        for (id, frame) in floating { out[id] = frame }
        return out
    }

    /// Blow up `id`, or drop back to the grid if it is already zoomed.
    public mutating func toggleZoom(_ id: SurfaceID) {
        zoomed = (zoomed == id) ? nil : id
    }
}
