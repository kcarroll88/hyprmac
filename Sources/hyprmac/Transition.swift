import AppKit
import HyprCore
import HyprKit

/// A crossfade through the desktop when changing workspace.
///
/// Nothing public can fade another application's window — the Accessibility API
/// has position and size and no more. What can fade is a window of our own. So
/// this is an overlay painted as the desktop with the *next* workspace's empty
/// slots on it: it fades in over the current windows, the switch happens under
/// it in a few milliseconds, and it fades out to reveal the new windows already
/// sitting in the slots it showed. The windows read as dissolving into the desktop
/// and the next set dissolving back in — and the parking moves, tiny as they are,
/// happen while nothing but the overlay is on screen.
///
/// Interruptible: a second switch mid-fade lands under the overlay and restarts
/// the fade out, so holding the bracket key steps cleanly rather than stacking
/// fades.
final class WorkspaceTransition {
    private enum Phase { case idle, fadingIn, fadingOut }

    private var panel: NSPanel?
    private let view = CanvasView()
    private var phase: Phase = .idle
    private var generation = 0
    private var pending: (() -> Void)?

    /// Whether to animate at all. Respects the system's Reduce Motion setting,
    /// which on macOS is a promise that things do not crossfade at you.
    static func shouldAnimate(_ config: Config) -> Bool {
        config.animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Fade to `model`, run `switching` while covered, fade back.
    func run(model: CanvasModel, config: Config, duration: TimeInterval, switching: @escaping () -> Void) {
        let panel = panel ?? makePanel()
        view.model = model
        view.config = config
        view.windowOriginInCocoa = panel.frame.origin
        view.needsDisplay = true
        pending = switching

        switch phase {
        case .idle:
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            phase = .fadingIn
            NSAnimationContext.runAnimationGroup({ context in
                // The way out is quicker than the way in: the user has already
                // decided to leave, and what they are waiting for is the arrival.
                context.duration = duration * 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in self?.reveal(duration: duration) })
        case .fadingIn:
            // Already on the way; `reveal` runs whatever is pending by then.
            break
        case .fadingOut:
            // Snap back to opaque, switch again underneath, fade out afresh.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            reveal(duration: duration)
        }
    }

    private func reveal(duration: TimeInterval) {
        guard let panel else { return }
        pending?()
        pending = nil
        generation += 1
        let mine = generation
        phase = .fadingOut
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration * 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == mine, self.phase == .fadingOut else { return }
            self.phase = .idle
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let screen = NSScreen.screens.first?.frame ?? .zero
        let panel = NSPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = view
        // Above the tiles and above the corner covers; below the menu bar, the
        // Dock, and the workspace HUD, all of which should stay readable through
        // a switch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0
        self.panel = panel
        return panel
    }
}
