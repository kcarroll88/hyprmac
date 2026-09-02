import AppKit
import HyprCore

/// Menu bar presence.
///
/// A tiling WM on Linux advertises itself with a bar across the top of the screen.
/// On a Mac there is already a bar there, and putting a second one below it is the
/// single most out-of-place thing this project could do. So the workspace
/// indicator lives in the menu bar, like every other Mac utility.
final class StatusItemController {
    private var item: NSStatusItem?
    private var workspaceCount = 5
    private var active = 1
    private var occupied: Set<Int> = []
    private var names: [Int: String] = [:]

    var onSelectWorkspace: ((Int) -> Void)?
    var onRenameWorkspace: ((Int) -> Void)?
    var onShowKeybindings: (() -> Void)?
    var onShowWelcome: (() -> Void)?
    var onReload: (() -> Void)?
    var onQuit: (() -> Void)?

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        self.item = item
        rebuild()
    }

    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    func update(active: Int, count: Int, occupied: Set<Int>, names: [Int: String]) {
        self.active = active
        self.workspaceCount = count
        self.occupied = occupied
        self.names = names
        rebuild()
    }

    /// A named workspace is worth reading; an unnamed one is just its number.
    private func label(_ index: Int) -> String {
        names[index].map { "\(index) · \($0)" } ?? "Workspace \(index)"
    }

    private func rebuild() {
        guard let item else { return }

        // Filled dot for the current workspace, hollow for ones holding windows,
        // nothing for empty ones — compact enough to belong in a menu bar.
        let pips = (1...workspaceCount).map { index -> String in
            if index == active { return "\u{25CF}" }
            return occupied.contains(index) ? "\u{25CB}" : "\u{00B7}"
        }.joined()
        // The dots alone say where you are; the name says what you are doing.
        if let name = names[active] {
            item.button?.title = "\(pips)  \(name)"
        } else {
            item.button?.title = pips
        }

        let menu = NSMenu()
        for index in 1...workspaceCount {
            let entry = NSMenuItem(title: label(index),
                                   action: #selector(selectWorkspace(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = index == active ? .on : .off
            if occupied.contains(index) && index != active {
                entry.attributedTitle = NSAttributedString(
                    string: label(index),
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            }
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        // Renaming lives in a submenu so any workspace can be renamed, not only
        // the one you happen to be looking at.
        let renameItem = NSMenuItem(title: "Rename Workspace", action: nil, keyEquivalent: "")
        let renameMenu = NSMenu()
        for index in 1...workspaceCount {
            let target = NSMenuItem(title: "\(label(index))…",
                                    action: #selector(renameWorkspace(_:)), keyEquivalent: "")
            target.target = self
            target.tag = index
            renameMenu.addItem(target)
        }
        renameItem.submenu = renameMenu
        menu.addItem(renameItem)

        menu.addItem(entry(title: "Keybindings…", action: #selector(showKeybindings)))
        // The one screen hyprmac has, reachable on purpose rather than only when it
        // decides to appear: permissions, the trackpad gesture, and the keys.
        menu.addItem(entry(title: "Setup…", action: #selector(showWelcome)))
        menu.addItem(entry(title: "Reload Configuration", action: #selector(reload)))
        menu.addItem(.separator())
        menu.addItem(entry(title: "Quit hyprmac", action: #selector(quit)))
        item.menu = menu
    }

    private func entry(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func selectWorkspace(_ sender: NSMenuItem) { onSelectWorkspace?(sender.tag) }
    @objc private func renameWorkspace(_ sender: NSMenuItem) { onRenameWorkspace?(sender.tag) }
    @objc private func showKeybindings() { onShowKeybindings?() }
    @objc private func showWelcome() { onShowWelcome?() }
    @objc private func reload() { onReload?() }
    @objc private func quit() { onQuit?() }
}
