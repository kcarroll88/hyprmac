import AppKit
import HyprCore

/// Every workspace at once, and every window in them: jumping 1 → 4 is one glance
/// and one keystroke rather than remembering which number holds what, and finding a
/// window is a matter of seeing it rather than guessing which number it went to.
///
/// The windows are shown as their applications' icons, one per window, each with its
/// title as a tooltip and a click that goes to it. Icons rather than thumbnails on
/// purpose: a live picture of a window needs Screen Recording, and a window manager
/// asking for that is a red flag whatever its reason. Mission Control cannot do this
/// job here — parked windows are off in a screen corner, which is exactly where it
/// will not look.
///
/// Opened and closed by a three-finger swipe either way, or bound directly.
final class WorkspaceOverview {
    struct Entry {
        let id: SurfaceID
        let icon: NSImage?
        let title: String
    }
    struct Item {
        let index: Int
        let name: String?
        let entries: [Entry]
        let isActive: Bool
        var windows: Int { entries.count }
    }

    private var panel: OverviewPanel?
    var onPick: ((Int) -> Void)?
    /// A particular window was clicked: go to it, wherever it lives.
    var onPickWindow: ((SurfaceID) -> Void)?
    /// Dropped a workspace on a new slot: (from, to), both 1-based.
    var onReorder: ((Int, Int) -> Void)?
    var onRename: ((Int) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(items: [Item], accent: NSColor) {
        if isVisible { hide() } else { show(items: items, accent: accent) }
    }

    func hide() {
        panel?.dismiss()
        panel = nil
    }

    /// Redraw what is already on screen, without re-presenting it.
    ///
    /// The overview does not block anything while it is up: the three-finger swipe
    /// and the workspace keys both still work, so the workspace can change under it.
    /// Built once and never told, it went on pointing at the workspace you were on
    /// when you opened it. Skipped mid-drag, since rebuilding the cards under a
    /// dragged one would drop it.
    func refresh(items: [Item], accent: NSColor) {
        guard let panel, panel.isVisible, !panel.isDragging else { return }
        panel.items = items
        panel.accent = accent
        panel.selection = items.firstIndex { $0.isActive } ?? panel.selection
        panel.build()
    }

    func show(items: [Item], accent: NSColor) {
        guard !items.isEmpty else { return }
        hide()

        let card = CGSize(width: 132, height: 108)
        let gap: CGFloat = 12
        let padding: CGFloat = 22
        // Wrap at five so nine workspaces read as two tidy rows rather than one
        // strip wider than the screen.
        let columns = min(items.count, 5)
        let rows = Int((Double(items.count) / Double(columns)).rounded(.up))
        let size = CGSize(width: CGFloat(columns) * card.width + CGFloat(columns - 1) * gap + padding * 2,
                          height: CGFloat(rows) * card.height + CGFloat(rows - 1) * gap + padding * 2 + 30)

        let panel = OverviewPanel(size: size, cornerRadius: 22)
        panel.items = items
        panel.cardSize = card
        panel.gap = gap
        panel.padding = padding
        panel.columns = columns
        panel.accent = accent
        panel.selection = items.firstIndex { $0.isActive } ?? 0
        panel.onPick = { [weak self] index in
            self?.hide()
            self?.onPick?(index)
        }
        panel.onPickWindow = { [weak self] id in
            self?.hide()
            self?.onPickWindow?(id)
        }
        panel.onReorder = { [weak self] from, to in
            self?.hide()
            self?.onReorder?(from, to)
        }
        panel.onRename = { [weak self] index in
            // Both are key-taking panels, so this one has to leave first.
            self?.hide()
            self?.onRename?(index)
        }
        panel.onDismiss = { [weak self] in self?.panel = nil }
        panel.build()
        self.panel = panel
        panel.present()
    }
}

/// Needs keyboard focus, so it restores whatever was frontmost on the way out.
final class OverviewPanel: OverlayPanel {
    var items: [WorkspaceOverview.Item] = []
    var cardSize = CGSize(width: 132, height: 108)
    var gap: CGFloat = 12
    var padding: CGFloat = 22
    var columns = 5
    var accent: NSColor = .controlAccentColor
    var selection = 0 { didSet { refresh() } }
    var onPick: ((Int) -> Void)?
    var onPickWindow: ((SurfaceID) -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private var cards: [NSView] = []
    private var homePositions: [CGRect] = []
    private var previouslyActive: NSRunningApplication?

    // Drag state. A press only becomes a drag once it travels far enough, so a
    // click with a shaky hand still means "jump to this workspace".
    var isDragging: Bool { dragIndex != nil }

    private var dragIndex: Int?
    private var dragOrigin: CGPoint = .zero
    private var didDrag = false
    private var dropTarget: Int?
    private static let dragThreshold: CGFloat = 6

    override var canBecomeKey: Bool { true }

    func build() {
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        homePositions.removeAll()

        let title = NSTextField(labelWithString: "WORKSPACES")
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.frame = CGRect(x: padding, y: frame.height - padding - 4, width: 200, height: 14)
        contentView?.addSubview(title)

        let hint = NSTextField(labelWithString: "number to jump  ·  click an app to go to it  ·  drag to reorder  ·  R to rename")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        hint.frame = CGRect(x: frame.width - padding - 420, y: frame.height - padding - 4,
                            width: 420, height: 14)
        contentView?.addSubview(hint)

        for (offset, item) in items.enumerated() {
            let row = offset / columns
            let column = offset % columns
            let x = padding + CGFloat(column) * (cardSize.width + gap)
            let y = frame.height - padding - 26 - CGFloat(row + 1) * cardSize.height - CGFloat(row) * gap

            let card = NSView(frame: CGRect(x: x, y: y, width: cardSize.width, height: cardSize.height))
            card.wantsLayer = true
            card.layer?.cornerRadius = 12
            card.layer?.cornerCurve = .continuous

            let number = NSTextField(labelWithString: "\(item.index)")
            number.font = .systemFont(ofSize: 30, weight: .medium)
            number.alignment = .center
            number.frame = CGRect(x: 0, y: cardSize.height - 52, width: cardSize.width, height: 38)
            card.addSubview(number)

            let label = NSTextField(labelWithString: item.name ?? "—")
            label.font = .systemFont(ofSize: 12, weight: item.name == nil ? .regular : .medium)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = CGRect(x: 6, y: 32, width: cardSize.width - 12, height: 16)
            card.addSubview(label)

            // What is actually in there. Seeing the apps is the difference between
            // picking the right workspace and cycling through them.
            if item.entries.isEmpty {
                let empty = NSTextField(labelWithString: "empty")
                empty.font = .systemFont(ofSize: 10.5)
                empty.textColor = .tertiaryLabelColor
                empty.alignment = .center
                empty.frame = CGRect(x: 4, y: 12, width: cardSize.width - 8, height: 14)
                card.addSubview(empty)
            } else {
                let iconSize: CGFloat = 20, iconGap: CGFloat = 4
                let shown = Array(item.entries.prefix(5))
                let overflow = item.entries.count - shown.count
                var width = CGFloat(shown.count) * iconSize + CGFloat(max(0, shown.count - 1)) * iconGap
                if overflow > 0 { width += iconGap + 18 }
                var x = (cardSize.width - width) / 2
                for entry in shown {
                    let button = IconButton(frame: CGRect(x: x, y: 10, width: iconSize, height: iconSize))
                    button.image = entry.icon
                    button.surface = entry.id
                    button.toolTip = entry.title.isEmpty ? nil : entry.title
                    button.onPick = { [weak self] id in self?.onPickWindow?(id) }
                    card.addSubview(button)
                    x += iconSize + iconGap
                }
                if overflow > 0 {
                    let more = NSTextField(labelWithString: "+\(overflow)")
                    more.font = .systemFont(ofSize: 10, weight: .medium)
                    more.textColor = .tertiaryLabelColor
                    more.frame = CGRect(x: x + iconGap, y: 12, width: 20, height: 14)
                    card.addSubview(more)
                }
            }

            contentView?.addSubview(card)
            cards.append(card)
            homePositions.append(card.frame)
        }
        refresh()
    }

    private func refresh() {
        for (offset, card) in cards.enumerated() {
            let item = items[offset]
            // While dragging, the highlight follows the drop slot rather than the
            // keyboard selection, so the panel shows where the card will land.
            let selected = dragIndex != nil ? offset == dropTarget : offset == selection
            card.layer?.backgroundColor = selected
                ? accent.withAlphaComponent(0.22).cgColor
                : NSColor.labelColor.withAlphaComponent(item.windows > 0 ? 0.08 : 0.035).cgColor
            card.layer?.borderWidth = selected ? 2 : (item.isActive ? 1.5 : 0)
            card.layer?.borderColor = selected
                ? accent.cgColor
                : accent.withAlphaComponent(0.45).cgColor
        }
    }

    func present() {
        previouslyActive = NSWorkspace.shared.frontmostApplication
        centerOnActiveScreen(verticalBias: 0.45)
        NSApp.activate(ignoringOtherApps: true)
        fadeIn()
        makeKey()
    }

    func dismiss() {
        let restore = previouslyActive
        fadeOut { [weak self] in
            restore?.activate()
            self?.onDismiss?()
        }
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  dismiss()                                    // escape
        case 36, 76: commit()                                  // return / enter
        case 123: move(by: -1)                                 // left
        case 124: move(by: 1)                                  // right
        case 126: move(by: -columns)                           // up
        case 125: move(by: columns)                            // down
        case 15:                                               // r
            guard items.indices.contains(selection) else { return }
            onRename?(items[selection].index)
        default:
            // Typing a number jumps straight there — the whole point of the panel.
            guard let characters = event.charactersIgnoringModifiers,
                  let value = Int(characters),
                  let target = items.firstIndex(where: { $0.index == value }) else { return }
            selection = target
            commit()
        }
    }

