import AppKit
import HyprCore

/// Drag a tiled window by its title bar onto another tile and the two swap.
///
/// For people who do not want to learn ALT+SHIFT+arrows. macOS moves the window
/// under the mouse on its own; this only watches: a press on a tile's title strip
/// starts a candidate, a drag past a few points makes it a drag and lights the tile
/// under the pointer, and the release either swaps the two windows in the tree or
/// lets the relayout snap the window back where it was. Global monitors, so it
/// needs the Accessibility grant hyprmac already has.
final class WindowDrag {
    /// The tiled window under a press, if the press is on its title strip, with its
    /// frame at the press — the grab offset is what makes the frame during the drag.
    var candidate: (CGPoint) -> (id: SurfaceID, frame: CGRect)? = { _ in nil }
    /// The tile the dragged window is over (or nearest), other than itself, with the
    /// zone of it and the rect to light up. Given the pointer, the dragged window's
    /// frame as it stands now (the press frame carried along by the pointer), and
    /// the window.
    struct Hit: Equatable { let id: SurfaceID; let zone: DropZone; let preview: CGRect }
    var target: (CGPoint, CGRect, SurfaceID) -> Hit? = { _, _, _ in nil }
    var highlight: (CGRect?) -> Void = { _ in }
    var dropped: (SurfaceID, Hit?) -> Void = { _, _ in }
    /// Counts drags, so work scheduled after a drop can tell a new drag has begun.
    private(set) var generation = 0

    private var monitors: [Any] = []
    private var pressed: (id: SurfaceID, at: CGPoint, frame: CGRect)?
    private var dragging = false
    private var lastHit: Hit?

    func start() {
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.down() } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.moved() } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.up() } as Any)
    }

    /// Cocoa's screen point (origin bottom-left of the primary screen) as the AX
    /// point the layout uses (origin top-left).
    static var pointer: CGPoint {
        let p = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: height - p.y)
    }

    private func down() {
        let p = Self.pointer
        pressed = candidate(p).map { ($0.id, p, $0.frame) }
        dragging = false; lastHit = nil
        if pressed != nil { generation += 1 }
    }

    private func moved() {
        guard let pressed else { return }
        let p = Self.pointer
        if !dragging { guard hypot(p.x - pressed.at.x, p.y - pressed.at.y) > 6 else { return }; dragging = true }
        let hit = target(p, frame(at: p), pressed.id)
        if hit != lastHit { lastHit = hit; highlight(hit?.preview) }
    }

    /// Where the dragged window is, from where it was grabbed: macOS keeps the grab
    /// offset through a drag, except against the menu bar, where the window stops
    /// and the pointer goes on alone — and this frame then reaches above the screen,
    /// which is how the target closure knows.
    private func frame(at p: CGPoint) -> CGRect {
        guard let pressed else { return .zero }
        return pressed.frame.offsetBy(dx: p.x - pressed.at.x, dy: p.y - pressed.at.y)
    }

    private func up() {
        defer { pressed = nil; dragging = false; lastHit = nil; highlight(nil) }
        guard let pressed, dragging else { return }
        let p = Self.pointer
        dropped(pressed.id, target(p, frame(at: p), pressed.id))
    }
}
