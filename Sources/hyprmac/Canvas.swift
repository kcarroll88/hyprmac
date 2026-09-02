import AppKit
import HyprCore
import HyprKit

/// What the canvas should draw. Plain data so rendering stays a pure function of
/// WM state — the manager never reaches into the view.
struct CanvasModel {
    struct Slot {
        let frame: CGRect   // AX coordinates
        let isActive: Bool
        let label: String
    }
    var slots: [Slot] = []
    /// The tile a dragged window would swap into, lit while it hovers there.
    var dropTarget: CGRect? = nil
    var workspaces: [Int] = []
    var activeWorkspace: Int = 1
    var occupiedWorkspaces: Set<Int> = []
}

/// A borderless window pinned below every application window, spanning all
/// displays. It paints the desktop the tiles sit on.
///
/// By default it sits *below* Finder's desktop icons and repaints the user's own
/// wallpaper, so the desktop still looks like their desktop. Its stroke shows in
/// the gap ring around each window rather than on top — the honest limit of doing
/// this without private APIs.
final class Canvas {
    private var window: NSWindow?
    private let view = CanvasView()
    private var config: Config

    /// Asked whether a divider sits under an AX-space point, to decide if a click
    /// belongs to us or should fall through to the desktop.
    var dividerProbe: ((CGPoint) -> Bool)? {
        get { view.dividerProbe } set { view.dividerProbe = newValue }
    }
    var onDragBegan: ((CGPoint) -> Void)? {
        get { view.onDragBegan } set { view.onDragBegan = newValue }
    }
    var onDragMoved: ((CGPoint) -> Void)? {
        get { view.onDragMoved } set { view.onDragMoved = newValue }
    }
    var onDragEnded: (() -> Void)? {
        get { view.onDragEnded } set { view.onDragEnded = newValue }
    }

    init(config: Config) {
        self.config = config
        rebuild()

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                           object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        // Follow the user into light/dark so the canvas never looks out of place.
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Wallpaper.invalidate()
            self?.view.needsDisplay = true
        }
    }

    func apply(config: Config) {
        self.config = config
        view.config = config
        Wallpaper.invalidate()
        rebuild()
    }

    func update(_ model: CanvasModel) {
        view.model = model
        view.needsDisplay = true
    }

    private func rebuild() {
        guard config.canvasEnabled else {
            window?.orderOut(nil)
            window = nil
            return
        }
        // One window covering the union of every screen, so tiles can straddle
        // displays without us managing a window per screen.
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull else { return }

        let window = self.window ?? makeWindow()
        window.setFrame(union, display: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(
            config.showDesktopIcons ? .desktopWindow : .desktopIconWindow)) + (config.showDesktopIcons ? 1 : 0))
        window.alphaValue = config.canvasOpacity
        view.frame = CGRect(origin: .zero, size: union.size)
        view.windowOriginInCocoa = union.origin
        view.config = config
        window.orderBack(nil)
        self.window = window
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Not blanket-ignored: the view's hit test claims only the few points that
        // sit on a divider, so everything else still falls through to the desktop.
        window.ignoresMouseEvents = false
        window.isMovable = false
        window.orderBack(nil)
        return window
    }
}

/// Shared with `WorkspaceTransition`, which paints the same desktop as an overlay.
final class CanvasView: NSView {
    var model = CanvasModel()
    var config = Config()
    /// Where the canvas window sits in Cocoa screen coordinates, so AX rects can
    /// be mapped into view space.
    var windowOriginInCocoa: CGPoint = .zero

    var dividerProbe: ((CGPoint) -> Bool)?
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private var isDragging = false

