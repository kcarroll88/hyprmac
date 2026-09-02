import CoreGraphics

/// A dwindle layout tree: every node is either one surface or a binary split.
/// Value semantics throughout, so a layout can be computed, diffed, or tested
/// without touching the desktop.
public indirect enum Tile: Equatable, Sendable {
    case leaf(SurfaceID)
    case split(axis: Axis, ratio: CGFloat, first: Tile, second: Tile)
}

// MARK: - Inspection

public extension Tile {
    /// Every surface, left to right / top to bottom.
    var surfaces: [SurfaceID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let f, let s): return f.surfaces + s.surfaces
        }
    }

    func contains(_ id: SurfaceID) -> Bool {
        switch self {
        case .leaf(let e): return e == id
        case .split(_, _, let f, let s): return f.contains(id) || s.contains(id)
        }
    }

    var count: Int { surfaces.count }

    /// Whether `a` and `b` are the two leaves of one split of `axis`, `a` first.
    /// Putting `a` beside `b` on that side would change nothing.
    func splits(_ a: SurfaceID, then b: SurfaceID, along axis: Axis) -> Bool {
        switch self {
        case .leaf: return false
        case .split(let ax, _, let f, let s):
            if ax == axis, f == .leaf(a), s == .leaf(b) { return true }
            return f.splits(a, then: b, along: axis) || s.splits(a, then: b, along: axis)
        }
    }

    /// Route to a leaf: `false` descends into `first`, `true` into `second`.
    func path(to id: SurfaceID) -> [Bool]? {
        switch self {
        case .leaf(let e):
            return e == id ? [] : nil
        case .split(_, _, let f, let s):
            if let p = f.path(to: id) { return [false] + p }
            if let p = s.path(to: id) { return [true] + p }
            return nil
        }
    }

    subscript(path: [Bool]) -> Tile {
        var node = self
        for step in path {
            guard case .split(_, _, let f, let s) = node else { return node }
            node = step ? s : f
        }
        return node
    }
}

// MARK: - Frames

public extension Tile {
    /// Resolve every surface's rect inside `rect`, honouring gaps.
    /// `rect` is the usable screen area; the outer gap is applied here.
    func frames(in rect: CGRect, gaps: Gaps) -> [SurfaceID: CGRect] {
        var out: [SurfaceID: CGRect] = [:]
        layout(in: rect.inset(by: gaps.outer), gaps: gaps, into: &out)
        return out
    }

    private func layout(in rect: CGRect, gaps: Gaps, into out: inout [SurfaceID: CGRect]) {
        switch self {
        case .leaf(let id):
            out[id] = CGRect(x: rect.minX, y: rect.minY,
                             width: max(0, rect.width), height: max(0, rect.height))
        case .split(let axis, let ratio, let first, let second):
            var (a, b) = rect.split(axis, ratio: ratio)
            // Carve the inner gap out of the shared edge, half from each side.
            let half = gaps.inner / 2
            switch axis {
            case .horizontal:
                a.size.width = max(0, a.width - half)
                b.origin.x += half
                b.size.width = max(0, b.width - half)
            case .vertical:
                a.size.height = max(0, a.height - half)
                b.origin.y += half
                b.size.height = max(0, b.height - half)
            }
            first.layout(in: a, gaps: gaps, into: &out)
            second.layout(in: b, gaps: gaps, into: &out)
        }
    }
}

// MARK: - Mutation

public extension Tile {
    /// Split `target`'s tile in two, putting `id` in the new half.
    /// With no target, splits the last leaf — which is where dwindle puts a new
    /// window when nothing is focused.
    ///
    /// `placeFirst` decides which side of `target` the new tile lands on, which is
    /// what makes a directional move different from a swap.
    func inserting(_ id: SurfaceID, splitting target: SurfaceID?, axis: Axis,
                   ratio: CGFloat = 0.5, placeFirst: Bool = false) -> Tile {
        guard let target, contains(target) else {
            guard let last = surfaces.last else { return .leaf(id) }
            return inserting(id, splitting: last, axis: axis, ratio: ratio, placeFirst: placeFirst)
        }
        switch self {
        case .leaf(let existing):
            guard existing == target else { return self }
            return placeFirst
                ? .split(axis: axis, ratio: ratio, first: .leaf(id), second: .leaf(existing))
                : .split(axis: axis, ratio: ratio, first: .leaf(existing), second: .leaf(id))
        case .split(let a, let r, let f, let s):
            // Descend only into the branch holding the target. Recursing into both
            // would make the other branch treat the target as absent and append a
            // second copy of `id` to its last leaf.
            return f.contains(target)
                ? .split(axis: a, ratio: r, first: f.inserting(id, splitting: target, axis: axis, ratio: ratio, placeFirst: placeFirst), second: s)
                : .split(axis: a, ratio: r, first: f, second: s.inserting(id, splitting: target, axis: axis, ratio: ratio, placeFirst: placeFirst))
        }
    }

