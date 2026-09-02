import CoreGraphics

/// Where on a tile a dragged window is dropped, and what that means.
///
/// The middle of a tile means "swap with this one". Near an edge means "put me in
/// that half of it": the target splits, and the dragged window takes the side it
/// was dropped on. The preview rect is what the canvas lights up, so the user sees
/// the half before letting go.
public enum DropZone: Equatable, Sendable {
    case center, left, right, top, bottom

    /// `centerFraction` is the width of the middle box as a fraction of the tile: a
    /// half, so the outer quarter on each side is an edge zone.
    public static func zone(for p: CGPoint, in frame: CGRect, centerFraction: CGFloat = 0.5) -> DropZone {
        guard frame.width > 0, frame.height > 0 else { return .center }
        let dx = (p.x - frame.midX) / (frame.width / 2)     // -1 … 1
        let dy = (p.y - frame.midY) / (frame.height / 2)
        if abs(dx) <= centerFraction, abs(dy) <= centerFraction { return .center }
        if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
        return dy < 0 ? .top : .bottom
    }

    public func preview(in frame: CGRect) -> CGRect {
        switch self {
        case .center: return frame
        case .left:   return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:  return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:    return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    public var axis: Axis? {
        switch self { case .center: return nil; case .left, .right: return .horizontal; case .top, .bottom: return .vertical }
    }
    /// The dragged window goes first (left or top) or second.
    public var placesFirst: Bool { self == .left || self == .top }

    /// The tile a dragged window is over, and the zone of it.
    ///
    /// Two questions, answered by two different things. *Which tile* is what the
    /// window visibly covers — the tile it overlaps most — because the pointer
    /// rides the title bar and is routinely over a different tile than the window
    /// body the user is watching. *Which part of it* is where the window's centre
    /// sits inside that tile, with a dead band (`band`, a fraction of the tile's
    /// half-extent) around the middle that means swap.
    ///
    /// The band is the whole difficulty, and it has been wrong twice. Judged by the
    /// pointer alone, dragging a window down over its neighbour read as *above* it,
    /// because the pointer sits at the window's top edge. Judged by how much of each
    /// half the window *covered*, a window the same size as the tile had to be hauled
    /// a quarter of the screen sideways before either half won a 65/35 majority —
    /// which took the halves out of reach entirely, since two windows are exactly
    /// the case where each one is half the screen. The centre answers both: it moves
    /// point for point with the drag, so the band is a distance the user can feel,
    /// and it is independent of the window's own size, so a half-height window
    /// dropped in the lower half of a tall tile is not sitting on the boundary.
    ///
    /// `pushedUp` says the pointer is above the tiles' area, in the menu bar: macOS
    /// pins a window there and lets the pointer go on alone, so the window is as high
    /// as it goes and the pointer says higher was meant. A topmost target then reads
    /// as *above* — the one thing neither covering nor the centre can say, since a
    /// window cannot get above a tile it is already as high as. A window covering no
    /// tile at all falls back to the nearest one within `reach` of its centre.
    public static func hit(window: CGRect, over frames: [SurfaceID: CGRect], pushedUp: Bool = false,
                           band: CGFloat = 0.3, reach: CGFloat = 48) -> (id: SurfaceID, zone: DropZone)? {
        guard !frames.isEmpty, window.width > 0, window.height > 0 else { return nil }
        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat { let i = a.intersection(b); return i.isNull ? 0 : i.width * i.height }
        let centre = CGPoint(x: window.midX, y: window.midY)
        let covered = frames.map { (id: $0.key, frame: $0.value, area: overlap(window, $0.value)) }
        let most = covered.max { l, r in
            if l.area != r.area { return l.area < r.area }
            if l.frame.contains(centre) != r.frame.contains(centre) { return r.frame.contains(centre) }
            return l.id.raw > r.id.raw
        }!
        guard most.area > 0 else {
            // Not over anything: the nearest tile within reach, by the centre.
            func distance(_ r: CGRect) -> CGFloat { hypot(max(r.minX - centre.x, 0, centre.x - r.maxX), max(r.minY - centre.y, 0, centre.y - r.maxY)) }
            guard let near = frames.min(by: { distance($0.value) < distance($1.value) }), distance(near.value) <= reach else { return nil }
            let inside = CGPoint(x: min(max(centre.x, near.value.minX), near.value.maxX), y: min(max(centre.y, near.value.minY), near.value.maxY))
            return (near.key, zone(for: inside, in: near.value, centerFraction: band))
        }
        let f = most.frame
        if pushedUp, !frames.values.contains(where: { $0.maxY <= f.minY && $0.maxX > f.minX && $0.minX < f.maxX }) {
            return (most.id, .top)
        }
        // An axis on which the window covers the tile end to end cannot name a side
        // of it — it is over both halves, whole — so that axis says nothing and the
        // other one decides. A window dropped square on a tile smaller than itself
        // is therefore a swap, which is the only thing it can sensibly mean.
        let slack: CGFloat = 1
        let spansX = window.minX <= f.minX + slack && window.maxX >= f.maxX - slack
        let spansY = window.minY <= f.minY + slack && window.maxY >= f.maxY - slack
        let inside = CGPoint(x: min(max(centre.x, f.minX), f.maxX), y: min(max(centre.y, f.minY), f.maxY))
        let dx = spansX ? 0 : (inside.x - f.midX) / max(1, f.width / 2)
        let dy = spansY ? 0 : (inside.y - f.midY) / max(1, f.height / 2)
        if abs(dx) <= band, abs(dy) <= band { return (most.id, .center) }
        if abs(dx) >= abs(dy) { return (most.id, dx < 0 ? .left : .right) }
        return (most.id, dy < 0 ? .top : .bottom)
    }
}
