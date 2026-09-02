import CoreGraphics
import HyprCore

/// Anything the layout engine can put in a tile.
///
/// Two implementations are planned:
///   - `AXSurface`     — a real app window, driven over the Accessibility API. Ships now.
///   - `HostedSurface`  — a view we render ourselves inside the canvas. Later.
///
/// The manager, the keybinds, the config and the dwindle tree all talk to this
/// protocol only, so adding hosted panes is additive rather than a rewrite.
///
/// All rects are in **global AX coordinates**: origin at the primary display's
/// top-left, y increasing downward. AppKit conversion happens only at the canvas
/// boundary, in `Displays`.
public protocol Surface: AnyObject {
    var id: SurfaceID { get }
    var title: String { get }

    /// False once the underlying window has closed and the surface should be evicted.
    var isAlive: Bool { get }

    /// False for things that must not be tiled: sheets, popovers, palettes,
    /// windows the app refuses to let us resize.
    var isTileable: Bool { get }

    /// Where the surface actually is right now, read back from the source of truth.
    var frame: CGRect { get }

    /// Move and resize. May be a no-op if the app clamps to a minimum size.
    func setFrame(_ rect: CGRect)

    /// Raise and give keyboard focus.
    func focus()
}

/// Whether a backend can do things the AX API cannot, so features can degrade
/// gracefully rather than being compiled out.
public struct SurfaceCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Frame changes can be animated smoothly rather than snapping.
    public static let animation  = SurfaceCapabilities(rawValue: 1 << 0)
    /// Corner radius can be applied to the surface itself.
    public static let rounding   = SurfaceCapabilities(rawValue: 1 << 1)
    /// Alpha is controllable.
    public static let opacity    = SurfaceCapabilities(rawValue: 1 << 2)
    /// Can be hidden without moving it off-screen.
    public static let visibility = SurfaceCapabilities(rawValue: 1 << 3)
}

public extension Surface {
    /// AX windows can only be moved and resized. Hosted surfaces will report far more.
    var capabilities: SurfaceCapabilities { [] }
}