    /// Drop a surface, promoting its sibling into the vacated slot.
    /// Returns nil when the tree is left empty.
    func removing(_ id: SurfaceID) -> Tile? {
        switch self {
        case .leaf(let e):
            return e == id ? nil : self
        case .split(let a, let r, let f, let s):
            let nf = f.removing(id)
            let ns = s.removing(id)
            switch (nf, ns) {
            case (nil, nil): return nil
            case (nil, let survivor?): return survivor
            case (let survivor?, nil): return survivor
            case (let x?, let y?): return .split(axis: a, ratio: r, first: x, second: y)
            }
        }
    }

    /// Exchange two surfaces' positions, leaving the tree shape untouched.
    func swapping(_ a: SurfaceID, _ b: SurfaceID) -> Tile {
        switch self {
        case .leaf(let e):
            if e == a { return .leaf(b) }
            if e == b { return .leaf(a) }
            return self
        case .split(let ax, let r, let f, let s):
            return .split(axis: ax, ratio: r, first: f.swapping(a, b), second: s.swapping(a, b))
        }
    }

    /// Grow or shrink the tile holding `id` along `axis`, by nudging the nearest
    /// enclosing split of that axis. No-op when the surface has no such ancestor —
    /// a lone window has nothing to resize against.
    func adjustingRatio(containing id: SurfaceID, axis: Axis, by delta: CGFloat) -> Tile {
        guard let p = path(to: id), !p.isEmpty else { return self }
        for depth in stride(from: p.count - 1, through: 0, by: -1) {
            let prefix = Array(p[0..<depth])
            guard case .split(let a, _, _, _) = self[prefix], a == axis else { continue }
            // Descending into `second` means growing it moves the divider the other way.
            let signed = p[depth] ? -delta : delta
            return replacingRatio(at: prefix, delta: signed)
        }
        return self
    }

    /// Move the divider by a real number of points.
    ///
    /// `adjustingRatio` treats its delta as a fraction of the whole screen, so a
    /// "60pt" nudge on a split that only governs a quarter of the width actually
    /// moved the divider 15pt. This converts the request against the rect the
    /// governing split actually occupies, so 60pt means 60pt wherever you are.
    func adjustingSplit(containing id: SurfaceID, axis: Axis, byPoints delta: CGFloat,
                        in rect: CGRect, gaps: Gaps) -> Tile {
        guard let p = path(to: id), !p.isEmpty else { return self }

        // Walk to the leaf, recording the rect each node occupies on the way down.
        var rects: [CGRect] = []
        var node = self
        var current = rect.inset(by: gaps.outer)
        for step in p {
            rects.append(current)
            guard case .split(let a, let r, let f, let s) = node else { break }
            var (lhs, rhs) = current.split(a, ratio: r)
            let half = gaps.inner / 2
            switch a {
            case .horizontal:
                lhs.size.width = max(0, lhs.width - half)
                rhs.origin.x += half
                rhs.size.width = max(0, rhs.width - half)
            case .vertical:
                lhs.size.height = max(0, lhs.height - half)
                rhs.origin.y += half
                rhs.size.height = max(0, rhs.height - half)
            }
            current = step ? rhs : lhs
            node = step ? s : f
        }

        for depth in stride(from: p.count - 1, through: 0, by: -1) {
            let prefix = Array(p[0..<depth])
            guard case .split(let a, _, _, _) = self[prefix], a == axis, depth < rects.count else { continue }
            let extent = axis == .horizontal ? rects[depth].width : rects[depth].height
            guard extent > 0 else { return self }
            // Descending into `second` means growing it moves the divider the other way.
            let signed = (p[depth] ? -delta : delta) / extent
            return replacingRatio(at: prefix, delta: signed)
        }
        return self
    }

