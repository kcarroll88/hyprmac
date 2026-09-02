import AppKit
import HyprCore

/// A floating panel in the system's own HUD material — the look macOS uses for the
/// volume and brightness overlays. Never takes focus, never joins the window cycle.
class OverlayPanel: NSPanel {
    init(size: CGSize, cornerRadius: CGFloat = 18) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenNone]

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous   // matches macOS window corners
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        contentView = effect
    }

    override var canBecomeKey: Bool { false }

    func centerOnActiveScreen(verticalBias: CGFloat = 0.5) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2,
                               y: visible.minY + (visible.height - frame.height) * verticalBias))
    }

    func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func fadeOut(then: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({
            $0.duration = 0.22
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            then?()
        })
    }
}

/// Brief workspace overlay on switch, in the spirit of the system volume HUD:
/// the number, and a row of pips for the other workspaces.
final class WorkspaceHUD {
    private var panel: OverlayPanel?
    private var dismissal: Timer?

    func show(workspace: Int, name: String?, of all: [Int], occupied: Set<Int>, accent: NSColor) {
        let panel = self.panel ?? OverlayPanel(size: CGSize(width: 180, height: 180), cornerRadius: 22)
        self.panel = panel

        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }

        let number = NSTextField(labelWithString: "\(workspace)")
        number.font = .systemFont(ofSize: 76, weight: .medium)
        number.textColor = .labelColor
        number.alignment = .center
        number.frame = CGRect(x: 0, y: 52, width: 180, height: 88)
        panel.contentView?.addSubview(number)

        let pips = NSView(frame: CGRect(x: 0, y: 30, width: 180, height: 10))
        let diameter: CGFloat = 7
        let spacing: CGFloat = 6
        let total = CGFloat(all.count) * diameter + CGFloat(max(0, all.count - 1)) * spacing
        var x = (180 - total) / 2
        for index in all {
            let dot = NSView(frame: CGRect(x: x, y: 0, width: diameter, height: diameter))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = diameter / 2
            dot.layer?.backgroundColor = index == workspace
                ? accent.cgColor
                : NSColor.labelColor.withAlphaComponent(occupied.contains(index) ? 0.5 : 0.18).cgColor
            pips.addSubview(dot)
            x += diameter + spacing
        }
        panel.contentView?.addSubview(pips)

        if let name, !name.isEmpty {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = CGRect(x: 10, y: 46, width: 160, height: 18)
            panel.contentView?.addSubview(label)
            // Make room for it by lifting the number and pips.
            number.frame = number.frame.offsetBy(dx: 0, dy: 12)
            pips.frame = pips.frame.offsetBy(dx: 0, dy: -6)
        }

        panel.centerOnActiveScreen(verticalBias: 0.22)
        panel.fadeIn()

        dismissal?.invalidate()
        dismissal = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: false) { [weak panel] _ in
            panel?.fadeOut()
        }
    }
}

/// A sheet that goes away the way people expect one to: Escape, any key, a click
/// anywhere, or the shortcut that opened it.
final class SheetPanel: OverlayPanel {
    var onDismiss: (() -> Void)?
    private var previouslyActive: NSRunningApplication?

    override var canBecomeKey: Bool { true }

    func present() {
        previouslyActive = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        fadeIn()
        makeKey()
    }

    func dismiss() {
        let restore = previouslyActive
        previouslyActive = nil
        fadeOut { [weak self] in
            restore?.activate()
            self?.onDismiss?()
        }
    }

    override func keyDown(with event: NSEvent) { dismiss() }
    override func mouseDown(with event: NSEvent) { dismiss() }
    override func cancelOperation(_ sender: Any?) { dismiss() }
}

/// The keybinding sheet. Built from the live config, so it can never drift from
/// what is actually bound.
final class Cheatsheet {
    private var panel: SheetPanel?
    /// Tracked explicitly rather than read off the window: a panel mid-fade still
    /// reports itself visible, which made the toggle stack a second sheet on top
    /// of the first instead of closing it.
    private var shown = false

