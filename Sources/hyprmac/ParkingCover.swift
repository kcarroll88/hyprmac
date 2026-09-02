import AppKit
import HyprCore
import HyprKit

/// What one corner of the screen needs covered.
struct CornerCover: Equatable {
    /// Where each parked window in this corner actually landed (AX coordinates).
    var slivers: [CGRect] = []
    /// Tiles that are stacked above every sliver here. The cover leaves a hole
    /// for each, so the tile shows and does the hiding itself.
    var tiles: [CGRect] = []
    /// A sliver here is stacked above a tile and would show through a hole, so
    /// the cover paints over the tile instead. The lesser artifact, and rare —
    /// see `WindowManager.placeSlivers` for when it happens.
    var paintOverTiles = false
}

/// Hides the slivers of parked windows without any permission.
///
/// A parked window is clamped so ~40x52pt of its title bar stays on screen in a
/// bottom corner. This panel sits at that corner, above ordinary windows, and
/// paints the wallpaper — which is only right where the desktop is: a tile that
/// reaches into the corner would get a wallpaper patch painted over it. The
/// panel cannot simply go *under* the tile either, because it has to stay above
/// the parked windows, and those and the tiles belong to other apps whose
/// stacking is not ours.
///
/// So the manager arranges things the other way round: every sliver is parked
/// under a tile that is stacked above it (`WindowManager.placeSlivers`), and this
/// cover cuts a hole wherever such a tile is. In the hole the tile hides the
/// sliver; around it, in the gap ring, the cover paints wallpaper that matches the
/// canvas. Holes are rounded to the window corner radius, since a tile does not
/// paint its own corners and a sliver could peek through the unpainted triangle.
///
/// It swallows clicks: a click that fell through would land on a parked window
/// and focus something invisible.
final class ParkingCover {
    private var panels: [ParkCorner: NSPanel] = [:]
    private var views: [ParkCorner: CoverView] = [:]
    private var config = Config()
    /// Extra reach past the sliver, for the window shadow that bleeds around it.
    private let shadowMargin: CGFloat = 40

    func apply(config: Config) {
        self.config = config
        for view in views.values {
            view.config = config
            view.needsDisplay = true
        }
    }

    func update(_ corners: [ParkCorner: CornerCover]) {
        for corner in ParkCorner.allCases {
            guard let state = corners[corner], !state.slivers.isEmpty,
                  let screen = NSScreen.screens.first else {
                panels[corner]?.orderOut(nil)
                continue
            }
            let screenAX = Displays.toAX(screen.frame)
            var union: CGRect = .null
            for sliver in state.slivers {
                let visible = sliver.intersection(screenAX)
                if !visible.isNull { union = union.union(visible) }
            }
            guard !union.isNull else { panels[corner]?.orderOut(nil); continue }
            let padded = union.insetBy(dx: -shadowMargin, dy: -shadowMargin).intersection(screenAX)

            let (panel, view) = panelAndView(for: corner)
            panel.setFrame(Displays.toCocoa(padded), display: false)
            // The whole tile, not the part inside the cover: clipping first and
            // rounding after would round corners the tile does not have, painting a
            // wedge of wallpaper over its straight edge. The view clips for free.
            view.holes = state.paintOverTiles ? [] : state.tiles
                .filter { $0.intersects(padded) }
                .map { CGRect(x: $0.minX - padded.minX, y: padded.maxY - $0.maxY,
                              width: $0.width, height: $0.height) }
            view.needsDisplay = true
            panel.orderFrontRegardless()
        }
    }

    func remove() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
    }

    private func panelAndView(for corner: ParkCorner) -> (NSPanel, CoverView) {
        if let panel = panels[corner], let view = views[corner] { return (panel, view) }
        let view = CoverView()
        view.config = config
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = view
        // Above ordinary windows, below the Dock and menu bar.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panels[corner] = panel
        views[corner] = view
        return (panel, view)
    }
}

/// Paints the wallpaper the canvas paints, cropped to the cover's own rect, with
/// holes where tiles are.
private final class CoverView: NSView {
    var config = Config()
    /// View-space rects to leave transparent.
    var holes: [CGRect] = []

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = window.frame.origin

        if case .color(let argb) = config.wallpaper {
            NSColor(argb: argb).setFill()
            context.fill(bounds)
        } else if let screen = NSScreen.screens.first,
                  let image = Wallpaper.image(for: screen, source: config.wallpaper) {
            // Draw the whole screen's wallpaper offset by our origin, so the crop
            // lines up with what the canvas shows around us.
            let rect = CGRect(x: screen.frame.minX - origin.x, y: screen.frame.minY - origin.y,
                              width: screen.frame.width, height: screen.frame.height)
            image.draw(in: Wallpaper.aspectFillRect(for: image.size, in: rect),
                       from: .zero, operation: .copy, fraction: 1)
        } else {
            NSColor.windowBackgroundColor.setFill()
            context.fill(bounds)
        }

        if config.wallpaperDim > 0 {
            NSColor.black.withAlphaComponent(config.wallpaperDim).setFill()
            context.fill(bounds)
        }

        guard !holes.isEmpty else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        for hole in holes {
            context.addPath(CGPath(roundedRect: hole, cornerWidth: config.rounding,
                                   cornerHeight: config.rounding, transform: nil))
        }
        context.fillPath()
        context.restoreGState()
    }

    // Swallow the click; do nothing with it.
    override func mouseDown(with event: NSEvent) {}
}
