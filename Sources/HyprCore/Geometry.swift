import CoreGraphics

/// Identifies one tileable thing. Deliberately opaque: the layout engine never
/// learns whether this is a real app window driven over the Accessibility API
/// or a pane we render ourselves. See `Surface` in HyprKit for what backs it.
public struct SurfaceID: Hashable, Sendable, CustomStringConvertible, ExpressibleByIntegerLiteral {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public init(integerLiteral value: UInt64) { self.raw = value }
    public var description: String { "surface#\(raw)" }

    private static var counter: UInt64 = 1 << 32  // above the CGWindowID range
    /// Mints an id for a surface with no natural OS-level identifier (hosted panes,
    /// or app windows whose CGWindowID we failed to read).
    public static func synthetic() -> SurfaceID {
        defer { counter &+= 1 }
        return SurfaceID(counter)
    }
}

public enum Axis: Sendable, Equatable {
    /// Children sit side by side, split along x.
    case horizontal
    /// Children stack, split along y.
    case vertical

    public var opposite: Axis { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: String, Sendable, CaseIterable {
    case left, right, up, down

    public var axis: Axis { (self == .left || self == .right) ? .horizontal : .vertical }
    /// True when moving this way increases the coordinate.
    public var isForward: Bool { self == .right || self == .down }
}

/// Gap geometry, mirroring hyprland's `gaps_in` / `gaps_out`.
public struct Gaps: Sendable, Equatable {
    /// Between adjacent tiles.
    public var inner: CGFloat
    /// Between the tile field and the screen edge.
    public var outer: CGFloat

    public init(inner: CGFloat = 5, outer: CGFloat = 12) {
        self.inner = inner
        self.outer = outer
    }
}

public extension CGRect {
    /// Split into two along `axis`, with `ratio` of the extent going to the first part.
    func split(_ axis: Axis, ratio: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let w = (width * ratio).rounded()
            return (CGRect(x: minX, y: minY, width: w, height: height),
                    CGRect(x: minX + w, y: minY, width: width - w, height: height))
        case .vertical:
            let h = (height * ratio).rounded()
            return (CGRect(x: minX, y: minY, width: width, height: h),
                    CGRect(x: minX, y: minY + h, width: width, height: height - h))
        }
    }

    /// Shrink on every side by `amount`, never inverting the rect.
    func inset(by amount: CGFloat) -> CGRect {
        let r = insetBy(dx: amount, dy: amount)
        return CGRect(x: r.minX, y: r.minY, width: max(0, r.width), height: max(0, r.height))
    }

    /// The axis a new sibling should split along, matching hyprland's dwindle:
    /// wide tiles split side-by-side, tall tiles stack.
    var naturalSplitAxis: Axis { width > height ? .horizontal : .vertical }
}