    private func replacingRatio(at path: [Bool], delta: CGFloat) -> Tile {
        guard case .split(let a, let r, let f, let s) = self else { return self }
        guard let step = path.first else {
            return .split(axis: a, ratio: min(0.95, max(0.05, r + delta)), first: f, second: s)
        }
        let rest = Array(path.dropFirst())
        return step
            ? .split(axis: a, ratio: r, first: f, second: s.replacingRatio(at: rest, delta: delta))
            : .split(axis: a, ratio: r, first: f.replacingRatio(at: rest, delta: delta), second: s)
    }
}

// MARK: - Directional navigation

public extension Tile {
    /// The surface a directional focus move should land on: the nearest tile whose
    /// centre lies that way and which overlaps `id` on the perpendicular axis.
    /// Geometric rather than tree-based, so it behaves the way it looks.
    func neighbor(of id: SurfaceID, _ direction: Direction, in rect: CGRect, gaps: Gaps) -> SurfaceID? {
        let all = frames(in: rect, gaps: gaps)
        guard let origin = all[id] else { return nil }

        var best: (id: SurfaceID, distance: CGFloat, alignment: CGFloat)?
        for (other, frame) in all where other != id {
            let overlaps: Bool
            let distance: CGFloat
            switch direction.axis {
            case .horizontal:
                overlaps = frame.maxY > origin.minY && frame.minY < origin.maxY
                distance = direction.isForward ? frame.minX - origin.maxX : origin.minX - frame.maxX
            case .vertical:
                overlaps = frame.maxX > origin.minX && frame.minX < origin.maxX
                distance = direction.isForward ? frame.minY - origin.maxY : origin.minY - frame.maxY
            }
            // A small negative distance is just the gap overlap rounding; anything
            // more means the candidate is behind us.
            guard overlaps, distance > -gaps.inner - 1 else { continue }

            // Ties are the norm, not the exception: every tile in the next column
            // starts at the same edge. Break them on leading edges — moving right
            // should keep you on the row you were already on — and fall back to the
            // id so the answer can never depend on dictionary ordering.
            let alignment: CGFloat = switch direction.axis {
            case .horizontal: abs(frame.minY - origin.minY)
            case .vertical:   abs(frame.minX - origin.minX)
            }
            let candidate = (id: other, distance: distance, alignment: alignment)
            if let current = best {
                let sameDistance = abs(candidate.distance - current.distance) <= 0.5
                if !sameDistance {
                    guard candidate.distance < current.distance else { continue }
                } else {
                    let sameAlignment = abs(candidate.alignment - current.alignment) <= 0.5
                    if sameAlignment {
                        guard candidate.id.raw < current.id.raw else { continue }
                    } else {
                        guard candidate.alignment < current.alignment else { continue }
                    }
                }
            }
            best = candidate
        }
        return best?.id
    }
}

// MARK: - Dividers (mouse resize)

/// A split found under the cursor, and everything needed to drag it.
public struct DividerHit: Equatable, Sendable {
    /// Route to the split node, for `settingRatio`.
    public let path: [Bool]
    public let axis: Axis
    /// The area the split governs — the drag maps a cursor position into a ratio
    /// of this, not of the screen.
    public let bounds: CGRect
    public let ratio: CGFloat
}

public extension Tile {
    /// The divider within `tolerance` of `point`, if any.
    ///
    /// Walks to the deepest match so that dragging in a nested gap moves the inner
    /// divider rather than the outer one you happen to also be near.
    func divider(at point: CGPoint, in rect: CGRect, gaps: Gaps,
                 tolerance: CGFloat = 8) -> DividerHit? {
        var found: DividerHit?
        search(point: point, area: rect.inset(by: gaps.outer), gaps: gaps,
               tolerance: tolerance, path: [], into: &found)
        return found
    }

    private func search(point: CGPoint, area: CGRect, gaps: Gaps, tolerance: CGFloat,
                        path: [Bool], into found: inout DividerHit?) {
        guard case .split(let axis, let ratio, let first, let second) = self else { return }
        var (lhs, rhs) = area.split(axis, ratio: ratio)
        let half = gaps.inner / 2
        let line: CGFloat
        switch axis {
        case .horizontal:
            line = lhs.maxX
            lhs.size.width = max(0, lhs.width - half)
            rhs.origin.x += half
            rhs.size.width = max(0, rhs.width - half)
        case .vertical:
            line = lhs.maxY
            lhs.size.height = max(0, lhs.height - half)
            rhs.origin.y += half
            rhs.size.height = max(0, rhs.height - half)
        }

        let reach = max(tolerance, half + tolerance)
        let onLine = axis == .horizontal
            ? abs(point.x - line) <= reach && point.y >= area.minY && point.y <= area.maxY
            : abs(point.y - line) <= reach && point.x >= area.minX && point.x <= area.maxX
        if onLine {
            found = DividerHit(path: path, axis: axis, bounds: area, ratio: ratio)
        }

        first.search(point: point, area: lhs, gaps: gaps, tolerance: tolerance,
                     path: path + [false], into: &found)
        second.search(point: point, area: rhs, gaps: gaps, tolerance: tolerance,
                      path: path + [true], into: &found)
    }