    // MARK: Drag to reorder

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        guard let index = homePositions.firstIndex(where: { $0.contains(point) }) else {
            dismiss()
            return
        }
        if event.clickCount == 2 {
            selection = index
            onRename?(items[index].index)
            return
        }
        dragIndex = index
        dragOrigin = point
        didDrag = false
        dropTarget = index
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragIndex else { return }
        let point = event.locationInWindow
        if !didDrag {
            let travelled = hypot(point.x - dragOrigin.x, point.y - dragOrigin.y)
            guard travelled > Self.dragThreshold else { return }
            didDrag = true
            // Lift the card: raised above its neighbours and slightly transparent,
            // so it reads as being carried rather than as a layout glitch.
            let card = cards[index]
            card.layer?.zPosition = 10
            card.layer?.shadowColor = NSColor.black.cgColor
            card.layer?.shadowOpacity = 0.35
            card.layer?.shadowRadius = 14
            card.layer?.shadowOffset = .zero
            card.alphaValue = 0.9
        }
        cards[index].frame = homePositions[index]
            .offsetBy(dx: point.x - dragOrigin.x, dy: point.y - dragOrigin.y)

        let target = slot(under: point) ?? index
        guard target != dropTarget else { return }
        dropTarget = target
        reflow(dragging: index, to: target)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragIndex = nil
            didDrag = false
            dropTarget = nil
        }
        guard let index = dragIndex else { return }

