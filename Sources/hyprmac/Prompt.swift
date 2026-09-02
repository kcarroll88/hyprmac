import AppKit
import HyprCore

/// A single-line text prompt in the system HUD material.
///
/// Unlike the other overlays this one has to take keyboard focus, so it restores
/// focus to whatever had it when dismissed — otherwise renaming a workspace would
/// leave you typing into nothing.
final class PromptPanel: OverlayPanel {
    private let field = NSTextField()
    private var onCommit: ((String) -> Void)?
    private var onDismiss: (() -> Void)?
    private var previouslyActive: NSRunningApplication?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(size: CGSize(width: 420, height: 96), cornerRadius: 18)
    }

    func ask(title: String, initial: String, accent: NSColor,
             onCommit: @escaping (String) -> Void,
             onDismiss: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        previouslyActive = NSWorkspace.shared.frontmostApplication

        contentView?.subviews.forEach { $0.removeFromSuperview() }

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = CGRect(x: 20, y: 62, width: 380, height: 16)
        contentView?.addSubview(label)

        field.stringValue = initial
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.frame = CGRect(x: 18, y: 20, width: 384, height: 32)
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.35)
        field.focusRingType = .none
        field.textColor = .labelColor
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.layer?.borderWidth = 1
        field.layer?.borderColor = accent.withAlphaComponent(0.5).cgColor
        contentView?.addSubview(field)

        centerOnActiveScreen(verticalBias: 0.62)
        // The WM runs as an accessory, so it has to ask for activation before any
        // panel of ours can receive keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        fadeIn()
        makeKey()
        field.selectText(nil)
    }

    @objc private func commit() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finish { self.onCommit?(value) }
    }

    private func cancel() { finish {} }

    private func finish(_ action: @escaping () -> Void) {
        let restore = previouslyActive
        fadeOut { [weak self] in
            action()
            restore?.activate()
            self?.onDismiss?()
        }
    }

    override func cancelOperation(_ sender: Any?) { cancel() }
}

extension PromptPanel: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}