    /// Set a split's ratio outright, for a drag in progress.
    func settingRatio(at path: [Bool], to ratio: CGFloat) -> Tile {
        let clamped = min(0.9, max(0.1, ratio))
        return replacingNode(at: path) { node in
            guard case .split(let axis, _, let first, let second) = node else { return node }
            return .split(axis: axis, ratio: clamped, first: first, second: second)
        }
    }
}

// MARK: - Directional movement

public extension Tile {
    /// Move `id` one step in `direction`, doing whatever is most obviously correct.
    ///
    /// Three cases, in order:
    ///
    /// 1. **Something is there.** Re-insert beside it, on the side pushed towards.
    ///
    /// 2. **Nothing is there, but the tile shares a split with a sibling running
    ///    the other way.** Re-orient that split. Two full-height columns pushed
    ///    `down` become a stacked pair in the same region — the window ends up
    ///    under its neighbour, which is what "move it down" plainly means even
    ///    though no tile was literally below it.
    ///
    /// 3. **Nothing is there and the tile is already stacked that way.** It is at
    ///    the edge of its container, so escape one level and span the whole layout
    ///    along that edge.
    ///
    /// Doing nothing is never the answer: a direction key that silently no-ops
    /// reads as broken.
    func moving(_ id: SurfaceID, _ direction: Direction, in rect: CGRect, gaps: Gaps) -> Tile {
        guard contains(id), count > 1 else { return self }

        if let target = neighbor(of: id, direction, in: rect, gaps: gaps),
           let pruned = removing(id) {
            // The direction chooses *which* tile you land in; the tile's own shape
            // chooses *how* it splits — the same dwindle rule a new window follows.
            // Landing in a tall half-screen therefore stacks rather than carving it
            // into two slivers, whichever way you pushed to get there.
            //
            // Measured after removal, since vacating your old slot can change the
            // shape of the one you are about to split.
            let landing = pruned.frames(in: rect, gaps: gaps)[target] ?? rect
            let axis = landing.naturalSplitAxis
            // Only the direction you pushed can say which side to take, and only
            // when the split runs that way at all; otherwise take the far side.
            let placeFirst = (axis == direction.axis) ? !direction.isForward : false
            return pruned.inserting(id, splitting: target, axis: axis, placeFirst: placeFirst)
        }

        guard let p = path(to: id), !p.isEmpty else { return self }
        let parentPath = Array(p.dropLast())
        guard case .split(let axis, _, let parentFirst, let parentSecond) = self[parentPath] else { return self }

        // Re-orient only a genuine pair. If the other side of this split is a whole
        // subtree, flipping the axis drags every window in it onto a new axis —
        // which is how a three-window layout collapsed into one vertical column
        // after moving a single window that had nothing below it.
        let sibling = parentFirst.contains(id) ? parentSecond : parentFirst
        if axis != direction.axis, case .leaf = sibling {
            return reorienting(at: parentPath, holding: id,
                               to: direction.axis, idFirst: !direction.isForward)
        }

        // Otherwise leave the container entirely and take the far edge.
        guard let pruned = removing(id) else { return self }

        // Unless the remainder already runs along that axis: wrapping a stack in
        // another split of the same axis just deepens the stack, producing the
        // same collapse by a different route. There is genuinely nowhere to go.
        if case .split(let remainingAxis, _, _, _) = pruned, remainingAxis == direction.axis {
            return self
        }

        // Keep the size it already had. Moving a window is a change of position;
        // handing it some fixed fraction of the screen on the way out silently
        // resizes it, which is how a terminal ends up squeezed to 30% after a few
        // rearrangements. Clamped so an extreme starting size stays usable.
        let field = rect.inset(by: gaps.outer)
        let previous = frames(in: rect, gaps: gaps)[id] ?? field
        let total = direction.axis == .horizontal ? field.width : field.height
        let mine = direction.axis == .horizontal ? previous.width : previous.height
        let share = total > 0 ? min(0.6, max(0.2, mine / total)) : 0.35

        return direction.isForward
            ? .split(axis: direction.axis, ratio: 1 - share, first: pruned, second: .leaf(id))
            : .split(axis: direction.axis, ratio: share, first: .leaf(id), second: pruned)
    }