        let card = cards[index]
        card.layer?.zPosition = 0
        card.layer?.shadowOpacity = 0
        card.alphaValue = 1

        guard didDrag else {
            // Never travelled: this was a click, so jump.
            selection = index
            commit()
            return
        }

        let target = slot(under: event.locationInWindow) ?? index
        guard target != index else {
            // Put everything back where it started.
            settleAllCards()
            refresh()
            return
        }

        // Let the card land in its new slot before the panel closes, so the drop
        // reads as completing rather than as the window vanishing.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.reflowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().frame = self.homePositions[target]
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.onReorder?(self.items[index].index, self.items[target].index)
        })
    }

    /// Slide every other card into the arrangement the drop would produce, so the
    /// gap opens up under the cursor before you let go. Without this the drag has
    /// no visual language at all — nothing suggests a reorder is even possible.
    private func reflow(dragging index: Int, to target: Int) {
        var order = Array(cards.indices)
        let moved = order.remove(at: index)
        order.insert(moved, at: min(max(0, target), order.count))

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reflowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            for (slot, card) in order.enumerated() where card != index {
                cards[card].animator().frame = homePositions[slot]
            }
        }
    }

    /// Honour the system setting rather than animating over someone who asked for
    /// less motion.
    private static var reflowDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
    }

    private func settleAllCards() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reflowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (slot, card) in cards.enumerated() {
                card.animator().frame = homePositions[slot]
            }
        }
    }

    /// Which slot the cursor is over. Uses the cards' home positions, not their
    /// live frames — the card being carried has left its own slot.
    private func slot(under point: CGPoint) -> Int? {
        if let exact = homePositions.firstIndex(where: { $0.contains(point) }) { return exact }
        // Past the end of a row or below the grid: fall to the nearest centre, so
        // a drop into the gaps still means something.
        var best: (index: Int, distance: CGFloat)?
        for (index, frame) in homePositions.enumerated() {
            let distance = hypot(frame.midX - point.x, frame.midY - point.y)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(items.count - 1, max(0, selection + delta))
    }

    private func commit() {
        guard items.indices.contains(selection) else { return dismiss() }
        onPick?(items[selection].index)
    }
}


/// One window in the overview: its application's icon, its title as a tooltip, and a
/// click that goes to it. A plain view rather than an `NSButton` because the panel
/// tracks its own mouse events for dragging workspaces around, and a button would
/// swallow the ones that begin a drag.
final class IconButton: NSView {
    var image: NSImage?
    var surface: SurfaceID?
    var onPick: ((SurfaceID) -> Void)?
    private var hovering = false

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5).fill()
        }
        image?.draw(in: bounds, from: .zero, operation: .sourceOver,
                    fraction: hovering ? 1 : 0.92, respectFlipped: true, hints: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { /* swallow, so the card does not start a drag */ }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), let surface else { return }
        onPick?(surface)
    }
}
