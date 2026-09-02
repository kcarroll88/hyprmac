import AppKit
import HyprCore
import HyprKit
import ServiceManagement

/// The first thing a new user sees, and the only screen hyprmac has.
///
/// A tiling window manager cannot move a single window until macOS trusts it, and
/// nothing in the app used to ask: launched on a fresh Mac it came up, failed every
/// Accessibility call in silence, and looked broken. This window is the answer to
/// that — it states the one permission needed and why, opens the right settings pane,
/// notices the moment the grant lands, and offers the restart that makes it take.
/// It shows itself once, and any time the grant is missing.
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindow()

    /// The build this screen was last dismissed for. Not a boolean: "have they seen
    /// it" was a one-way flag three times over, and each time it made the screen
    /// unreachable on a machine that needed it — after an uninstall, after a
    /// reinstall, after the gesture was handed back. A new build is a new install,
    /// and an install is exactly when someone wants to see that it is set up right.
    private static let buildKey = "welcomeShownForBuild"
    private var window: NSWindow?
    private var poll: Timer?
    private var statusDot: NSView?
    private var statusLabel: NSTextField?
    private var actionButton: NSButton?
    private var loginToggle: NSButton?
    private var gestureBody: NSTextField?
    private var gestureStatus: NSTextField?
    private var gestureButton: NSButton?
    private var gestureDot: NSView?
    /// Whether the manager started without the grant. Accessibility observers are
    /// registered at launch, so a grant that arrives afterwards needs a restart to
    /// be of any use — offering it is honest, and one click.
    private var startedUntrusted = false
    /// Shown before hyprmac manages anything, because macOS has not trusted it yet.
    /// Closing the window in this state does not quit: the app goes on waiting.
    private var waiting = false
    /// Whether hyprmac uses the up-and-down swipe. When it does not — the default —
    /// Mission Control is left alone and only the sideways swipe is asked for.
    private var usesVerticalSwipe = false

    /// Nothing is managed yet; this is the only thing on screen.
    func showWaitingForAccessibility() {
        startedUntrusted = true
        waiting = true
        show()
    }

    func showIfNeeded(usesVerticalSwipe: Bool) {
        self.usesVerticalSwipe = usesVerticalSwipe
        startedUntrusted = !Accessibility.isTrusted
        // Three reasons to show, and none of them is a flag that can get stuck: this
        // build has not been dismissed yet (so every install shows it), the one
        // permission is missing, or macOS still has a claim on the swipe. The last
        // one repeats every launch until it is actually settled — which is the point.
        // It stops the moment the clash is gone, and `Setup…` opens it any time.
        let seenThisBuild = UserDefaults.standard.string(forKey: Self.buildKey) == Self.buildStamp
        let clash = SystemGestures.conflict(usesVertical: usesVerticalSwipe).any
        guard !seenThisBuild || !Accessibility.isTrusted || clash else { return }
        show()
    }

    /// Asked for from the menu bar. Always opens, whatever has been seen before.
    /// Identifies this build, so a new one shows the screen again. The version alone
    /// would not: every build tonight was 0.1.0.
    private static var buildStamp: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let built = (Bundle.main.executableURL?.path).flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        return "\(version)@\(built.map { Int($0.timeIntervalSince1970) } ?? 0)"
    }

    func showOnDemand(usesVerticalSwipe: Bool) {
        self.usesVerticalSwipe = usesVerticalSwipe
        waiting = false
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // ARC owns this window through `self.window`. AppKit's default for a window
        // built in code is to release it again when it closes, and the second release
        // lands on freed memory: closing the welcome screen crashed hyprmac outright,
        // which read to the user as "closing the window quit it". It did — through
        // objc_release in an autorelease pool pop, with a crash report to prove it.
        window.isReleasedWhenClosed = false
        window.title = "hyprmac"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()
        window.contentView = buildContent()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // The grant is given in System Settings, not here, so watch for it.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPermission()
        }
        refreshPermission()
    }

    func windowWillClose(_ notification: Notification) {
        // Not while waiting for the grant: this screen has not been seen in the
        // sense that matters until hyprmac is actually running, and marking it seen
        // would cost the user the gesture card on the launch that follows.
        if !waiting { UserDefaults.standard.set(Self.buildStamp, forKey: Self.buildKey) }
        poll?.invalidate(); poll = nil
        window = nil
    }

    // MARK: Content

    private func buildContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Icon and name.
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 14
        header.alignment = .centerY
        if let icon = NSApp.applicationIconImage {
            let view = NSImageView(image: icon)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 56).isActive = true
            view.heightAnchor.constraint(equalToConstant: 56).isActive = true
            header.addArrangedSubview(view)
        }
        let names = NSStackView()
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2
        names.addArrangedSubview(label("hyprmac", size: 26, weight: .semibold))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        names.addArrangedSubview(label("Version \(version) — beta · build \(build)", size: 12, colour: .secondaryLabelColor))
        header.addArrangedSubview(names)
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(wrapping("A tiling window manager for macOS, in the shape of Hyprland. "
                                        + "Windows arrange themselves; the keyboard moves you around them.", width: 456))

        // The one permission.
        stack.addArrangedSubview(permissionCard())

        // macOS's own three-finger swipe, if it is still holding it. Never while
        // waiting for the grant — one thing at a time, and it will be offered on
        // the launch that follows.
        if !waiting, SystemGestures.conflict(usesVertical: usesVerticalSwipe).any {
            stack.addArrangedSubview(gestureCard())
        }

        // Login item.
        let toggle = NSButton(checkboxWithTitle: "Open hyprmac when I log in", target: self, action: #selector(toggleLogin))
        toggle.state = Self.isLoginItem ? .on : .off
        loginToggle = toggle
        stack.addArrangedSubview(toggle)

        stack.addArrangedSubview(separator(width: 456))
        stack.addArrangedSubview(label("The keys worth knowing", size: 13, weight: .semibold))
        stack.addArrangedSubview(keyGrid())

        // Footer.
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        let done = NSButton(title: "Start tiling", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        actionButton = done
        footer.addArrangedSubview(done)
        if waiting {
            let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
            quit.bezelStyle = .rounded
            footer.addArrangedSubview(quit)
            footer.addArrangedSubview(label("allow it in System Settings, then restart", size: 11, colour: .tertiaryLabelColor))
        } else {
            footer.addArrangedSubview(label("ALT+/ shows every binding", size: 11, colour: .tertiaryLabelColor))
        }
        stack.addArrangedSubview(footer)

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
        ])
        return background
    }

    private func permissionCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot = dot

        let title = NSStackView()
        title.orientation = .horizontal
        title.spacing = 8
        title.alignment = .centerY
        title.addArrangedSubview(dot)
        title.addArrangedSubview(label("Accessibility", size: 14, weight: .semibold))
        let status = label("checking…", size: 12, colour: .secondaryLabelColor)
        statusLabel = status
        title.addArrangedSubview(status)

        // When something is provably wrong, say that instead of the general
        // explanation: someone staring at a restart loop does not need to be told
        // what the Accessibility API is for.
        let explanation: String
        if Self.isTranslocated {
            explanation = "hyprmac is running from a copy macOS made for it, because it was opened from "
                        + "the disk image or the Downloads folder. That copy is somewhere new every "
                        + "launch, so no permission can stick to it. Quit hyprmac, drag it into "
                        + "Applications, and open it from there."
        } else if waiting, Self.restartDidNotHelp {
            explanation = "hyprmac restarted after the permission was given and still cannot see it. "
                        + "That is almost always an entry left over from an earlier copy: open System "
                        + "Settings ▸ Privacy & Security ▸ Accessibility, select hyprmac, remove it "
                        + "with the − button, then add this copy and allow it."
        } else {
            explanation = "hyprmac moves and resizes windows through the Accessibility API — the only "
                        + "way on macOS with System Integrity Protection left on. It reads window "
                        + "positions and titles, and nothing it sees leaves your Mac."
        }
        let body = wrapping(explanation, width: 400)

        let button = NSButton(title: "Open System Settings…", target: self, action: #selector(openSettings))
        button.bezelStyle = .rounded

        let stack = NSStackView(views: [title, body, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            card.widthAnchor.constraint(equalToConstant: 456),
        ])
        return card
    }

    /// Offered only when macOS is actually holding the gesture, so a machine that
    /// has nothing wrong with it never sees a card about a problem it does not have.
    private func gestureCard() -> NSView {
        let conflict = SystemGestures.conflict(usesVertical: usesVerticalSwipe)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        gestureDot = dot

        let status = label(conflict.onlyNeedsLogout ? "waiting for a logout"
                         : conflict.visible ? "in use by macOS" : "shared with macOS",
                           size: 12, colour: .secondaryLabelColor)
        gestureStatus = status
        let title = NSStackView(views: [dot, label("The three-finger swipe", size: 14, weight: .semibold), status])
        title.orientation = .horizontal
        title.spacing = 8
        title.alignment = .centerY

        let kept = usesVerticalSwipe
            ? "Handing it over turns off the two three-finger swipes in System Settings; every other gesture stays."
            : "Handing it over turns off only the sideways three-finger swipe. Mission Control keeps three fingers up, and every other gesture stays."
        let body = wrapping(conflict.onlyNeedsLogout
                            ? conflict.summary
                            : conflict.summary + " hyprmac reads the trackpad without taking the "
                              + "gesture away, so both happen. " + kept, width: 400)
        gestureBody = body

        let button = conflict.onlyNeedsLogout
            ? NSButton(title: "Log out…", target: self, action: #selector(logOut))
            : NSButton(title: "Give it to hyprmac", target: self, action: #selector(releaseGesture))
        button.bezelStyle = .rounded
        gestureButton = button

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, body, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            card.widthAnchor.constraint(equalToConstant: 456),
        ])
        return card
    }

    @objc private func releaseGesture() {
        SystemGestures.release(vertical: usesVerticalSwipe)
        gestureDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
        gestureStatus?.stringValue = "waiting for a logout"
        gestureBody?.stringValue = (usesVerticalSwipe
            ? "macOS has been told to let the three-finger swipes go. "
            : "macOS has been told to let the sideways three-finger swipe go, and to keep Mission Control. ")
            + "It reads that setting only when you log in, so until you log out and back in a swipe "
            + "still changes desktop as well as workspace. If you remove hyprmac later, turn this "
            + "back on in System Settings ▸ Trackpad ▸ More Gestures."
        // Not "Done": the file has changed, the running system has not. Saying done
        // here is how a user ends up swiping into two window managers and believing
        // hyprmac is broken.
        gestureButton?.title = "Log out…"
        gestureButton?.target = self
        gestureButton?.action = #selector(logOut)
    }

    @objc private func logOut() {
        SystemGestures.logOut()
    }

    private func keyGrid() -> NSView {
        let keys: [(String, String)] = [
            ("ALT + Return", "a terminal"),
            ("ALT + 1…5", "workspaces"),
            ("ALT + H J K L", "move the focus"),
            ("ALT + SHIFT + H J K L", "move the window"),
            ("ALT + `", "overview of every workspace"),
            ("ALT + Q", "close the window"),
            ("ALT + SHIFT + Q", "quit hyprmac"),
        ]
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5
        for (key, meaning) in keys {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            let k = label(key, size: 11, weight: .medium, monospaced: true)
            k.translatesAutoresizingMaskIntoConstraints = false
            k.widthAnchor.constraint(equalToConstant: 168).isActive = true
            row.addArrangedSubview(k)
            row.addArrangedSubview(label(meaning, size: 11, colour: .secondaryLabelColor))
            rows.addArrangedSubview(row)
        }
        return rows
    }

    // MARK: Permission

    private func refreshPermission() {
        let trusted = Accessibility.isTrusted
        statusDot?.layer?.backgroundColor = (trusted ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        statusLabel?.stringValue = trusted
            ? (startedUntrusted ? "allowed — restart to pick it up" : "allowed")
            : "not yet allowed"
        if trusted, startedUntrusted {
            actionButton?.title = "Restart hyprmac"
        } else if waiting {
            // Always pressable. macOS caches a process's trust at launch, so a
            // process that started without the grant can go on reporting "not
            // allowed" long after the box is ticked — and a button that stays
            // disabled until it notices leaves the user with the permission given
            // and nothing on screen that will accept it. Restarting is what makes
            // the grant real anyway, so offer that from the start.
            actionButton?.title = trusted ? "Restart hyprmac" : "I've allowed it — restart"
            actionButton?.isEnabled = true
        } else {
            actionButton?.title = trusted ? "Start tiling" : "Continue without it"
        }
    }

    @objc private func openSettings() {
        // Asking through the API is what puts hyprmac in the list at all; the URL
        // then takes the user straight to the switch rather than hunting for it.
        _ = Accessibility.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func finish() {
        // In waiting mode the restart is the whole point: a new process is the only
        // one that can see a grant made after it started.
        if waiting || (Accessibility.isTrusted && startedUntrusted) { Self.relaunch(); return }
        window?.close()
    }

    // MARK: Login item

    private static var isLoginItem: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            log("welcome: could not \(sender.state == .on ? "add" : "remove") the login item — \(error.localizedDescription)")
            sender.state = Self.isLoginItem ? .on : .off
        }
    }

    /// Start a fresh copy and stand down. The single-instance guard makes the new
    /// one quit if it starts too early, so the relaunch waits for this one to go.
    static let relaunchedKey = "relaunchedForAccessibilityAt"

    /// Running from a randomised read-only copy. macOS does this to a quarantined app
    /// opened from a disk image or the Downloads folder, and the path is different
    /// every launch — so no permission can ever stick to it, and the grant is given
    /// to a copy that will not exist next time.
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    /// This process started right after hyprmac restarted itself to pick up the
    /// grant, and is *still* untrusted. Restarting again would do the same thing
    /// forever: grant seen, restart, not seen, wait, grant seen… Something else is
    /// wrong, and the only useful move is to stop and say so.
    static var restartDidNotHelp: Bool {
        let at = UserDefaults.standard.double(forKey: relaunchedKey)
        return at > 0 && Date().timeIntervalSince1970 - at < 90
    }

    static func noteTrusted() { UserDefaults.standard.removeObject(forKey: relaunchedKey) }

    static func relaunch() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: relaunchedKey)
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1.5; open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Small builders

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       colour: NSColor = .labelColor, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight)
                                : .systemFont(ofSize: size, weight: weight)
        field.textColor = colour
        return field
    }

    private func wrapping(_ text: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func separator(width: CGFloat) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        return line
    }
}