    override var isFlipped: Bool { false }
    /// Track the system appearance rather than pinning one, so the canvas follows
    /// the user into light and dark mode like any other Mac app.
    override var allowsVibrancy: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(in: context)
        for slot in model.slots { draw(slot) }
        if let target = model.dropTarget {
            let rect = toViewSpace(target).insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(roundedRect: rect, xRadius: config.rounding + 3, yRadius: config.rounding + 3)
            accentColor.withAlphaComponent(0.22).setFill(); path.fill()
            accentColor.withAlphaComponent(0.9).setStroke(); path.lineWidth = 2; path.stroke()
        }
    }

    // MARK: Background

    private func drawBackground(in context: CGContext) {
        if case .color(let argb) = config.wallpaper {
            NSColor(argb: argb).setFill()
            context.fill(bounds)
        } else {
            // Each display can have its own desktop picture, so draw per screen.
            for screen in NSScreen.screens {
                let rect = CGRect(x: screen.frame.minX - windowOriginInCocoa.x,
                                  y: screen.frame.minY - windowOriginInCocoa.y,
                                  width: screen.frame.width, height: screen.frame.height)
                guard let image = Wallpaper.image(for: screen, source: config.wallpaper) else {
                    NSColor.windowBackgroundColor.setFill()
                    rect.fill()
                    continue
                }
                context.saveGState()
                context.clip(to: rect)
                image.draw(in: Wallpaper.aspectFillRect(for: image.size, in: rect),
                           from: .zero, operation: .copy, fraction: 1)
                context.restoreGState()
            }
        }

        if config.wallpaperDim > 0 {
            NSColor.black.withAlphaComponent(config.wallpaperDim).setFill()
            context.fill(bounds)
        }
    }

    // MARK: Slots

    private func draw(_ slot: CanvasModel.Slot) {
        let rect = toViewSpace(slot.frame)
        guard !rect.isEmpty else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: config.rounding, yRadius: config.rounding)

        NSGraphicsContext.saveGraphicsState()
        if config.slotShadow {
            // Roughly the shadow macOS puts under a real window, so an empty slot
            // reads as window-shaped rather than as a painted rectangle.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(slot.isActive ? 0.45 : 0.28)
            shadow.shadowBlurRadius = slot.isActive ? 30 : 18
            shadow.shadowOffset = NSSize(width: 0, height: slot.isActive ? -8 : -5)
            shadow.set()
        }
        // Barely-there fill: the slot is a recess in the wallpaper, not a panel.
        // It is only visible while a window is mid-move or a tile sits empty.
        NSColor.black.withAlphaComponent(0.10).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        if slot.isActive {
            // macOS never outlines the focused window — it signals focus with depth.
            // So this is a soft halo in the user's accent colour rather than the
            // hard 2px border a Linux WM would draw, which in a 12pt gap reads as a
            // harsh divider line.
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = accentColor.withAlphaComponent(0.5)
            glow.shadowBlurRadius = 20
            glow.shadowOffset = .zero
            glow.set()
            accentColor.withAlphaComponent(0.28).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.white.withAlphaComponent(0.10).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private var accentColor: NSColor {
        config.activeBorderUsesAccent ? .controlAccentColor : NSColor(argb: config.activeBorderColor)
    }

    // MARK: Mouse

    /// Claim only the points sitting on a divider. Returning nil everywhere else
    /// keeps the desktop clickable — icons, drag-select, right-click menus.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let probe = dividerProbe else { return nil }
        let local = convert(point, from: superview)
        return probe(toAXSpace(local)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        onDragBegan?(toAXSpace(convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDragMoved?(toAXSpace(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        onDragEnded?()
    }

    /// Only fires over a divider, since the hit test rejects everywhere else — so
    /// the resize cursor appears exactly where a drag would actually work.
    override func mouseMoved(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved, .inVisibleRect],
                                       owner: self))
    }

    /// This view's space (bottom-left, y up) back to AX space (top-left, y down).
    private func toAXSpace(_ point: CGPoint) -> CGPoint {
        let cocoa = CGPoint(x: point.x + windowOriginInCocoa.x, y: point.y + windowOriginInCocoa.y)
        return CGPoint(x: cocoa.x, y: Displays.flipHeight - cocoa.y)
    }

    /// AX space (top-left origin, y down) to this view's space (bottom-left, y up).
    private func toViewSpace(_ axRect: CGRect) -> CGRect {
        let cocoa = Displays.toCocoa(axRect)
        return CGRect(x: cocoa.minX - windowOriginInCocoa.x,
                      y: cocoa.minY - windowOriginInCocoa.y,
                      width: cocoa.width, height: cocoa.height)
    }
}

extension NSColor {
    /// Config colours are stored as 0xAARRGGBB.
    convenience init(argb: UInt32) {
        self.init(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
                  green: CGFloat((argb >> 8) & 0xFF) / 255,
                  blue: CGFloat(argb & 0xFF) / 255,
                  alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }
}