    private func reorienting(at path: [Bool], holding id: SurfaceID,
                             to axis: Axis, idFirst: Bool) -> Tile {
        replacingNode(at: path) { node in
            guard case .split(_, let ratio, let first, let second) = node else { return node }
            let idIsAlreadyFirst = first.contains(id)
            let mine = idIsAlreadyFirst ? first : second
            let theirs = idIsAlreadyFirst ? second : first
            // Swapping which child comes first would otherwise swap their sizes too.
            let keptRatio = (idIsAlreadyFirst == idFirst) ? ratio : 1 - ratio
            return idFirst
                ? .split(axis: axis, ratio: keptRatio, first: mine, second: theirs)
                : .split(axis: axis, ratio: keptRatio, first: theirs, second: mine)
        }
    }

    private func replacingNode(at path: [Bool], with transform: (Tile) -> Tile) -> Tile {
        guard let step = path.first else { return transform(self) }
        guard case .split(let a, let r, let f, let s) = self else { return self }
        let rest = Array(path.dropFirst())
        return step
            ? .split(axis: a, ratio: r, first: f, second: s.replacingNode(at: rest, with: transform))
            : .split(axis: a, ratio: r, first: f.replacingNode(at: rest, with: transform), second: s)
    }
}

// MARK: - Split orientation

public extension Tile {
    /// Flip the nearest split enclosing `id` between side-by-side and stacked.
    func togglingSplit(containing id: SurfaceID) -> Tile {
        guard let p = path(to: id), !p.isEmpty else { return self }
        return flippingAxis(at: Array(p.dropLast()))
    }

    private func flippingAxis(at path: [Bool]) -> Tile {
        guard case .split(let a, let r, let f, let s) = self else { return self }
        guard let step = path.first else {
            return .split(axis: a.opposite, ratio: r, first: f, second: s)
        }
        let rest = Array(path.dropFirst())
        return step
            ? .split(axis: a, ratio: r, first: f, second: s.flippingAxis(at: rest))
            : .split(axis: a, ratio: r, first: f.flippingAxis(at: rest), second: s)
    }
}

// MARK: - Persistence

extension Tile: Codable {
    private enum CodingKeys: String, CodingKey { case leaf, axis, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try c.decodeIfPresent(UInt64.self, forKey: .leaf) {
            self = .leaf(SurfaceID(raw))
            return
        }
        let axis: Axis = try c.decode(String.self, forKey: .axis) == "h" ? .horizontal : .vertical
        self = .split(axis: axis,
                      ratio: try c.decode(CGFloat.self, forKey: .ratio),
                      first: try c.decode(Tile.self, forKey: .first),
                      second: try c.decode(Tile.self, forKey: .second))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try c.encode(id.raw, forKey: .leaf)
        case .split(let axis, let ratio, let first, let second):
            try c.encode(axis == .horizontal ? "h" : "v", forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}

public extension Tile {
    /// The same tree with every surface not in `keep` removed, siblings promoted.
    ///
    /// This is how a saved layout comes back after a restart: windows are
    /// discovered one at a time, and at each step the saved tree pruned to the
    /// windows seen so far is a valid layout that converges on the saved one as
    /// the rest arrive. Nil when nothing in `keep` is in the tree.
    func pruned(keeping keep: Set<SurfaceID>) -> Tile? {
        surfaces.filter { !keep.contains($0) }.reduce(Optional(self)) { tree, id in tree?.removing(id) }
    }
}

// MARK: - Debugging

extension Tile: CustomStringConvertible {
    public var description: String { render(depth: 0) }

    private func render(depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        switch self {
        case .leaf(let id):
            return "\(pad)\(id)"
        case .split(let axis, let ratio, let first, let second):
            let name = axis == .horizontal ? "cols" : "rows"
            return """
            \(pad)\(name) \(String(format: "%.2f", ratio))
            \(first.render(depth: depth + 1))
            \(second.render(depth: depth + 1))
            """
        }
    }
}