    var isVisible: Bool { shown }

    func toggle(binds: [Bind]) {
        if shown { hide() } else { show(binds: binds) }
    }

    func hide() {
        shown = false
        panel?.dismiss()
        panel = nil
    }

    func show(binds: [Bind]) {
        // Group by category, preserving the order the categories first appear.
        var order: [String] = []
        var grouped: [String: [Bind]] = [:]
        for bind in binds {
            let key = bind.dispatcher.category
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(bind)
        }

        let columnWidth: CGFloat = 300
        let rowHeight: CGFloat = 24
        let headerHeight: CGFloat = 34
        let padding: CGFloat = 28

        // Two columns, balanced by row count.
        let totalRows = binds.count + order.count
        let perColumn = Int((Double(totalRows) / 2).rounded(.up))
        var columns: [[String]] = [[], []]
        var columnRows = [0, 0]
        var current = 0
        for category in order {
            let rows = (grouped[category]?.count ?? 0) + 1
            if columnRows[current] + rows > perColumn && current == 0 { current = 1 }
            columns[current].append(category)
            columnRows[current] += rows
        }

        let contentHeight = CGFloat(max(columnRows[0], columnRows[1])) * rowHeight
            + CGFloat(max(columns[0].count, columns[1].count)) * (headerHeight - rowHeight)
        let size = CGSize(width: columnWidth * 2 + padding * 3,
                          height: contentHeight + padding * 2 + 30)

        panel?.orderOut(nil)
        let panel = SheetPanel(size: size, cornerRadius: 20)
        panel.onDismiss = { [weak self] in
            self?.shown = false
            self?.panel = nil
        }
        self.panel = panel
        shown = true

        let title = NSTextField(labelWithString: "Keybindings")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.frame = CGRect(x: padding, y: size.height - padding - 6, width: 300, height: 22)
        panel.contentView?.addSubview(title)

        // Say how to leave. A sheet with no visible exit is the reason this one
        // felt stuck even once it could be closed.
        let dismissHint = NSTextField(labelWithString: "esc  or click anywhere")
        dismissHint.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        dismissHint.textColor = .tertiaryLabelColor
        dismissHint.alignment = .right
        dismissHint.frame = CGRect(x: size.width - padding - 220,
                                   y: size.height - padding - 2, width: 220, height: 16)
        panel.contentView?.addSubview(dismissHint)

        for (index, categories) in columns.enumerated() {
            var y = size.height - padding - 40
            let x = padding + CGFloat(index) * (columnWidth + padding)
            for category in categories {
                let header = NSTextField(labelWithString: category.uppercased())
                header.font = .systemFont(ofSize: 10, weight: .semibold)
                header.textColor = .secondaryLabelColor
                header.frame = CGRect(x: x, y: y, width: columnWidth, height: 16)
                panel.contentView?.addSubview(header)
                y -= headerHeight - rowHeight + 4

                for bind in grouped[category] ?? [] {
                    y -= rowHeight
                    let shortcut = NSTextField(labelWithString:
                        bind.modifiers.symbolic + KeyCode.symbol(for: bind.keyCode))
                    shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                    shortcut.textColor = .labelColor
                    shortcut.alignment = .right
                    shortcut.frame = CGRect(x: x, y: y, width: 78, height: 18)
                    panel.contentView?.addSubview(shortcut)

                    let label = NSTextField(labelWithString: bind.dispatcher.label)
                    label.font = .systemFont(ofSize: 12)
                    label.textColor = .secondaryLabelColor
                    label.lineBreakMode = .byTruncatingTail
                    label.frame = CGRect(x: x + 90, y: y, width: columnWidth - 90, height: 18)
                    panel.contentView?.addSubview(label)
                }
                y -= 10
            }
        }

        panel.centerOnActiveScreen()
        panel.present()
    }
}
