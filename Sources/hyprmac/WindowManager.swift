import AppKit
import QuartzCore
import HyprCore
import HyprKit

/// Ties everything together: owns workspace state, decides frames, and pushes
/// them at surfaces.
final class WindowManager: SurfaceRegistryDelegate {
    private var config: Config
    private let registry = SurfaceRegistry()
    private let hotkeys = HotkeyManager()
    private let canvas: Canvas
    private let statusItem = StatusItemController()
    private let hud = WorkspaceHUD()
    private let cheatsheet = Cheatsheet()
    private lazy var prompt = PromptPanel()
    private var gestures: TrackpadGestureMonitor?
    private let overview = WorkspaceOverview()
    /// Names set at runtime, layered over whatever the config declared.
    private var renamedWorkspaces: [Int: String] = WorkspaceNameStore.load()
    /// "ᵃˢˢᶜʳᵃᶜᵏᵉʳ¹²³" and "asscracker" are one name: fold superscripts, accents
    /// and decoration down to plain lowercase letters and digits.
    static func foldName(_ s: String) -> String {
        let map: [Character: Character] = ["ᵃ":"a","ᵇ":"b","ᶜ":"c","ᵈ":"d","ᵉ":"e","ᶠ":"f","ᵍ":"g","ʰ":"h","ⁱ":"i","ʲ":"j","ᵏ":"k","ˡ":"l","ᵐ":"m","ⁿ":"n","ᵒ":"o","ᵖ":"p","ʳ":"r","ˢ":"s","ᵗ":"t","ᵘ":"u","ᵛ":"v","ʷ":"w","ˣ":"x","ʸ":"y","ᶻ":"z",
                                           "⁰":"0","¹":"1","²":"2","³":"3","⁴":"4","⁵":"5","⁶":"6","⁷":"7","⁸":"8","⁹":"9"]
        let mapped = String(s.map { map[$0] ?? $0 })
        let plain = mapped.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        return plain.filter { $0.isLetter || $0.isNumber }
    }

    /// How the last `chat` into each window went: pending, sent, or why not.
    private var chatOutcomes: [UInt64: String] = [:]

    private var workspaces: [Int: Workspace] = [:]
    private var activeWorkspace = 1
    /// Which workspace each surface belongs to, so a parked window can be found again.
    private var homeWorkspace: [SurfaceID: Int] = [:]
    private var focused: SurfaceID?
    /// What had focus before the current window did. Asking Wisper anything
    /// focuses her, so "what is on my screen" would otherwise mean her own window;
    /// this is what she reads instead.
    private var previouslyFocused: SurfaceID?

    /// Windows belonging to a workspace you are not looking at, pushed into the
    /// far corner — where the WindowServer clamps them so ~40x52pt stays on screen,
    /// under `cover`. Where each one actually landed is kept so the cover can be
    /// sized to the truth rather than a constant.
    ///
    /// This is the third mechanism this project has used, and the only fast one:
    ///
    ///     park / unpark a window         1-6ms, no animation
    ///     hide / unhide an application   0-17ms, but all-or-nothing per app
    ///     un-minimize a window           ~500-700ms each, serialized by the Dock
    ///
    /// Minimizing was correct but unusably slow; hiding whole apps was fast but
    /// wrong for any app with windows on both sides of a switch. Parking is
    /// per-window and instant, and costs only the sliver the cover exists to hide.
    private var parked: Set<SurfaceID> = []
    private var parkedSlivers: [SurfaceID: CGRect] = [:]
    private var parkedCorner: [SurfaceID: ParkCorner] = [:]
    private let cover = ParkingCover()
    private let transition = WorkspaceTransition()
    private var modifierTaps: ModifierTapMonitor?
    private lazy var control = ControlSocket { [weak self] request in
        self?.handleControl(request) ?? ["error": "shutting down"]
    }
    /// Applications with no window on the active workspace, hidden whole so they
    /// have no sliver at all. Purely cosmetic: integrity is parking's, so an
    /// unhide — ours or the user's — only ever reveals windows that are still
    /// parked. Measured: `unhide()` does not change the frontmost app.
    private var hiddenApps: Set<pid_t> = []
    /// When the last workspace switch happened. Focus reports arriving right after
    /// one are the switch's own echo, not the user asking for a parked window.
    private var lastSwitch: CFTimeInterval = 0
    /// A parked window that just reported focus, held for a beat before we follow
    /// it to its workspace. Launching an app — Spotlight, `open -a`, the "New
    /// Window" helper, the `terminal` bind — activates it first, and macOS hands
    /// the activated app its old key window, which for an app with windows on
    /// other workspaces is one we parked. Measured: from an empty workspace 4,
    /// opening Ghostty flipped to workspace 2 (its parked key window) and the new
    /// window landed there. A new window of the same app arriving inside the
    /// grace means the focus was the launch's echo, not the user asking for the
    /// parked window; the switch is dropped and the window lands where the user is.
    private var parkedFocusHold: (id: SurfaceID, home: Int, bundle: String?, at: CFTimeInterval)?
    /// The last switch made by following a parked window's focus: where the user
    /// was, which app, when. A window of that app arriving shortly after — the
    /// launch was slow — goes back to the origin workspace, and so does the user.
    private var parkedFocusSwitch: (origin: Int, home: Int, bundle: String?, at: CFTimeInterval)?
    /// The last window to close from the workspace being looked at: its app and
    /// when. Closing an app's last window on a workspace makes macOS focus the
    /// app's next window, which is one we parked — following it teleported the
    /// user off the workspace they had just emptied. That focus is the app's,
    /// not the user's; the user stays.
    private var lastClosed: (bundle: String?, at: CFTimeInterval)?
    /// A launch this process asked for — the `terminal` bind, an `exec` of
    /// `open -na`, a Dock click answered with File ▸ New Window — and when. The activation
    /// hands the app its parked window first, and the new one follows when the
    /// app gets round to it: measured 1 ms to 1772 ms for Ghostty, so no grace
    /// short enough for a Cmd+Tab covers it. While a launch is expected, a parked
    /// focus of that app is held without a timer: the window is coming, and the
    /// workspace must not flash away and back in the meantime.
    private var expectedLaunch: (bundle: String, at: CFTimeInterval)?
    /// How long an expected launch stays expected.
    static let expectedLaunchWindow: TimeInterval = 5.0
    /// What the person last did, for reading a parked window's focus. A Dock click
    /// ends in a mouse-down and Spotlight in a Return; `Cmd+Tab` activates on the
    /// release of ⌘, which is the one gesture that means *switch to that app*.
    private enum Input { case key, mouse, commandRelease }
    private var lastInput: (kind: Input, at: CFTimeInterval)?
    private var commandDown = false
    private var inputMonitors: [Any] = []
    /// How long a parked window's focus waits for a new window to follow it.
    static let parkedFocusGrace: TimeInterval = 0.35
    /// How long after a followed parked focus a new window still counts as its launch.
    static let parkedFocusEcho: TimeInterval = 1.0

    /// What each window has proved it cannot shrink below, learned by asking for a
    /// tile and reading back what came. A window that will not fit is floated —
    /// see `floatWhatCannotFit`.
    private var minimums = MinimumSizes()
    /// Windows the user has put back into the tiling by hand, after hyprmac floated
    /// them. Their word is final: never floated automatically again.
    private var keptTiled: Set<SurfaceID> = []
    /// Apps whose windows the user floats by hand. A window is a passing thing —
    /// close it and its id is gone forever, so remembering the choice against the
    /// window remembers nothing. The choice is really about the app: float one of
    /// its windows and the next one floats too, which is the promise "the app that
    /// fights you only fights you once". ALT+V on a floating window takes it back,
    /// for that window and for the app, so the memory is as easy to undo as to make.
    private var floatedApps: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "floatedApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(floatedApps).sorted(), forKey: "floatedApps") }
    }
    private var fitCheckScheduled = false
    /// Windows seen on the active workspace but absent from the screen. Acted on only
    /// after two consecutive sightings, so a window caught mid-hide or mid-unhide is
    /// not mistaken for one the app has put away.
    private var missingFromScreen: Set<SurfaceID> = []
    private var recheckScheduled = false
    /// Apps with a new-window request already in flight, and when each was last asked.
    /// One activation arrives as several focus notifications — measured: three inside
    /// 330 ms — and without this each one asked Safari for a window of its own.
    private var askingForWindow: Set<String> = []
    private var lastAskedForWindow: [String: CFTimeInterval] = [:]
    /// How many times the hotkeys have been registered without every bind taking.
    private var bindAttempts = 0
    private var relayoutScheduled = false
    private var displayChangeWork: DispatchWorkItem?

    /// Screen changes arrive in a burst (each display, then the arrangement), so
    /// one relayout half a second after the last. The relayout takes the tiling
    /// area fresh and re-parks any sliver that is no longer at a screen edge, which
    /// after a resize is all of them.
    private func displaysChanged() {
        displayChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let area = tilingArea
            log(String(format: "displays: changed — tiling area now %.0f×%.0f; relaying out and re-parking", area.width, area.height))
            scheduleRelayout()
        }
        displayChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    /// Remembered assignments not yet claimed by a window that has appeared.
    /// Drains as windows are discovered at launch.
    private var pendingSession: [WindowIdentity] = []
    /// Apps a rediscovered window matched by exact id: running since the session
    /// was saved, so their unclaimed records are closed windows. See `dropStaleRecords`.
    private var appsRunningSinceSave: Set<String> = []
    /// The saved shape of each workspace, applied as its windows are discovered.
    /// Dropped shortly after launch: past that point a window reappearing with
    /// the same id is a re-adoption, and snapping it back to the launch-time
    /// layout would undo whatever the user did since.
    private var pendingLayouts: [Int: WorkspaceLayout] = [:]
    /// Each workspace's tree as it was the moment a window left it, kept ten
    /// minutes. A window Accessibility drops and re-reports (the rescan re-adopting
    /// a missed notification) came back to the right workspace and then got
    /// dwindle-inserted at whatever tile had focus: the workspace "rearranged
    /// itself". Now it prunes its way back into the tree it left.
    /// Stamped on the awake clock: see `reclaims`.
    private var rememberedTrees: [Int: (root: Tile, at: CFTimeInterval)] = [:]
    /// Windows that closed, with the workspace they left — claimed by exact id
    /// only, for ten minutes. A record from a removal must never match by app or
    /// title: measured, a Ghostty window closed on workspace 4 made the next NEW
    /// Ghostty window land on 4, because "same app" was the matcher's last resort.
    /// Only a re-adopted window (same id) is the window that left.
    /// Each record carries the tree as that window left it: at sleep every window
    /// departs in sequence, and the per-workspace slot got restamped with a
    /// shrinking tree each time — the last stamp held one leaf, so the wake knew
    /// every window's workspace and none of their arrangement.
    /// Stamped with `CACurrentMediaTime`, which does not tick while the machine is
    /// asleep — measured on this Mac: 5.1 days since boot, 47.7 h of it on the
    /// monotonic clock, the other 74.4 h asleep. Ten minutes of *use* is what these
    /// records are meant to survive, and the wall clock cannot say that. It also
    /// removes a race that only ever showed on a machine that sleeps for hours: at
    /// wake, Accessibility re-reports the windows it dropped at sleep, and if the
    /// first of them arrived before `NSWorkspace.didWakeNotification`, the expiry
    /// below ran against un-adjusted wall-clock stamps, binned every record, and
    /// every window landed on whatever workspace the machine went to sleep on.
    private var reclaims: [(identity: WindowIdentity, at: CFTimeInterval, tree: Tile?, floating: CGRect?)] = []
    /// The tree a window was in when the user minimized it, kept for as long as it
    /// stays minimized. Measured: ⌘M then a Dock click put the window back
    /// dwindle-inserted at whatever had focus — `8317 | (8319 / 8321)` came back as
    /// `(8319 | 8317) / 8321` — on a path the ten-minute tree slot never covered.
    private var minimizedSlots: [SurfaceID: Tile] = [:]
    /// Why the next tree change happened, for the journal line relayout writes.
    private var treeCause = "start"
    /// When the system went to sleep. The wake handler adds the slept interval to
    /// every closed-window record and tree slot: at sleep, Accessibility drops
    /// every window and the records are stamped; an 87-minute nap aged them past
    /// the ten-minute expiry, and the whole desktop came back dwindle-packed onto
    /// the active workspace. Time asleep is time nothing happened.
    private var sleptAt: Date?
    private var treeSignatures: [Int: String] = [:]
    private var sessionSaveScheduled = false
    /// Identity kept alongside each live window. The registry has already dropped
    /// a surface by the time it reports the removal, so this is the only place the
    /// bundle and title still exist when a window closes.
    private var knownIdentity: [SurfaceID: WindowIdentity] = [:]
    /// The divider currently under the mouse, captured on mouse-down so the drag
    /// keeps moving the same one even if the cursor wanders off it.
    private var activeDivider: DividerHit?
    /// Title-bar drags between tiles: see `WindowDrag`.
    private let windowDrag = WindowDrag()
    private var dropHighlight: CGRect?
    private var lastDragApply: CFTimeInterval = 0

    /// When set, compute and draw the layout but never touch a real window.
    /// Makes it possible to develop against a live desktop without rearranging it.
    private let isDryRun: Bool

    init(config: Config, dryRun: Bool = false) {
        var config = config
        for (index, name) in WorkspaceNameStore.load() { config.workspaceNames[index] = name }
        self.config = config
        self.isDryRun = dryRun
        self.canvas = Canvas(config: config)
        cover.apply(config: config)
        for index in 1...config.workspaceCount {
            workspaces[index] = Workspace(index: index)
        }
        // Restore where things were before adopting anything, so the first window
        // discovered already knows which workspace it belongs on.
        let session = SessionStore.load()
        pendingSession = session.windows.filter { (1...config.workspaceCount).contains($0.workspace) }
        pendingLayouts = session.layouts.filter { (1...config.workspaceCount).contains($0.key) }
        // The remembered assignments expire with the layouts. Kept past launch, a
        // record nothing claimed — a Ghostty on workspace 4 from last week — claims
        // the next new window of that app, which appears, is sent there, and is
        // parked out of sight: "pops up and disappears". Messages always landing
        // on workspace 1 was the same record, older. After the grace, new is new.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            pendingLayouts.removeAll()
            pendingSession.removeAll()
        }
        activeWorkspace = (1...config.workspaceCount).contains(session.activeWorkspace)
            ? session.activeWorkspace : 1
        registry.delegate = self
    }

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noteSleep() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noteWake() }
        }
        // The display changed under us — a monitor plugged in or out, the lid
        // closed — and every tile and every parked sliver is where the old screen
        // put it: laptop-sized tiles on a 27-inch, slivers a third of the way
        // across it. The canvas repainted; the tree never relaid out. Found the
        // morning the laptop woke on a Studio Display and had to be restarted.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaysChanged() }
        }
        inputMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in self?.lastInput = (.key, CACurrentMediaTime()) }
        } as Any)
        inputMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.lastInput = (.mouse, CACurrentMediaTime()) }
        } as Any)
        inputMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let down = event.modifierFlags.contains(.command)
            Task { @MainActor in
                guard let self else { return }
                if self.commandDown, !down { self.lastInput = (.commandRelease, CACurrentMediaTime()) }
                self.commandDown = down
            }
        } as Any)
        // Drag a window by its title bar onto another tile: the two swap, or — near
        // the target's edge — the dragged window takes that half of it.
        windowDrag.candidate = { [weak self] p in
            guard let self, let ws = workspaces[activeWorkspace] else { return nil }
            // The window as it actually is, not its tile: a window a little off its
            // slot must still be grabbable by its title bar.
            for id in ws.tiled {
                guard let surface = registry.surface(for: id) else { continue }
                let f = surface.frame
                guard f.contains(p), p.y - f.minY < 34 else { continue }
                // And confirm the system agrees that this window is what the pointer
                // is on. Geometry alone said yes to a press on anything floating above
                // a tiled window — a picture-in-picture window, a panel, a dialog —
                // none of which hyprmac manages or can even see in its own registry,
                // so dragging one dragged the tiled window underneath it as well.
                // A nil answer means the window server had nothing to say; trust the
                // geometry then rather than refusing to drag at all.
                if let onTop = Accessibility.windowUnderPointer(p),
                   let ax = surface as? AXSurface, onTop != ax.windowID { continue }
                return (id, f)
            }
            return nil
        }
        windowDrag.target = { [weak self] p, draggedFrame, dragged in
            guard let self, let ws = workspaces[activeWorkspace] else { return nil }
            let area = tilingArea
            let frames = ws.frames(in: area, gaps: config.gaps).filter { $0.key != dragged }
            // Judge the drop by what the window covers, not by where the pointer is:
            // the grab is the title bar, so the pointer rides the window's top edge,
            // and a point of any kind was too sharp to aim. The pointer speaks only
            // from the menu bar, where macOS has pinned the window and let it go on
            // alone: that means "above". See `DropZone.hit`.
            guard let (id, found) = DropZone.hit(window: draggedFrame, over: frames, pushedUp: p.y < area.minY),
                  let frame = frames[id] else { return nil }
            var zone = found
            // A drop that would change nothing swaps instead — the top window of a
            // pair let go a little way down over the bottom one is "above that one",
            // which is where it came from. Nobody drags a window to leave it put.
            if let axis = zone.axis, let root = ws.root,
               root.splits(zone.placesFirst ? dragged : id, then: zone.placesFirst ? id : dragged, along: axis) {
                zone = .center
            }
            return WindowDrag.Hit(id: id, zone: zone, preview: zone.preview(in: frame))
        }
        windowDrag.highlight = { [weak self] rect in
            guard let self else { return }
            dropHighlight = rect
            // Redraw the canvas only. A relayout here wrote frames mid-drag and could
            // pull the window out from under the mouse.
            refreshCanvas()
        }
        windowDrag.dropped = { [weak self] dragged, hit in
            guard let self else { return }
            let gen = windowDrag.generation
            if let hit, var ws = workspaces[activeWorkspace], let root = ws.root {
                if let axis = hit.zone.axis {
                    ws.move(dragged, beside: hit.id, axis: axis, first: hit.zone.placesFirst)
                    treeCause = "drag \(dragged) beside \(hit.id) (\(hit.zone))"
                } else {
                    ws.root = root.swapping(dragged, hit.id)
                    ws.focused = dragged
                    treeCause = "drag swap \(dragged) with \(hit.id)"
                }
                workspaces[activeWorkspace] = ws
                focused = dragged
                scheduleSessionSave()
            }
            // macOS moved the dragged window; our record of where we put it is stale.
            registry.surface(for: dragged)?.forgetRequestedFrame()
            if let hit { registry.surface(for: hit.id)?.forgetRequestedFrame() }
            // Either way the relayout puts every window on its tile: swapped, moved, or
            // back. Twice more after a beat — macOS finishes its own move after the
            // release, and its drag-to-edge tiling zooms after that — unless a new drag
            // has begun, in which case a late relayout would yank that one.
            scheduleRelayout()
            for delay in [0.25, 0.8, 1.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, windowDrag.generation == gen else { return }
                    registry.surface(for: dragged)?.forgetRequestedFrame()
                    if let hit { registry.surface(for: hit.id)?.forgetRequestedFrame() }
                    scheduleRelayout()
                }
            }
        }
        windowDrag.start()
        registry.ignore(bundleIDs: Array(config.ignoredBundleIDs))
        control.start()
        installMouseResize()
        installGestures()
        registry.start()
        bindHotkeys()
        installStatusItem()
        // AX notifications are best-effort; a slow sweep catches whatever they miss.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.registry.rescan()
            self?.dropWindowsTheirAppsHid()
        }
        // After the first sweep every window that exists has been found. A record
        // left over for an app that has kept running is a closed window's, and would
        // send the app's next new window away (measured: a terminal opened on
        // workspace 4 within twenty seconds of a restart landed on 3, where one with
        // that title had been closed). A new window lands where you are.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            let dropped = SessionMatcher.dropRecords(ofApps: appsRunningSinceSave, from: &pendingSession)
            if dropped > 0 { log("session: dropped \(dropped) record(s) of closed windows for \(appsRunningSinceSave.count) app(s) running since the save — new windows land where you are") }
        }
        relayout()
    }

    // MARK: Trackpad

    private func installGestures() {
        gestures?.stop()
        guard config.gesturesEnabled else {
            gestures = nil
            return
        }
        let monitor = TrackpadGestureMonitor(fingers: config.gestureFingers,
                                             threshold: config.gestureThreshold,
                                             inverted: config.gestureInverted)
        monitor.onSwipe = { [weak self] direction in
            guard let self else { return }
            // Logged, because a gesture that does nothing is otherwise unsupportable:
            // there is no way to tell "the fingers were never seen" from "the swipe
            // was read as the other axis" from "it fired and the action did nothing".
            log("gesture: swipe \(direction)\(direction == .up || direction == .down ? (self.config.gestureOverview ? " — overview" : " — ignored, gestures.overview is false") : "")")
            switch direction {
            case .right: self.dispatch(.workspaceRelative(1))
            case .left:  self.dispatch(.workspaceRelative(-1))
            // Either direction toggles it. Which way a person swipes to "show me
            // everything" is not a thing worth being right about, and a gesture that
            // works one way and silently does nothing the other reads as broken.
            case .up, .down: if self.config.gestureOverview { self.dispatch(.workspaceOverview) }
            }
        }
        overview.onPick = { [weak self] index in self?.dispatch(.workspace(index)) }
        // Clicking a window in the overview goes to it, workspace and all — the
        // thing Mission Control is used for, on windows Mission Control cannot see.
        overview.onPickWindow = { [weak self] id in self?.controlFocus(id) }
        overview.onRename = { [weak self] index in self?.promptRename(workspace: index) }
        overview.onReorder = { [weak self] from, to in
            guard let self else { return }
            self.applyWorkspaceOrder(WorkspaceOrder.moving(from: from, to: to,
                                                           count: self.config.workspaceCount))
        }
        monitor.start()
        gestures = monitor
    }

    // MARK: Mouse resize

    private func installMouseResize() {
        canvas.dividerProbe = { [weak self] point in
            guard let self, let root = self.workspaces[self.activeWorkspace]?.root else { return false }
            return root.divider(at: point, in: self.tilingArea, gaps: self.config.gaps) != nil
        }
        canvas.onDragBegan = { [weak self] point in
            guard let self, let root = self.workspaces[self.activeWorkspace]?.root else { return }
            self.activeDivider = root.divider(at: point, in: self.tilingArea, gaps: self.config.gaps)
        }
        canvas.onDragMoved = { [weak self] point in self?.dragDivider(to: point) }
        canvas.onDragEnded = { [weak self] in
            self?.activeDivider = nil
            self?.scheduleRelayout()
        }
    }

    private func dragDivider(to point: CGPoint) {
        guard let hit = activeDivider,
              var workspace = workspaces[activeWorkspace],
              let root = workspace.root else { return }

        // Map the cursor into a fraction of the split's own bounds, so a drag
        // tracks the pointer exactly regardless of how deep the split sits.
        let ratio: CGFloat = switch hit.axis {
        case .horizontal: (point.x - hit.bounds.minX) / max(1, hit.bounds.width)
        case .vertical:   (point.y - hit.bounds.minY) / max(1, hit.bounds.height)
        }
        workspace.root = root.settingRatio(at: hit.path, to: ratio)
        workspaces[activeWorkspace] = workspace

        // Every frame write is a synchronous round trip into another app, so a
        // drag that relayouts on every mouse event stutters. Cap it at ~60Hz and
        // let the mouse-up settle the final position.
        let now = CACurrentMediaTime()
        guard now - lastDragApply > 1.0 / 60 else { return }
        lastDragApply = now
        relayout()
    }

    // MARK: Config

    func reload() {
        let (newConfig, diagnostics) = ConfigStore.load()
        for diagnostic in diagnostics {
            FileHandle.standardError.write("config:\(diagnostic.line): \(diagnostic.message)\n".data(using: .utf8)!)
        }
        var merged = newConfig
        // A reload must not undo a rename you made since the last edit.
        for (index, name) in renamedWorkspaces { merged.workspaceNames[index] = name }
        config = merged
        canvas.apply(config: merged)
        cover.apply(config: merged)
        bindHotkeys()
        installStatusItem()
        installGestures()
        relayout()
    }

    /// The user's accent colour from System Settings, unless the config pins one.
    private var accentColor: NSColor {
        config.activeBorderUsesAccent ? .controlAccentColor : NSColor(argb: config.activeBorderColor)
    }

    private func installStatusItem() {
        guard config.menuBarIndicator else {
            statusItem.remove()
            return
        }
        statusItem.install()
        statusItem.onSelectWorkspace = { [weak self] in self?.dispatch(.workspace($0)) }
        statusItem.onRenameWorkspace = { [weak self] index in self?.promptRename(workspace: index) }
        statusItem.onShowKeybindings = { [weak self] in self?.dispatch(.cheatsheet) }
        statusItem.onReportBug = { [weak self] in self?.reportBug() }
        statusItem.onShowWelcome = { [weak self] in
            guard let self else { return }
            WelcomeWindow.shared.showOnDemand(usesVerticalSwipe: config.gestureOverview)
        }
        statusItem.onReload = { [weak self] in self?.dispatch(.reload) }
        statusItem.onQuit = { [weak self] in self?.dispatch(.exit) }
    }

    /// Register every bind, and say so in the journal — including the ones that did
    /// not take. A `RegisterEventHotKey` failure used to go to stderr alone, which is
    /// thrown away when the app is launched from the Dock or by `open`: a key that
    /// silently does nothing, with the startup line still claiming all 55 binds were
    /// registered because it counted the binds in the config rather than the ones
    /// that took. The commonest cause is hyprmac restarting faster than the outgoing
    /// instance releases its hotkeys — a config reload, an update, a relaunch — so a
    /// failure is retried rather than mourned.
    private func bindHotkeys() {
        modifierTaps?.stop()
        modifierTaps = ModifierTapMonitor(taps: config.doubleTaps) { [weak self] dispatcher in self?.dispatch(dispatcher) }
        modifierTaps?.start()
        hotkeys.onAnyHotkey = { [weak self] in self?.modifierTaps?.hotkeyFired() }
        hotkeys.unregisterAll()
        var refused: [String] = []
        for bind in config.binds {
            let dispatcher = bind.dispatcher
            let ok = hotkeys.register(modifiers: bind.modifiers, keyCode: bind.keyCode) { [weak self] in
                self?.dispatch(dispatcher)
            }
            if !ok { refused.append(dispatcher.label) }
        }
        guard !refused.isEmpty else {
            if bindAttempts > 0 { log("binds: all \(config.binds.count) registered on attempt \(bindAttempts + 1)") }
            bindAttempts = 0
            return
        }
        bindAttempts += 1
        let took = config.binds.count - refused.count
        if bindAttempts <= 3 {
            log("binds: \(took) of \(config.binds.count) registered — something else still owns \(refused.joined(separator: ", ")); trying again in 1.5 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.bindHotkeys() }
        } else {
            log("binds: \(took) of \(config.binds.count) registered — gave up after \(bindAttempts) tries; another app owns \(refused.joined(separator: ", "))")
        }
    }

    // MARK: Registry delegate

    func registry(_ registry: SurfaceRegistry, didAdd surface: Surface) {
        let bundle = (surface as? AXSurface)?.bundleID
        // The rule: a new window lands on the workspace you are looking at. The
        // only windows that go elsewhere are not new — the same window re-reported
        // (a closed-window record, claimed by exact id), or a window found at launch
        // that the saved session places. Nothing here decides where you meant it.
        // Twelve hours, not ten minutes. These are matched by exact window id, so a
        // stale one can only ever be claimed by the very window that made it — unlike
        // the launch pool, which matches by app and title and must expire quickly. Ten
        // minutes was enough for a window Accessibility dropped and re-reported, and
        // far too little for a machine that sleeps overnight and wakes with every
        // window arriving at once.
        reclaims.removeAll { CACurrentMediaTime() - $0.at > 43_200 }
        if reclaims.count > 400 { reclaims.removeFirst(reclaims.count - 400) }
        let claim = reclaims.firstIndex { $0.identity.id == surface.id.raw }.map { reclaims.remove(at: $0) }
        let reclaimed = claim?.identity.workspace
        if let bundle, claim == nil, pendingSession.contains(where: { $0.id == surface.id.raw }) { appsRunningSinceSave.insert(bundle) }
        let remembered = reclaimed ?? SessionMatcher.claim(id: surface.id.raw,
                                                           bundleID: bundle,
                                                           title: surface.title,
                                                           from: &pendingSession)
        var destination = remembered ?? activeWorkspace
        var returnTo: Int?
        // The launch we were expecting has produced its window, wherever it goes.
        if let expected = expectedLaunch, expected.bundle == bundle { expectedLaunch = nil }
        if remembered == nil {
            let now = CACurrentMediaTime()
            if let hold = parkedFocusHold, hold.bundle == bundle, now - hold.at < Self.expectedLaunchWindow {
                // The parked focus was this launch's activation echo. Stay put.
                parkedFocusHold = nil
                log(String(format: "launch: %@ window %@ arrived %.0f ms after its parked window took focus — staying on ws%d", (surface as? AXSurface)?.appName ?? "?", "\(surface.id)", (now - hold.at) * 1000, activeWorkspace))
            } else if let echo = parkedFocusSwitch, echo.bundle == bundle, now - echo.at < Self.parkedFocusEcho,
                      echo.home == activeWorkspace, workspaces[echo.origin] != nil {
                // Too slow for the grace: we already followed the parked window.
                // The new window still belongs where the user was; go back.
                parkedFocusSwitch = nil
                destination = echo.origin
                returnTo = echo.origin
                log(String(format: "launch: %@ window %@ arrived %.0f ms after we followed its parked window — back to ws%d", (surface as? AXSurface)?.appName ?? "?", "\(surface.id)", (now - echo.at) * 1000, echo.origin))
            }
        }

        let how: String
        if let rect = claim?.floating {
            // The same window, re-reported: it was floating when it left.
            workspaces[destination]?.setFloating(surface.id, rect)
            how = "floating, where it was"
        } else if let bundle, config.floatingBundleIDs.contains(bundle) {
            workspaces[destination]?.setFloating(surface.id, surface.frame)
            how = "floating (float rule in the config)"
        } else if let bundle, floatedApps.contains(bundle) {
            workspaces[destination]?.setFloating(surface.id, surface.frame)
            how = "floating (you float this app by hand)"
        } else if let best = bestTree(for: surface.id, into: destination, claimed: claim?.tree),
                  restore(surface.id, into: destination, from: best) {
            how = "into the richest tree that held it"
        } else if restoreLayout(for: surface.id, into: destination) {
            how = "into its saved slot"
        } else {
            insertTiled(surface.id, into: destination)
            how = "inserted at the focused tile"
        }
        treeCause = "added \(surface.id) \((surface as? AXSurface)?.appName ?? "?") \(reclaimed != nil ? "(reclaimed) " : remembered != nil ? "(remembered) " : "")\(how)"
        // One line per window, because the tree journal records a single cause for a
        // whole relayout: when a dozen windows come back together after a wake, it
        // names the last of them and says nothing about the other eleven.
        log("place: \(surface.id) \((surface as? AXSurface)?.appName ?? "?") → ws\(destination) "
          + "(\(reclaimed != nil ? "its own record" : remembered != nil ? "the saved session" : "no record — where you are"))"
          + "\(returnTo != nil ? ", then back to ws\(returnTo!)" : "")")
        homeWorkspace[surface.id] = destination
        knownIdentity[surface.id] = WindowIdentity(id: surface.id.raw, bundleID: bundle,
                                                   title: surface.title, workspace: destination)
        // Only take focus if it actually appeared in front of you.
        if destination == activeWorkspace { focused = surface.id }
        scheduleSessionSave()
        scheduleRelayout()
        if let returnTo, returnTo != activeWorkspace {
            workspaces[returnTo]?.focused = surface.id
            dispatch(.workspace(returnTo))
        }
    }

    func registry(_ registry: SurfaceRegistry, didRemove id: SurfaceID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reapEmptyTerminalInstances() }
        parked.remove(id)
        parkedSlivers[id] = nil
        parkedCorner[id] = nil
        minimizedSlots[id] = nil
        minimums.forget(id)
        keptTiled.remove(id)
        treeCause = "closed \(id)"
        if homeWorkspace[id] == activeWorkspace {
            let bundle = knownIdentity[id]?.bundleID
            lastClosed = (bundle, CACurrentMediaTime())
            // macOS focused the app's next window before telling us this one was
            // gone; if that next window is parked, the hold is already ticking.
            if let hold = parkedFocusHold, hold.bundle == bundle {
                parkedFocusHold = nil
                log("focus: parked \(hold.id) (\(bundle ?? "?")) took focus as \(id) closed here — the app's refocus, staying on ws\(activeWorkspace)")
            }
        }
        if let home = homeWorkspace.removeValue(forKey: id) {
            // Floating windows are not in the tree, so the departing tree says
            // nothing about them; their rect is the thing worth keeping.
            let wasFloating = workspaces[home]?.floating[id]
            let departing = workspaces[home]?.root.flatMap { $0.contains(id) ? $0 : nil }
            // Never trade a richer remembered tree for a poorer one: a mass removal
            // stamps once per window, each tree smaller than the last.
            if let departing {
                let kept = rememberedTrees[home]
                if kept == nil || CACurrentMediaTime() - kept!.at > 43_200 || departing.surfaces.count >= kept!.root.surfaces.count {
                    rememberedTrees[home] = (departing, CACurrentMediaTime())
                }
            }
            workspaces[home]?.remove(id)
            // Remember it: closing a window is usually temporary, and its place in
            // the project should still be waiting when it comes back.
            if let identity = knownIdentity.removeValue(forKey: id) {
                reclaims.append((WindowIdentity(id: identity.id, bundleID: identity.bundleID,
                                                title: identity.title, workspace: home), CACurrentMediaTime(), departing, wasFloating))
            }
            scheduleSessionSave()
        }
        if focused == id { focused = workspaces[activeWorkspace]?.focused }
        scheduleRelayout()
    }

    func registry(_ registry: SurfaceRegistry, didFocus id: SurfaceID) {
        // Only accept focus for a window on the workspace being looked at.
        // Activating an application reports whichever window it considers focused,
        // and for an app with windows spread across workspaces that is routinely
        // one we have minimised out of sight. Taking it would silently point every
        // subsequent command at a window the user cannot see.
        if focused != id { previouslyFocused = focused }
        if parked.contains(id) {
            // Cmd+Tab or a Dock click landed on a window that is parked out of
            // sight. Leaving it there would put the keyboard into something you
            // cannot see; going to its workspace is what the gesture meant. Not
            // within a switch's own settling time, or the echoes would bounce us.
            guard CACurrentMediaTime() - lastSwitch > 0.5,
                  let home = homeWorkspace[id], home != activeWorkspace else { return }
            let bundle = knownIdentity[id]?.bundleID ?? (registry.surface(for: id) as? AXSurface)?.bundleID
            if let closed = lastClosed, closed.bundle == bundle, CACurrentMediaTime() - closed.at < 1.0 {
                log("focus: parked \(id) (\(bundle ?? "?")) right after a window of its app closed here — the app's refocus, staying on ws\(activeWorkspace)")
                return
            }
            // Not yet: if this is an app being launched, its new window is about
            // to appear, and it belongs on the workspace the user is looking at.
            let hold = (id: id, home: home, bundle: bundle, at: CACurrentMediaTime())
            parkedFocusHold = hold
            if let expected = expectedLaunch, expected.bundle == bundle, hold.at - expected.at < Self.expectedLaunchWindow {
                // We asked for this launch ourselves: the window is coming, however
                // long the app takes. No timer — nothing to follow.
                log(String(format: "focus: parked %@ (%@) took focus %.0f ms after we launched the app — holding for its window", "\(id)", bundle ?? "?", (hold.at - expected.at) * 1000))
                return
            }
            // A gesture with no launch behind it. `Cmd+Tab` means "switch to that
            // app" and is followed. A Dock click or Spotlight means "that app, here":
            // if the app has a window here, that one takes focus; if not, "here"
            // means a new one — File ▸ New Window, pressed in the app's own menu
            // bar, and held for like a launch of ours. An app without that item
            // is followed as before.
            let switching = commandDown || lastInput.map { $0.kind == .commandRelease && hold.at - $0.at < 1.0 } ?? false
            if !switching {
                if let here = workspaces[activeWorkspace]?.all.first(where: { knownIdentity[$0]?.bundleID == bundle }) {
                    parkedFocusHold = nil
                    log("focus: parked \(id) (\(bundle ?? "?")) took focus, but \(here) of the same app is here — focusing that instead")
                    controlFocus(here)
                    return
                }
                if let bundle, let pid = registry.surface(for: id)?.pid {
                    // One request per app at a time, and not again for five seconds.
                    guard !askingForWindow.contains(bundle),
                          CACurrentMediaTime() - (lastAskedForWindow[bundle] ?? 0) > 5 else { return }
                    askingForWindow.insert(bundle)
                    // Give the app a moment to answer for itself first. "Activate
                    // Safari" and "open this URL in Safari" arrive here identically,
                    // and in the second case Safari is already making a window — or
                    // has put the page in a tab. Asking immediately produced a blank
                    // window beside a page the user could not see.
                    // What the app already has, and what each window is showing. Whether
                    // to add a window is a question about the app's behaviour, not about
                    // who asked: an activation from a person, from Wisper, or from any
                    // other program all deserve the same answer, and hyprmac is expected
                    // to work while nobody is at the machine.
                    let before = registry.allSurfaces.filter { $0.bundleID == bundle }
                    let beforeCount = before.count
                    let beforeTitles = Dictionary(before.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                        guard let self else { return }
                        askingForWindow.remove(bundle)
                        lastAskedForWindow[bundle] = CACurrentMediaTime()
                        let now = registry.allSurfaces.filter { $0.bundleID == bundle }
                        if now.count > beforeCount {
                            log("focus: \(bundle) opened its own window — not asking for another")
                            return
                        }
                        // A window it already had is showing something new: the
                        // activation carried a request and the app has answered it, in a
                        // tab, in a window that may be on another workspace entirely.
                        // Adding a window here would put a blank one beside a page the
                        // user cannot see, which is the thing to avoid above all.
                        if let changed = now.first(where: { beforeTitles[$0.id] != nil && beforeTitles[$0.id] != $0.title }) {
                            log("focus: \(bundle) answered in a window it already had (\(changed.id)) — not asking for another")
                            return
                        }
                        if workspaces[activeWorkspace]?.all.contains(where: { self.knownIdentity[$0]?.bundleID == bundle }) == true {
                            return
                        }
                        guard AppMenus.press(menu: "File", item: "New Window", in: pid) else { return }
                        expectedLaunch = (bundle: bundle, at: CACurrentMediaTime())
                        log("focus: parked \(id) (\(bundle)) took focus with none of the app on ws\(activeWorkspace) — asked it for a new window here")
                    }
                    return
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.parkedFocusGrace) { [weak self] in
                guard let self, let held = parkedFocusHold, held.id == hold.id, held.at == hold.at else { return }
                parkedFocusHold = nil
                guard parked.contains(id), let home = homeWorkspace[id], home != activeWorkspace else { return }
                log("focus: parked \(id) (\(bundle ?? "?")) held \(Int(Self.parkedFocusGrace * 1000)) ms with no new window — following it to ws\(home)")
                parkedFocusSwitch = (origin: activeWorkspace, home: home, bundle: bundle, at: CACurrentMediaTime())
                workspaces[home]?.focused = id
                dispatch(.workspace(home))
            }
            return
        }
        // A real window of the active workspace took focus: nothing to wait for.
        if workspaces[activeWorkspace]?.contains(id) == true { parkedFocusHold = nil }
        guard workspaces[activeWorkspace]?.contains(id) == true else { return }
        focused = id
        workspaces[activeWorkspace]?.focused = id
        scheduleRelayout()
    }

    func registry(_ registry: SurfaceRegistry, didChangeMinimized id: SurfaceID, isMinimized: Bool) {
        // Nothing here is ever our doing: parking moves windows, it never
        // minimizes them, so a minimize is always the user's.
        guard let home = homeWorkspace[id] else { return }
        if isMinimized {
            // The user minimized it: give up its tile so the others reclaim the
            // space — and keep the tree it was in, so it gets its slot back.
            if let root = workspaces[home]?.root, root.contains(id) { minimizedSlots[id] = root }
            workspaces[home]?.remove(id)
            treeCause = "minimized \(id)"
        } else if workspaces[home]?.contains(id) == false {
            if let root = minimizedSlots.removeValue(forKey: id), restore(id, into: home, from: root) {
                treeCause = "un-minimized \(id), back in its slot"
            } else if restoreLayout(for: id, into: home) {
                treeCause = "un-minimized \(id), into the remembered tree"
            } else {
                insertTiled(id, into: home)
                treeCause = "un-minimized \(id), inserted at the focused tile"
            }
        }
        scheduleRelayout()
    }

    /// Put a rediscovered window back into the shape its workspace had. Returns
    /// false when the saved layout has nothing to say about it.
    ///
    /// The saved tree pruned to the windows present so far is always a valid
    /// layout, so each arrival rebuilds the workspace from it; windows that are
    /// present but were never in the saved tree are re-inserted the dwindle way.
    private func restoreLayout(for id: SurfaceID, into index: Int) -> Bool {
        let remembered = rememberedTrees[index].flatMap { CACurrentMediaTime() - $0.at < 43_200 ? WorkspaceLayout(root: $0.root) : nil }
        guard let saved = pendingLayouts[index] ?? remembered, var workspace = workspaces[index] else { return false }
        if let rect = saved.floating[id.raw] {
            workspace.setFloating(id, rect)
            workspaces[index] = workspace
            return true
        }
        guard let savedRoot = saved.root else { return false }
        return restore(id, into: index, from: savedRoot)
    }

    /// Out of everything that survived — the window's own closed-record tree, the
    /// workspace's slot, the launch session — the tree containing `id` that
    /// overlaps most with the windows present now. A late arrival's one-leaf
    /// record must never wipe the arrangement an earlier arrival rebuilt.
    private func bestTree(for id: SurfaceID, into index: Int, claimed: Tile?) -> Tile? {
        let present = Set((workspaces[index]?.tiled ?? []) + [id])
        let slot = rememberedTrees[index].flatMap { CACurrentMediaTime() - $0.at < 43_200 ? $0.root : nil }
        return Tile.richest(of: [claimed, slot, pendingLayouts[index]?.root, workspaces[index]?.root],
                            containing: id, present: present)
    }

    /// Rebuild a workspace from a tree that held `id`, pruned to the windows
    /// present now; windows the tree never knew are re-inserted the dwindle way.
    private func restore(_ id: SurfaceID, into index: Int, from savedRoot: Tile) -> Bool {
        guard savedRoot.contains(id), var workspace = workspaces[index] else { return false }
        let present = Set(workspace.tiled + [id])
        workspace.root = savedRoot.pruned(keeping: present)
        for stray in present where workspace.root?.contains(stray) != true {
            workspace.insert(stray, splitting: workspace.focused, axis: tilingArea.naturalSplitAxis)
        }
        workspace.focused = id
        workspaces[index] = workspace
        return true
    }

    private func insertTiled(_ id: SurfaceID, into index: Int) {
        guard var workspace = workspaces[index] else { return }
        // Dwindle: the new window splits whichever tile has focus, along that
        // tile's long edge.
        let area = tilingArea
        let frames = workspace.root?.frames(in: area, gaps: config.gaps) ?? [:]
        let target = workspace.focused.flatMap { frames[$0] } ?? area
        workspace.insert(id, splitting: workspace.focused, axis: target.naturalSplitAxis)
        workspaces[index] = workspace
    }

    /// The window a command acts on.
    ///
    /// Never trust `focused` on its own: it is updated from AX notifications that
    /// can name a window on another workspace. Everything the user triggers goes
    /// through here so a command can only ever hit something actually on screen.
    private var actionTarget: SurfaceID? {
        guard let workspace = workspaces[activeWorkspace] else { return nil }
        func usable(_ id: SurfaceID?) -> SurfaceID? {
            guard let id, workspace.contains(id), !parked.contains(id) else { return nil }
            return id
        }
        // Ask the system first. One AX round trip per keypress is nothing, and it
        // is the only answer that cannot be stale — a dropped notification would
        // otherwise leave every command aimed at the previously focused window.
        return usable(registry.systemFocused) ?? usable(focused) ?? workspace.resolvedFocus
    }

    // MARK: Layout

    /// v0 tiles the primary display only. Multi-display means a workspace set per
    /// display, which is the next change rather than a rewrite.
    private var tilingArea: CGRect {
        Displays.all().first(where: \.isPrimary)?.visibleFrame
            ?? Displays.all().first?.visibleFrame
            ?? .zero
    }

    /// Bursts of AX events are normal (opening a window fires several). Coalescing
    /// to the next runloop turn keeps us from tiling three times for one change.
    /// Writing the session on every AX event would hammer the disk; coalescing to
    /// the next runloop turn keeps it to one write per burst of changes.
    private func scheduleSessionSave() {
        guard !sessionSaveScheduled, !isDryRun else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.sessionSaveScheduled = false
            self?.saveSession()
        }
    }

    private func saveSession() {
        var windows: [WindowIdentity] = []
        for (id, home) in homeWorkspace {
            guard let surface = registry.surface(for: id) else { continue }
            // Refresh the cached identity while the window is still here: titles
            // change constantly and the newest one matches best next launch.
            let identity = WindowIdentity(id: id.raw, bundleID: surface.bundleID,
                                          title: surface.title, workspace: home)
            knownIdentity[id] = identity
            windows.append(identity)
        }
        // Keep records for windows that have not come back yet, or closing an app
        // for an afternoon would forget where its windows lived.
        windows.append(contentsOf: pendingSession)
        // A closed window's workspace is still worth a restart: an app quit for an
        // afternoon comes back by title and app at launch, and only at launch.
        windows.append(contentsOf: reclaims.map(\.identity))
        var layouts: [Int: WorkspaceLayout] = [:]
        for (index, workspace) in workspaces where !workspace.isEmpty {
            var floating: [UInt64: CGRect] = [:]
            for (id, rect) in workspace.floating { floating[id.raw] = rect }
            layouts[index] = WorkspaceLayout(root: workspace.root, floating: floating)
        }
        SessionStore.save(SessionState(windows: windows, activeWorkspace: activeWorkspace, layouts: layouts))
    }

    private func noteSleep() {
        sleptAt = Date()
        log("sleep: \(reclaims.count) closed-window records and \(rememberedTrees.count) tree slots will not age")
    }

    /// Nothing to put right — the stamps are on a clock that stopped when the
    /// machine did. This only says how long that was, and it no longer matters
    /// whether it runs before or after the windows come back.
    private func noteWake() {
        guard let sleptAt else { return }
        let slept = Date().timeIntervalSince(sleptAt)
        self.sleptAt = nil
        guard slept > 1 else { return }
        log(String(format: "wake: slept %.0f s — %d records and %d tree slots aged none of it", slept, reclaims.count, rememberedTrees.count))
    }

    /// One line per workspace whose shape changed since the last relayout, with
    /// the cause the change was made under — the record "rearranged itself" lacked.
    private func journalTrees() {
        for index in workspaces.keys.sorted() {
            let now = workspaces[index]?.root?.shorthand ?? "empty"
            let before = treeSignatures[index]
            treeSignatures[index] = now
            let cause = treeCause.isEmpty ? "no cause recorded" : treeCause
            guard let before else { if now != "empty" { log("tree ws\(index): \(now)   [\(cause)]") }; continue }
            guard before != now else { continue }
            log("tree ws\(index): \(before)  ->  \(now)   [\(cause)]")
        }
        treeCause = ""
    }

    private func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.relayoutScheduled = false
            self?.relayout()
        }
    }

    private func relayout() {
        journalTrees()
        let area = tilingArea
        guard var workspace = workspaces[activeWorkspace] else { return }

        var frames = workspace.frames(in: area, gaps: config.gaps)
        // A window already known not to fit its tile is floated before the write,
        // not after: the flash of it overlapping its neighbours happens once, the
        // first time it is measured, and never again.
        if floatWhatCannotFit(&workspace, frames: frames, in: area) {
            workspaces[activeWorkspace] = workspace
            journalTrees()
            frames = workspace.frames(in: area, gaps: config.gaps)
        }
        if isDryRun {
            for (id, rect) in frames {
                let name = registry.surface(for: id)?.appName ?? "?"
                log("would place \(name) [\(id)] at \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
            }
            return
        }

        // Apps that get a window here must be visible before their frames land.
        let activeApps = Set(workspace.all.compactMap { registry.surface(for: $0)?.pid })
        for pid in hiddenApps.intersection(activeApps) {
            hiddenApps.remove(pid)
            // Only wake an app that has a window to show here. An app whose last
            // window was closed has nothing to unhide, and an Electron app answers
            // being unhidden with no windows by making one — which is how Discord
            // reopened itself every time you came back to its workspace.
            guard registry.allSurfaces.contains(where: { $0.pid == pid }) else { continue }
            NSRunningApplication(processIdentifier: pid)?.unhide()
            reparkAfterUnhide(pid)
        }
        // The user can unhide an app too — Cmd+Tab, a Dock click — with the same
        // effect on its parked windows, and no call of ours to hang the fix on.
        for pid in hiddenApps where Accessibility.isHidden(pid: pid) == false {
            hiddenApps.remove(pid)
            reparkAfterUnhide(pid)
        }

        // Put away what belongs elsewhere, then bring back what belongs here. Both
        // are position writes: applying a parked window's tile frame is what
        // unparks it. Order matters only for looks — outgoing windows leave before
        // incoming ones land, so nothing overlaps for a frame.
        for (id, home) in homeWorkspace where home != activeWorkspace && !parked.contains(id) {
            guard let surface = registry.surface(for: id), !surface.isMinimized else { continue }
            parked.insert(id)
            parkedCorner[id] = .bottomRight
            parkedSlivers[id] = surface.park(.bottomRight)
        }
        // Remember which windows are arriving from a parked corner: those are off
        // screen right now and the frame write below is exactly what brings them back.
        let arriving = Set(workspace.all.filter { parked.contains($0) })
        for id in workspace.all where parked.contains(id) {
            parked.remove(id)
            parkedSlivers[id] = nil
            parkedCorner[id] = nil
        }
        apply(frames, arriving: arriving)

        // An app with nothing here is hidden whole: no sliver to place at all.
        // `hide()` returns false even on success, so wait on the truth instead.
        let parkedApps = Set(parked.compactMap { registry.surface(for: $0)?.pid })
        for pid in parkedApps.subtracting(activeApps).subtracting(hiddenApps) {
            NSRunningApplication(processIdentifier: pid)?.hide()
            if Accessibility.waitUntilHidden(pid: pid) { hiddenApps.insert(pid) }
        }

        placeSlivers(frames: frames)

        let model = canvasModel(workspace: activeWorkspace, frames: frames, active: actionTarget)
        canvas.update(model)
        statusItem.update(active: activeWorkspace,
                          count: config.workspaceCount,
                          occupied: model.occupiedWorkspaces,
                          names: config.workspaceNames)
        // The overview stays open while workspaces are switched under it, so it is
        // told too — otherwise it keeps pointing at wherever you were when it opened.
        overview.refresh(items: overviewItems(), accent: accentColor)
    }

    /// Unhiding an application makes AppKit put its off-screen windows back on
    /// screen — Safari cascades them 16pt from where they last were, Ghostty
    /// returns them to an older position — so every parked window of an app that
    /// was just unhidden is on screen again, behind the tiles, and has to be parked
    /// a second time. Measured: the re-park sticks once the unhide has landed.
    private func reparkAfterUnhide(_ pid: pid_t) {
        let deadline = Date().addingTimeInterval(0.2)
        while Accessibility.isHidden(pid: pid) == true, Date() < deadline { usleep(500) }
        for id in parked {
            guard let surface = registry.surface(for: id), surface.pid == pid else { continue }
            parkedSlivers[id] = surface.park(parkedCorner[id] ?? .bottomRight)
        }
    }

    /// Put every visible sliver under a tile that is stacked above it, and tell
    /// the cover where the holes go.
    ///
    /// The cover cannot be placed under a tile — it must stay above the parked
    /// windows, and the tiles and the parked windows are other apps' to stack.
    /// What *can* be done is choosing which corner a window parks in, raising a
    /// tile above its own app's parked windows, and reading the real stacking
    /// order. So for each sliver, in order of certainty:
    ///
    ///   1. A corner tile owned by the same app: raise it if the sliver is above
    ///      it. Within one app, raising is ours to do.
    ///   2. A corner tile owned by the app about to be focused: activation puts
    ///      every window of that app above every window of any other.
    ///   3. A corner tile the stacking order already shows above the sliver.
    ///
    /// Anything left is a sliver of the focused app in a workspace where that app
    /// owns neither bottom corner. It would show through a hole, so that corner's
    /// cover paints over the tile instead — the lesser artifact, and a narrow case.
    private func placeSlivers(frames: [SurfaceID: CGRect]) {
        guard let screen = Displays.all().first(where: \.isPrimary) else { return }
        let target = actionTarget
        let focusApp = target.flatMap { registry.surface(for: $0)?.pid }
        let order = Accessibility.stackingOrder()

        // The tile, if any, reaching into each corner's sliver zone.
        func cornerTile(_ corner: ParkCorner) -> (id: SurfaceID, surface: AXSurface, frame: CGRect)? {
            let zone = CGRect(x: corner == .bottomRight ? screen.frame.maxX - 40 : screen.frame.minX,
                              y: screen.frame.maxY - 52, width: 40, height: 52)
            for (id, frame) in frames where frame.intersects(zone) && !parked.contains(id) {
                if let surface = registry.surface(for: id) { return (id, surface, frame) }
            }
            return nil
        }
        let tiles: [ParkCorner: (id: SurfaceID, surface: AXSurface, frame: CGRect)?] =
            [.bottomRight: cornerTile(.bottomRight), .bottomLeft: cornerTile(.bottomLeft)]

        var raisedSomething = false
        var covers: [ParkCorner: CornerCover] = [.bottomRight: CornerCover(), .bottomLeft: CornerCover()]
        for corner in ParkCorner.allCases { covers[corner]?.tiles = [tiles[corner]??.frame].compactMap { $0 } }

        for id in parked {
            guard let surface = registry.surface(for: id), !hiddenApps.contains(surface.pid) else { continue }
            let current = parkedCorner[id] ?? .bottomRight

            // A parked window belongs at a screen edge. One that is not — an app
            // moved it, or put it back on screen for a reason not yet measured — is
            // simply parked again, so whatever the cause, it is never left showing.
            let actual = surface.frame
            let atEdge = actual.minX <= screen.frame.minX + 1 || actual.minX >= screen.frame.maxX - 41
            if !atEdge {
                parkedSlivers[id] = surface.park(current)
            } else {
                parkedSlivers[id] = actual
            }

            /// Whether the tile in `corner` will be stacked above this sliver.
            func covered(_ corner: ParkCorner) -> Bool {
                guard let tile = tiles[corner] ?? nil else { return false }
                if tile.surface.pid == surface.pid {
                    if let a = order[tile.surface.windowID], let b = order[surface.windowID], a > b {
                        tile.surface.raise()
                        raisedSomething = true
                    }
                    return true
                }
                if tile.surface.pid == focusApp { return true }
                if let a = order[tile.surface.windowID], let b = order[surface.windowID] { return a < b }
                return false
            }

            let chosen: ParkCorner?
            if covered(current) { chosen = current }
            else if covered(current.opposite) { chosen = current.opposite }
            else { chosen = nil }

            let place = chosen ?? current
            if place != current {
                parkedCorner[id] = place
                parkedSlivers[id] = surface.park(place)
            }
            covers[place]?.slivers.append(parkedSlivers[id] ?? surface.frame)
            if chosen == nil { covers[place]?.paintOverTiles = true }
        }

        // Raising changes which of its windows an app calls main, and that echoes
        // back as a focus report. Put focus back where it belongs, last.
        if raisedSomething, let target { registry.surface(for: target)?.focus() }
        cover.update(covers)
    }

    /// What the canvas should show for a workspace. Also what the switch overlay
    /// shows for the workspace being entered, so the two agree to the pixel.
    private func canvasModel(workspace index: Int, frames: [SurfaceID: CGRect], active: SurfaceID?) -> CanvasModel {
        var model = CanvasModel()
        model.slots = frames.map { id, rect in
            CanvasModel.Slot(frame: rect,
                             isActive: id == active,
                             label: registry.surface(for: id)?.appName ?? "")
        }
        model.dropTarget = index == activeWorkspace ? dropHighlight : nil
        model.workspaces = Array(1...config.workspaceCount)
        model.activeWorkspace = index
        model.occupiedWorkspaces = Set(workspaces.filter { !$0.value.isEmpty }.map(\.key))
        return model
    }

    /// The canvas alone, for a drag in progress: the model relayout would build,
    /// without writing a single window frame.
    private func refreshCanvas() {
        guard let workspace = workspaces[activeWorkspace] else { return }
        let frames = workspace.frames(in: tilingArea, gaps: config.gaps)
        canvas.update(canvasModel(workspace: activeWorkspace, frames: frames, active: actionTarget))
    }

    private func apply(_ frames: [SurfaceID: CGRect], arriving: Set<SurfaceID> = []) {
        // A window that is off screen, is not arriving from a parked corner, and whose
        // app hyprmac has not hidden, has been put away by its own app. Writing its
        // frame is what puts it back — and the evidence says that happens within
        // milliseconds of the hide, because the sweep below never once caught such a
        // window off screen across a whole test. Leave it where its app put it.
        let onScreen = Accessibility.onScreenWindowIDs()
        for (id, rect) in frames {
            guard let surface = registry.surface(for: id), !surface.isMinimized else { continue }
            if let onScreen, !arriving.contains(id), let ax = surface as? AXSurface,
               !onScreen.contains(ax.windowID), !hiddenApps.contains(ax.pid) {
                continue
            }
            surface.setFrame(rect)
        }
        scheduleFitCheck()
        // And look straight away rather than waiting for the next sweep: the window is
        // hidden right now, and every relayout is a chance to notice it.
        dropWindowsTheirAppsHid()
    }

    /// Float every tiled window whose known floor will not fit the tile it is about
    /// to be given. Returns whether anything moved.
    private func floatWhatCannotFit(_ workspace: inout Workspace, frames: [SurfaceID: CGRect], in area: CGRect) -> Bool {
        var moved = false
        for id in workspace.tiled where !keptTiled.contains(id) {
            guard let tile = frames[id], !minimums.fits(id, in: tile.size), let floor = minimums.minimum(for: id) else { continue }
            let name = registry.surface(for: id)?.appName ?? "?"
            // Only the axis it actually refused on is a floor; saying "0x600" for a
            // window that only ever refused a height reads as a bug in the journal.
            let refused = floor.width > 0 && floor.height > 0 ? "\(Int(floor.width))x\(Int(floor.height))"
                        : floor.width > 0 ? "\(Int(floor.width)) wide" : "\(Int(floor.height)) tall"
            workspace.setFloating(id, floatingRect(for: id, floor: floor, in: area))
            log("float: \(name) [\(id)] will not go below \(refused) and its tile is \(Int(tile.width))x\(Int(tile.height)) — floating it (ALT+V puts it back)")
            treeCause = "floated \(id) \(name) — will not fit its tile"
            moved = true
        }
        return moved
    }

    /// Where a floated window goes: its own smallest size, centred, never larger
    /// than the screen it has to live on.
    private func floatingRect(for id: SurfaceID, floor: CGSize, in area: CGRect) -> CGRect {
        let actual = registry.surface(for: id)?.frame.size ?? floor
        let width = min(max(floor.width, actual.width), area.width)
        let height = min(max(floor.height, actual.height), area.height)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    /// Ask, then look. Accessibility has no minimum-size attribute, and a frame is a
    /// request an app may decline, so the only way to learn that a window will not
    /// fit is to give it a tile and read back what it kept. A beat later, because
    /// the write returns before a slow app has finished resizing.
    private func scheduleFitCheck() {
        guard !fitCheckScheduled else { return }
        fitCheckScheduled = true
        let checking = activeWorkspace
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            fitCheckScheduled = false
            guard activeWorkspace == checking else { return }
            checkFit()
        }
    }

    private func checkFit() {
        let area = tilingArea
        guard var workspace = workspaces[activeWorkspace], workspace.root != nil else { return }
        let frames = workspace.frames(in: area, gaps: config.gaps)
        var learned = false
        for id in workspace.tiled where !keptTiled.contains(id) {
            guard let tile = frames[id], let surface = registry.surface(for: id), !surface.isMinimized else { continue }
            guard !parked.contains(id) else { continue }
            if minimums.note(id, asked: tile.size, got: surface.frame.size) { learned = true }
        }
        guard learned, floatWhatCannotFit(&workspace, frames: frames, in: area) else { return }
        workspaces[activeWorkspace] = workspace
        scheduleSessionSave()
        scheduleRelayout()
    }

    // MARK: Dispatch

    func dispatch(_ dispatcher: Dispatcher) {
        treeCause = "dispatch \(dispatcher)"
        switch dispatcher {
        case .terminal:
            openTerminal(dir: nil, run: nil)

        case .exec(let command):
            // `open -na App` (or `-n -a`): a launch we asked for, so its parked
            // window's focus must not be followed. Plain `open -a App` is the
            // opposite — it activates a running app and makes no window, and the
            // Safari bind counts on being followed to the parked one.
            if let name = Self.newWindowApp(in: command) { expectLaunch(ofAppNamed: name) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-lc", command]
            try? process.run()

        case .killActive, .closeWindow:
            guard let focused = actionTarget, let surface = registry.surface(for: focused) else { return }
            surface.close()

        case .moveFocus(let direction):
            guard let focused = actionTarget,
                  let root = workspaces[activeWorkspace]?.root,
                  let next = root.neighbor(of: focused, direction, in: tilingArea, gaps: config.gaps)
            else { return }
            self.focused = next
            workspaces[activeWorkspace]?.focused = next
            registry.surface(for: next)?.focus()
            scheduleRelayout()

        case .moveWindow(let direction):
            // A real move, not an exchange: pull the window out of the tree and
            // re-insert it beside its neighbour, on the side you pushed towards.
            // In a two-window layout this looks identical to a swap; with three or
            // more it is the difference between relocating a window and trading
            // places with whatever happened to be there.
            guard let focused = actionTarget,
                  var workspace = workspaces[activeWorkspace],
                  let root = workspace.root
            else { return }
            workspace.root = root.moving(focused, direction, in: tilingArea, gaps: config.gaps)
            workspaces[activeWorkspace] = workspace
            scheduleRelayout()

        case .swapWindow(let direction):
            guard let focused = actionTarget,
                  var workspace = workspaces[activeWorkspace],
                  let root = workspace.root,
                  let target = root.neighbor(of: focused, direction, in: tilingArea, gaps: config.gaps)
            else { return }
            workspace.root = root.swapping(focused, target)
            workspaces[activeWorkspace] = workspace
            scheduleRelayout()

        case .resizeActive(let dx, let dy):
            guard let focused = actionTarget, var workspace = workspaces[activeWorkspace],
                  let root = workspace.root else { return }
            let area = tilingArea
            var updated = root
            if dx != 0 {
                updated = updated.adjustingSplit(containing: focused, axis: .horizontal,
                                                 byPoints: dx, in: area, gaps: config.gaps)
            }
            if dy != 0 {
                updated = updated.adjustingSplit(containing: focused, axis: .vertical,
                                                 byPoints: dy, in: area, gaps: config.gaps)
            }
            workspace.root = updated
            workspaces[activeWorkspace] = workspace
            scheduleRelayout()

        case .toggleSplit:
            guard let focused = actionTarget, var workspace = workspaces[activeWorkspace],
                  let root = workspace.root else { return }
            workspace.root = root.togglingSplit(containing: focused)
            workspaces[activeWorkspace] = workspace
            scheduleRelayout()

        case .toggleFloating:
            guard let focused = actionTarget, var workspace = workspaces[activeWorkspace],
                  let surface = registry.surface(for: focused) else { return }
            let bundle = knownIdentity[focused]?.bundleID ?? surface.bundleID
            if workspace.floating[focused] != nil {
                // Put back by hand: hyprmac does not float it again, however badly
                // it fits, and the app stops floating by default too. Whose desktop
                // it is, is not in question.
                keptTiled.insert(focused)
                if let bundle, floatedApps.remove(bundle) != nil {
                    log("float: \(surface.appName) windows will tile again by default")
                }
                workspace.setTiled(focused, axis: tilingArea.naturalSplitAxis)
            } else {
                // Drop it to a comfortable centred size rather than leaving it
                // exactly tile-shaped, so floating reads as a distinct state.
                let area = tilingArea
                let size = CGSize(width: area.width * 0.5, height: area.height * 0.5)
                let origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
                keptTiled.remove(focused)
                if let bundle, floatedApps.insert(bundle).inserted {
                    log("float: \(surface.appName) windows will float from now on (ALT+V again puts them back)")
                }
                workspace.setFloating(focused, CGRect(origin: origin, size: size))
            }
            workspaces[activeWorkspace] = workspace
            scheduleRelayout()

        case .toggleFullscreen:
            guard let focused = actionTarget else { return }
            workspaces[activeWorkspace]?.toggleZoom(focused)
            // Raise it, or the windows it now covers can end up drawn on top.
            registry.surface(for: focused)?.focus()
            scheduleRelayout()

        case .workspaceRelative(let delta):
            dispatch(.workspace(config.workspace(from: activeWorkspace, offset: delta)))

        case .workspaceNamed(let name):
            guard let index = config.workspaceIndex(named: name) else {
                log("no workspace named '\(name)'")
                return
            }
            dispatch(.workspace(index))

        case .moveToWorkspaceNamed(let name):
            guard let index = config.workspaceIndex(named: name) else {
                log("no workspace named '\(name)'")
                return
            }
            dispatch(.moveToWorkspace(index))

        case .workspace(let index):
            guard let target = workspaces[index], index != activeWorkspace else { return }
            let perform = { [self] in
                if let focused { previouslyFocused = focused }
                activeWorkspace = index
                focused = workspaces[index]?.focused
                lastSwitch = CACurrentMediaTime()
                scheduleSessionSave()
                relayout()
                if let focused { registry.surface(for: focused)?.focus() }
            }
            if WorkspaceTransition.shouldAnimate(config), !isDryRun {
                // The overlay shows the workspace we are going to, with its slots
                // empty, so the windows appear to dissolve into those slots.
                let frames = target.frames(in: tilingArea, gaps: config.gaps)
                transition.run(model: canvasModel(workspace: index, frames: frames, active: target.resolvedFocus),
                               config: config, duration: config.animationDuration, switching: perform)
            } else {
                perform()
            }
            if config.workspaceHUD {
                hud.show(workspace: index,
                         name: config.workspaceNames[index],
                         of: Array(1...config.workspaceCount),
                         occupied: Set(workspaces.filter { !$0.value.isEmpty }.map(\.key)),
                         accent: accentColor)
            }

        case .moveToWorkspace(let index):
            // The bug this guards: `focused` could name a window on another
            // workspace, so this moved something the user could not even see.
            guard let moving = actionTarget else { return }
            move(moving, to: index)

        case .cycleNext, .cyclePrev:
            guard let workspace = workspaces[activeWorkspace] else { return }
            let order = workspace.tiled
            guard !order.isEmpty else { return }
            let current = actionTarget.flatMap { order.firstIndex(of: $0) } ?? 0
            let step = dispatcher == .cycleNext ? 1 : -1
            let next = order[(current + step + order.count) % order.count]
            focused = next
            workspaces[activeWorkspace]?.focused = next
            registry.surface(for: next)?.focus()
            scheduleRelayout()

        case .renameWorkspace:
            promptRename(workspace: activeWorkspace)

        case .askAgent:
            promptAgent()

        case .moveWorkspace(let delta):
            let target = config.workspace(from: activeWorkspace, offset: delta)
            guard target != activeWorkspace else { return }
            applyWorkspaceOrder(WorkspaceOrder.moving(from: activeWorkspace, to: target,
                                                      count: config.workspaceCount))
            if let focused { registry.surface(for: focused)?.focus() }
            if config.workspaceHUD {
                hud.show(workspace: activeWorkspace,
                         name: config.workspaceNames[activeWorkspace],
                         of: Array(1...config.workspaceCount),
                         occupied: Set(workspaces.filter { !$0.value.isEmpty }.map(\.key)),
                         accent: accentColor)
            }

        case .workspaceOverview:
            overview.toggle(items: overviewItems(), accent: accentColor)

        case .cheatsheet:
            cheatsheet.toggle(binds: config.binds)

        case .reload:
            reload()

        case .exit:
            statusItem.remove()
            // Un-park everything first, or the user is left hunting for windows
            // at (-25000, -25000) with no way to get them back.
            unparkAll()
            NSApp.terminate(nil)
        }
    }

    /// Rename one workspace by index, so the menu bar can rename a workspace you
    /// are not currently looking at.
    func promptRename(workspace index: Int) {
        prompt.ask(title: "RENAME WORKSPACE \(index)",
                   initial: config.workspaceNames[index] ?? "",
                   accent: accentColor,
                   onCommit: { [weak self] name in
                       guard let self else { return }
                       if name.isEmpty {
                           self.config.workspaceNames[index] = nil
                           self.renamedWorkspaces[index] = nil
                       } else {
                           self.config.workspaceNames[index] = name
                           self.renamedWorkspaces[index] = name
                       }
                       WorkspaceNameStore.save(self.renamedWorkspaces)
                       self.scheduleRelayout()
                   },
                   onDismiss: { [weak self] in
                       // Put the keyboard back where the user left it.
                       guard let self, let focused = self.focused else { return }
                       self.registry.surface(for: focused)?.focus()
                   })
    }

    /// Ask an agent something, typed.
    ///
    /// `VoiceGrammar` has carried a `.tellAgent(name:message:)` case — and unit tests for
    /// it — with nothing on the receiving end. This is that consumer, reached by keyboard
    /// rather than by microphone: the grammar was always the trustworthy half (speech
    /// recognisers are not), so it is worth using on its own.
    func promptAgent() {
        prompt.ask(title: "ASK", initial: "", accent: accentColor,
                   onCommit: { [weak self] text in self?.routeToAgent(text) },
                   onDismiss: { [weak self] in
                       guard let self, let focused = self.focused else { return }
                       self.registry.surface(for: focused)?.focus()
                   })
    }

    /// Send a typed utterance to whichever agent it names.
    ///
    /// The text is fed through the voice grammar with an "ask " opener so that typed and
    /// spoken input take exactly one code path. With a single agent configured the name is
    /// optional — you type the question and it goes there, which is how the hyprmac
    /// launcher's always-present "ask Wisper" row behaved.
    func routeToAgent(_ text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !config.agents.isEmpty else { return }

        var target: String?
        var message = typed
        if case let .tellAgent(name, spoken) = VoiceGrammar.parse("ask " + typed),
           let url = config.agents[name.lowercased()] {
            target = url
            message = spoken
        } else if config.agents.count == 1, let only = config.agents.first {
            // No name, one agent: it can only have meant that one.
            target = only.value
        }

        guard let prefix = target,
              // The question is user text going into a URL — a bare "?" or "&" in it would
              // silently truncate everything after.
              let encoded = message.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: prefix + encoded)
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Apply a whole new workspace ordering at once.
    ///
    /// `order[i]` names the workspace that becomes number `i + 1`. Trees, names,
    /// and the window-to-workspace map all move together, and the workspace you
    /// were on is followed to its new number rather than leaving you somewhere
    /// you did not ask to be.
    func applyWorkspaceOrder(_ order: [Int]) {
        guard Set(order) == Set(workspaces.keys), order.count == workspaces.count else { return }

        var rebuiltWorkspaces: [Int: Workspace] = [:]
        var rebuiltNames: [Int: String] = [:]
        var remap: [Int: Int] = [:]

        for (offset, old) in order.enumerated() {
            let new = offset + 1
            remap[old] = new
            var workspace = Workspace(index: new)
            if let source = workspaces[old] {
                workspace.root = source.root
                workspace.floating = source.floating
                workspace.focused = source.focused
                workspace.zoomed = source.zoomed
            }
            rebuiltWorkspaces[new] = workspace
            if let name = config.workspaceNames[old] { rebuiltNames[new] = name }
        }

        workspaces = rebuiltWorkspaces
        config.workspaceNames = rebuiltNames
        renamedWorkspaces = rebuiltNames
        WorkspaceNameStore.save(rebuiltNames)

        for (id, home) in homeWorkspace {
            if let moved = remap[home] { homeWorkspace[id] = moved }
        }
        if let followed = remap[activeWorkspace] { activeWorkspace = followed }
        focused = workspaces[activeWorkspace]?.focused

        scheduleSessionSave()
        relayout()
    }

    /// Dump live state to stderr. Wired to SIGUSR1 — the beginning of what will
    /// become the hyprctl IPC surface, and the only way to see why a tile is being
    /// held by a window that is no longer on screen.
    func dumpState() {
        let area = tilingArea
        log("--- state ---")
        log("active workspace: \(activeWorkspace)   tiling area: \(area)")
        log("registry holds \(registry.all.count) surface(s)")
        for index in workspaces.keys.sorted() {
            guard let workspace = workspaces[index], !workspace.isEmpty else { continue }
            log("workspace \(index)\(index == activeWorkspace ? " (active)" : ""):")
            if let root = workspace.root { log(root.description) }
            let frames = workspace.frames(in: area, gaps: config.gaps)
            for id in workspace.all {
                let surface = registry.surface(for: id)
                let name = surface?.appName ?? "<MISSING FROM REGISTRY>"
                let alive = surface.map { $0.isAlive ? "alive" : "DEAD" } ?? "-"
                let tileable = surface.map { $0.isTileable ? "tileable" : "NOT-TILEABLE" } ?? "-"
                let planned = frames[id].map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
                let actual = surface.map { s -> String in
                    let f = s.frame
                    return "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
                } ?? "?"
                log("  \(id) \(name) [\(alive), \(tileable)] planned \(planned) actual \(actual) title=\(surface?.title.prefix(24) ?? "")")
                if let surface, !surface.isTileable { log("      \(surface.tileabilityReport)") }
                if parked.contains(id) { log("      parked") }
            }
        }
        log("--- end ---")
    }

    /// Bring every parked window back on screen. Called on quit and on any
    /// catchable signal — otherwise the user is left with windows wedged into the
    /// corner and no running WM to fetch them.
    ///
    /// Each goes back to its tile on its own workspace, so the desktop ends up the
    /// way it would look with every workspace stacked on one screen: overlapping,
    /// but every window reachable.
    func unparkAll() {
        control.stop()
        guard !isDryRun else { return }
        saveSession()
        cover.remove()
        let area = tilingArea
        for (index, workspace) in workspaces where index != activeWorkspace {
            for (id, rect) in workspace.frames(in: area, gaps: config.gaps) where parked.contains(id) {
                registry.surface(for: id)?.setFrame(rect)
            }
        }
        parked.removeAll()
        parkedSlivers.removeAll()
        parkedCorner.removeAll()
        for pid in hiddenApps { NSRunningApplication(processIdentifier: pid)?.unhide() }
        hiddenApps.removeAll()
    }
}

// MARK: - Requests

extension WindowManager {
    /// Answer one control request. Every command is read-only except `dispatch`
    /// and `focus`, which do exactly what a keybind would.
    func handleControl(_ request: [String: Any]) -> [String: Any] {
        guard let cmd = request["cmd"] as? String else { return ["error": "missing cmd"] }
        switch cmd {
        case "status":   return controlStatus()
        case "windows":  return ["windows": controlWindows()]
        case "screen":
            // A name that matches nothing is an error, never the focused window:
            // "the news window" answered with Safari's contents is worse than no answer.
            if let match = request["match"] as? String, !match.isEmpty, controlMatch(match) == nil {
                return ["error": "no window matching '\(match)'; windows: \(controlWindows().map { "\($0["app"] ?? "") — \($0["title"] ?? "")" }.joined(separator: "; "))"]
            }
            let id = (request["id"] as? NSNumber).map { SurfaceID(UInt64(truncating: $0)) }
                ?? (request["match"] as? String).flatMap(controlMatch)
                ?? controlFocusedID
            guard let id, let surface = registry.surface(for: id) else { return ["error": "no such window"] }
            let limit = (request["limit"] as? NSNumber).map { Int(truncating: $0) } ?? 12_000
            return ["id": surface.id.raw, "app": surface.appName, "title": surface.title,
                    "text": surface.readableText(limit: max(200, min(limit, 60_000)))]
        case "dispatch":
            guard let name = request["name"] as? String else { return ["error": "missing name"] }
            let arg = (request["arg"] as? String) ?? ""
            guard let dispatcher = Dispatcher.parse(name, arg) else {
                return ["error": "unknown dispatcher '\(name)' with argument '\(arg)'"]
            }
            dispatch(dispatcher)
            return ["ok": true, "did": dispatcher.label]
        case "terminal":
            let workspace = (request["workspace"] as? NSNumber)?.intValue ?? Int(request["workspace"] as? String ?? "")
            openTerminal(dir: request["dir"] as? String, run: request["run"] as? String, workspace: workspace)
            return ["ok": true, "did": "opening a terminal window\(workspace.map { " on workspace \($0)" } ?? "")"]
        case "activate":
            // Bring an app forward on another app's behalf. Since macOS 14 an app's own
            // `NSApp.activate()` is a request the system may ignore — Wisper's was, once
            // `open -g` stopped LaunchServices doing it: her panel showed, never became
            // key, and typing went to the app behind. Under the Accessibility grant this
            // process can do it for her, the same way it focuses any window.
            guard let bundle = request["bundle"] as? String,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first(where: { !$0.isTerminated }) else {
                return ["error": "no running app with that bundle id"]
            }
            // Reply first, then act. The AX route needs the target's main thread to
            // answer, and when the target is the one asking over this socket, its main
            // thread is waiting on our reply — measured: 1.5 s on the AX timeout, every
            // ⌥Space. So: the plain activation now, the AX push a moment later and
            // only if the plain one did not take.
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard !app.isActive else { return }
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                app.activate()
            }
            return ["ok": true, "did": "activating \(app.localizedName ?? bundle)"]
        case "chat":
            // A message into a chat app's conversation: Discord (and Slack, the same
            // way) has a quick switcher on ⌘K that jumps to any DM or channel by
            // typed name, then the composer takes the words. Wisper tried
            // AppleScript on Discord, which has no dictionary. Focus the window,
            // wait for focus, ⌘K, type the name, Return, wait for the composer,
            // type the message, Return; every wait is on a real signal.
            guard let number = request["id"] as? NSNumber, let who = request["to"] as? String, !who.isEmpty,
                  let text = request["text"] as? String, !text.isEmpty else { return ["error": "missing id, to or text"] }
            let cid = SurfaceID(UInt64(truncating: number))
            guard let target = registry.surface(for: cid) else { return ["error": "no such window"] }
            let back = focused
            let pid = target.pid
            controlFocus(cid)
            Task { @MainActor [weak self] in
                guard let self else { return }
                var landed = false
                for _ in 0..<25 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if self.focused == cid { landed = true; break }
                }
                guard landed else { log("chat: window \(cid.raw) never took focus; nothing sent"); self.chatOutcomes[cid.raw] = "no focus"; return }
                // Tiling focus is not keyboard focus. Keystrokes go to the FRONTMOST
                // app, and after Wisper was just spoken to that is Wisper, whatever
                // window the tree calls focused — ⌘K and the name went nowhere,
                // three times, while the same keys from a shell worked. Bring the
                // app to the front and wait until macOS says it is.
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate()
                    var front = false
                    for _ in 0..<20 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { front = true; break }
                    }
                    guard front else { log("chat: \(target.appName) never came to the front; nothing sent"); self.chatOutcomes[cid.raw] = "no focus"; return }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                Keys.pressViaSystemEvents(40, into: target.appName, command: true)   // ⌘K: the quick switcher
                // Electron reports no focused text field; the switcher is known to
                // be open by its own words appearing in the window.
                var ready = false
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let words = target.readableText(limit: 2000).lowercased()
                    if words.contains("quick switcher") || words.contains("where would you like to go") || words.contains("search for") { ready = true; break }
                }
                guard ready else { log("chat: quick switcher never opened; nothing sent"); self.chatOutcomes[cid.raw] = "no switcher"; return }
                // The name has to be in the switcher's field before the results
                // mean anything: once it opened and the typed name never arrived —
                // the switcher sat on "PREVIOUS CHANNELS" and the ask was refused
                // as "nobody called Asscracker" (2 September). Typed again, once,
                // after clearing the field, if the first attempt went nowhere.
                var inField = false
                for attempt in 0..<2 where !inField {
                    if attempt > 0 {
                        Keys.pressViaSystemEvents(0, into: target.appName, command: true)   // ⌘A
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        Keys.pressViaSystemEvents(51, into: target.appName)                 // Delete
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                    Keys.typeViaSystemEvents(who, into: target.appName)
                    for _ in 0..<12 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        let lines = target.readableText(limit: 4000).split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                        if lines.contains(where: { $0.lowercased() == who.lowercased() }) { inField = true; break }
                    }
                }
                // The top result must be the person asked for, not whatever Discord
                // ranks first: "asscracker" put a recent channel at the top, Return
                // opened it, and the message went nowhere (2 September). Names in
                // Discord are often stylised — ᵃˢˢᶜʳᵃᶜᵏᵉʳ¹²³ — so the match folds
                // to plain letters. Two seconds for the results, then a decision.
                var matched = false
                let wantFolded = Self.foldName(who)
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let words = target.readableText(limit: 4000)
                    // With text in its field the switcher drops its heading; the
                    // first line is the typed name itself and the top result is
                    // the line after it. That line, folded, has to contain the name.
                    let lines = words.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if let typed = lines.firstIndex(where: { $0.lowercased() == who.lowercased() }), typed + 1 < lines.count {
                        let top = lines[typed + 1]
                        if !top.uppercased().hasPrefix("PROTIP"), Self.foldName(top).contains(wantFolded) { matched = true; break }
                    }
                }
                guard matched else {
                    let seen = target.readableText(limit: 600).split(separator: "\n").prefix(6).joined(separator: " | ")
                    log("chat: no result for '\(who)' at the top of the switcher; nothing sent. switcher showed: \(seen)")
                    // Escape closes the switcher — checked, and pressed again if it
                    // is still up, so the next ask does not open ⌘K onto a switcher
                    // that is already open and close it instead.
                    for _ in 0..<3 {
                        Keys.pressViaSystemEvents(53, into: target.appName)   // Escape: close the switcher, leave everything as it was
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if !target.readableText(limit: 2000).lowercased().contains("quick switcher") { break }
                    }
                    self.chatOutcomes[cid.raw] = "no match"
                    if let back, back != cid { self.controlFocus(back) }
                    return
                }
                Keys.pressViaSystemEvents(36, into: target.appName)                          // Return: open it
                // The conversation has opened when the window's own title names it
                // — "@ᵃˢˢᶜʳᵃᶜᵏᵉʳ¹²³ - Discord", "#chat | … - Discord" — folded, so the
                // stylised name still matches. (The composer's placeholder is there
                // too, but far down a long window's text.)
                // The composer itself shows as an empty mark; its toolbar ("Add
                // Emoji") is the sign it has been built — the title flips first,
                // while the view is still loading, and words typed then go nowhere.
                var composer = false
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Self.foldName(target.title).contains(wantFolded),
                       target.readableText(limit: 40_000).contains("Add Emoji") { composer = true; break }
                }
                guard composer else {
                    log("chat: the conversation never showed a composer; nothing sent")
                    self.chatOutcomes[cid.raw] = "no composer"
                    if let back, back != cid { self.controlFocus(back) }
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                // Whatever an earlier attempt left in the composer goes first: a run
                // that opened the DM and bailed left its words there, and the next
                // run typed the same words after them — one message, doubled.
                // Select-all then Delete in a text field is exactly that and no more.
                // The words must be in the composer before Return sends them; the
                // composer sits at the end of a long window, so the read is generous.
                // Focus can arrive a beat after the toolbar, so a second try — clear
                // first, so nothing doubles — before giving up.
                var held = false
                for attempt in 0..<2 where !held {
                    if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
                    Keys.pressViaSystemEvents(0, into: target.appName, command: true)   // ⌘A
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    Keys.pressViaSystemEvents(51, into: target.appName)                 // Delete
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    Keys.typeViaSystemEvents(text, into: target.appName)
                    for _ in 0..<15 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if target.readableText(limit: 40_000).contains(String(text.prefix(24))) { held = true; break }
                    }
                }
                guard held else {
                    log("chat: the composer never took the words; nothing sent")
                    // Leave nothing half-typed behind.
                    Keys.pressViaSystemEvents(0, into: target.appName, command: true)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    Keys.pressViaSystemEvents(51, into: target.appName)
                    self.chatOutcomes[cid.raw] = "not typed"
                    if let back, back != cid { self.controlFocus(back) }
                    return
                }
                Keys.pressViaSystemEvents(36, into: target.appName)
                log("chat: \(text.count) chars to \(who) in \(target.appName)")
                self.chatOutcomes[cid.raw] = "sent"
                if let back, back != cid { self.controlFocus(back) }
            }
            chatOutcomes[cid.raw] = "pending"
            return ["ok": true, "did": "messaging \(who) in \(target.appName)"]

        case "chat-status":
            // Wisper asks this after `chat`, so "sent" is said only once it is true.
            guard let number = request["id"] as? NSNumber else { return ["error": "missing id"] }
            return ["state": chatOutcomes[UInt64(truncating: number)] ?? "none"]

        case "rename":
            // Name a workspace — the same thing ⌥R does, without the prompt. Asked to
            // name one, Wisper had no way to and said "workspace 2 is now named
            // Working" anyway (2 September). An empty name clears it.
            guard let number = request["workspace"] as? NSNumber else { return ["error": "missing workspace"] }
            let index = Int(truncating: number)
            guard (1...9).contains(index) else { return ["error": "workspace must be 1–9"] }
            let name = (request["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                config.workspaceNames[index] = nil
                renamedWorkspaces[index] = nil
            } else {
                config.workspaceNames[index] = name
                renamedWorkspaces[index] = name
            }
            WorkspaceNameStore.save(renamedWorkspaces)
            scheduleRelayout()
            return ["ok": true, "did": name.isEmpty ? "cleared the name of workspace \(index)" : "named workspace \(index) \"\(name)\""]

        case "title":
            // Name a terminal window and keep it named. Ghostty's own `title`
            // setting forces a title and ignores what the program asks for, but it
            // is global; View ▸ Change Terminal Title does the same for one surface,
            // and a title set that way survives everything Claude Code writes
            // afterwards (watched for a minute while it worked, 2 September).
            // So an agent window can be called "daily planner" instead of whatever
            // the agent decided its current task should be called.
            guard let number = request["id"] as? NSNumber, let text = request["text"] as? String, !text.isEmpty else {
                return ["error": "missing id or text"]
            }
            let tid = SurfaceID(UInt64(truncating: number))
            guard let target = registry.surface(for: tid) else { return ["error": "no such window"] }
            let back = focused
            let pid = target.pid
            controlFocus(tid)
            Task { @MainActor [weak self] in
                guard let self else { return }
                var landed = false
                for _ in 0..<25 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if self.focused == tid { landed = true; break }
                }
                guard landed else { log("title: window \(tid.raw) never took focus"); return }
                guard AppMenus.press(menu: "View", startingWith: "Change Terminal Title", in: pid) else {
                    log("title: Ghostty has no Change Terminal Title item")
                    return
                }
                // Nothing is typed until the prompt is actually there. The first
                // version typed after a fixed delay, the sheet had not opened, and
                // the name went into the shell instead — "zsh: command not found:
                // workout". Keystrokes meant for a dialog must never reach a prompt.
                var prompt = false
                for _ in 0..<25 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if AppMenus.textFieldFocused(in: pid) { prompt = true; break }
                }
                guard prompt else {
                    log("title: the rename prompt never appeared; nothing typed")
                    if let back, back != tid { self.controlFocus(back) }
                    return
                }
                Keys.type(text, into: pid)
                try? await Task.sleep(nanoseconds: 150_000_000)
                Keys.press(36, into: pid)   // Return, apart from the text burst
                if let back, back != tid { self.controlFocus(back) }
            }
            return ["ok": true, "did": "naming that window \(text)"]

        case "close":
            // Close one window by id — the way `type` targets by id, where the
            // `closewindow` dispatcher only ever reaches the focused one. Grew for
            // agent windows: QA left "\u{2733} Hello to hello.txt" open on workspace 3
            // after both its tasks were done, and nothing could ask it to go.
            guard let number = request["id"] as? NSNumber else { return ["error": "missing id"] }
            let cid = SurfaceID(UInt64(truncating: number))
            guard let doomed = registry.surface(for: cid) else { return ["error": "no such window"] }
            let label = "\(doomed.appName) — \(doomed.title.prefix(40))"
            doomed.close()
            return ["ok": true, "did": "closed \(label)"]

        case "type":
            // A line into a window's own program — how a running agent is told a
            // follow-up instead of a second agent being spawned beside it. The
            // window is focused first and the keys wait until it actually holds
            // focus: typed at a fixed 0.4 s they fired mid-workspace-switch and
            // landed nowhere (both composers empty, measured). The user's focus is
            // handed back afterward — telling an agent is not travelling to it.
            guard let number = request["id"] as? NSNumber, let text = request["text"] as? String, !text.isEmpty else { return ["error": "missing id or text"] }
            let tid = SurfaceID(UInt64(truncating: number))
            guard let target = registry.surface(for: tid) else { return ["error": "no such window"] }
            let back = focused
            let pid = target.pid
            controlFocus(tid)
            Task { @MainActor [weak self] in
                guard let self else { return }
                var landed = false
                for _ in 0..<25 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if self.focused == tid { landed = true; break }
                }
                guard landed else { log("type: window \(tid.raw) never took focus; nothing typed"); return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if request["clear"] as? Bool == true {
                    Keys.press(53, into: pid)   // Escape: clear anything stale in the composer
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                Keys.type(text, into: pid)
                // The Return apart from the burst: inside it, the terminal coalesces
                // everything into a paste and the newline never submits.
                try? await Task.sleep(nanoseconds: 350_000_000)
                Keys.press(36, into: pid)
                log("type: \(text.count) chars + Return into \(target.appName) — \(target.title)")
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let back, back != tid, self.registry.surface(for: back) != nil { self.controlFocus(back) }
            }
            return ["ok": true, "did": "typing into \(target.appName) — \(target.title)"]
        case "summon":
            // Bring a window here, wherever it lives — "open the report in Safari on
            // this workspace" put the document in Safari's window on another one.
            guard let number = request["id"] as? NSNumber else { return ["error": "missing id"] }
            let sid = SurfaceID(UInt64(truncating: number))
            guard let surface = registry.surface(for: sid) else { return ["error": "no such window"] }
            if let home = homeWorkspace[sid], home != activeWorkspace {
                workspaces[home]?.remove(sid)
                homeWorkspace[sid] = activeWorkspace
                insertTiled(sid, into: activeWorkspace)
                scheduleSessionSave()
            }
            controlFocus(sid)
            scheduleRelayout()
            return ["ok": true, "did": "summoned \(surface.appName) — \(surface.title)"]
        case "focus":
            if let match = request["match"] as? String, !match.isEmpty, controlMatch(match) == nil {
                return ["error": "no window matching '\(match)'"]
            }
            let id = (request["id"] as? NSNumber).map { SurfaceID(UInt64(truncating: $0)) }
                ?? (request["match"] as? String).flatMap(controlMatch)
            guard let id, let surface = registry.surface(for: id) else { return ["error": "missing id"] }
            controlFocus(id)
            return ["ok": true, "did": "focus \(surface.appName) — \(surface.title)"]
        case "say":
            // Spoken words. The grammar decides whether this is a window-manager
            // command — "focus left", "workspace three" — and if so it is done here,
            // instantly, without waiting on a model. Anything else is the caller's.
            guard let text = request["text"] as? String else { return ["error": "missing text"] }
            switch VoiceGrammar.parse(text) {
            case .dispatch(let dispatcher):
                dispatch(dispatcher)
                return ["handled": true, "did": dispatcher.label]
            case .cancel:
                return ["handled": true, "did": "cancelled"]
            default:
                return ["handled": false]
            }
        default:
            return ["error": "unknown cmd '\(cmd)'; try status, windows, screen, dispatch, focus, say"]
        }
    }

    /// The window a question is about: the focused one, unless that is Wisper
    /// herself — asking her focuses her, and she should not answer about her own
    /// transcript — in which case the window focused before her.
    /// A window by name: "news", "safari", "build log". App name first, then
    /// title, case-insensitive substring; ties go to the active workspace, then
    /// to the most recently focused. So "the news window" resolves without the
    /// model having to fetch ids first — which, measured, it would not do.
    private func controlMatch(_ needle: String) -> SurfaceID? {
        let wanted = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        func score(_ id: SurfaceID) -> Int? {
            guard let surface = registry.surface(for: id) else { return nil }
            let app = surface.appName.lowercased(), title = surface.title.lowercased()
            var score = 0
            if app == wanted { score = 40 } else if app.contains(wanted) { score = 30 }
            else if title.hasPrefix(wanted) { score = 20 } else if title.contains(wanted) { score = 10 }
            else { return nil }
            if homeWorkspace[id] == activeWorkspace { score += 5 }
            if id == focused { score += 3 } else if id == previouslyFocused { score += 2 }
            return score
        }
        return homeWorkspace.keys.compactMap { id in score(id).map { (id, $0) } }.max { $0.1 < $1.1 }?.0
    }

    private var controlFocusedID: SurfaceID? {
        let target = actionTarget
        guard let target, registry.surface(for: target)?.bundleID == Self.wisperBundleID else { return target }
        if let previous = previouslyFocused, registry.surface(for: previous) != nil { return previous }
        return workspaces[activeWorkspace]?.all.first { $0 != target }
    }

    private static let wisperBundleID = "dev.keenancarroll.wisper"

    private func controlStatus() -> [String: Any] {
        // Local time, with the zone. UTC here beside a local time in Wisper's
        // context line had her reasoning about a four-hour discrepancy.
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy, HH:mm zzz"
        let windows = controlWindows()
        var spaces: [[String: Any]] = []
        for index in 1...config.workspaceCount {
            var entry: [String: Any] = ["index": index,
                                        "windows": windows.filter { ($0["workspace"] as? Int) == index }]
            if let name = config.workspaceNames[index] { entry["name"] = name }
            spaces.append(entry)
        }
        var out: [String: Any] = ["active": activeWorkspace, "date": formatter.string(from: Date()),
                                  "workspaces": spaces]
        if let id = controlFocusedID, let surface = registry.surface(for: id) {
            var focused: [String: Any] = ["id": id.raw, "app": surface.appName, "title": surface.title]
            // Where that window lives. Asking Wisper switches to her workspace, so
            // "active" is hers by the time she looks; this is the one you meant.
            if let home = homeWorkspace[id] {
                focused["workspace"] = home
                if let name = config.workspaceNames[home] { focused["workspaceName"] = name }
            }
            out["focused"] = focused
        }
        return out
    }

    private func controlWindows() -> [[String: Any]] {
        let focused = controlFocusedID
        return homeWorkspace.compactMap { id, home in
            guard let surface = registry.surface(for: id) else { return nil }
            let f = surface.frame
            return ["id": id.raw, "app": surface.appName, "title": surface.title,
                    "bundle": surface.bundleID ?? "", "workspace": home, "focused": id == focused,
                    "floating": workspaces[home]?.floating[id] != nil,
                    "frame": ["x": Int(f.minX), "y": Int(f.minY), "w": Int(f.width), "h": Int(f.height)]]
        }.sorted { ($0["workspace"] as! Int, $0["id"] as! UInt64) < ($1["workspace"] as! Int, $1["id"] as! UInt64) }
    }

    static let ghosttyBundle = "com.mitchellh.ghostty"

    /// The app an `open` in a shell command asks a new window of: the first
    /// non-flag word after `open`, when its flags include both `-n` and `-a`
    /// (`-na`, `-n -a`, `-gna`). Nil for anything else.
    static func newWindowApp(in command: String) -> String? {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let at = words.firstIndex(of: "open") else { return nil }
        var flags = ""
        for word in words[(at + 1)...] {
            if word.hasPrefix("-") { flags += word; continue }
            guard flags.contains("n"), flags.contains("a") else { return nil }
            return word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// Note a launch we caused, by app name. Only an app already running can have a
    /// parked window to hand its activation, so a running app is the only one worth
    /// finding; the name is matched as the app names itself, or as its bundle is
    /// named on disk, squashed to lowercase letters and digits.
    func expectLaunch(ofAppNamed name: String) {
        guard !name.isEmpty else { return }
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let key = squash(name)
        let match = NSWorkspace.shared.runningApplications.first { app in
            guard !app.isTerminated, app.activationPolicy == .regular else { return false }
            if let n = app.localizedName, squash(n) == key { return true }
            if let u = app.bundleURL, squash(u.deletingPathExtension().lastPathComponent) == key { return true }
            return false
        }
        guard let bundle = match?.bundleIdentifier else { return }
        expectedLaunch = (bundle: bundle, at: CACurrentMediaTime())
    }

    /// A new Ghostty window in the instance that already has windows — File ▸ New
    /// Window over Accessibility — then, once it exists, focus it and type one line
    /// into its shell. `open -na Ghostty` was the old way: a second Ghostty per call,
    /// each a Dock icon, each staying behind after its window closed. Measured: four.
    /// A window on the active workspace to another, without following it.
    private func move(_ moving: SurfaceID, to index: Int) {
        guard workspaces[index] != nil, index != activeWorkspace else { return }
        workspaces[activeWorkspace]?.remove(moving)
        homeWorkspace[moving] = index
        insertTiled(moving, into: index)
        scheduleSessionSave()
        focused = workspaces[activeWorkspace]?.focused
        scheduleRelayout()
    }

    /// `workspace`: where the window should live once its line is in. The person
    /// stays where they are — "in workspace 3, open two agents", said from
    /// workspace 1, put both on 1, because nothing on this path could say otherwise.
    func openTerminal(dir: String?, run: String?, workspace: Int? = nil) {
        let before = Set(registry.allSurfaces.filter { $0.bundleID == Self.ghosttyBundle }.map(\.id))
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ghosttyBundle).filter { !$0.isTerminated }
        if let main = instances.max(by: { a, b in
            registry.allSurfaces.filter { $0.pid == a.processIdentifier }.count < registry.allSurfaces.filter { $0.pid == b.processIdentifier }.count
        }) {
            expectedLaunch = (bundle: Self.ghosttyBundle, at: CACurrentMediaTime())
            main.activate()
            if !AppMenus.press(menu: "File", item: "New Window", in: main.processIdentifier) {
                NSLog("terminal: could not press File ▸ New Window in Ghostty \(main.processIdentifier)")
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.ghosttyBundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSLog("terminal: Ghostty is not installed"); return
        }
        var line = ""
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if let dir, !dir.isEmpty { line = "cd \(q(dir))" }
        if let run, !run.isEmpty { line += (line.isEmpty ? "" : " && ") + "clear && " + run }
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                guard let fresh = registry.allSurfaces.first(where: { $0.bundleID == Self.ghosttyBundle && !before.contains($0.id) }) else { continue }
                controlFocus(fresh.id)
                if !line.isEmpty {
                    // The shell needs a moment to reach its prompt; the tty buffers
                    // what arrives early, but a clean line is nicer to look at.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    Keys.type(line + "\n", into: fresh.pid)
                }
                if let workspace, workspace != activeWorkspace, workspaces[workspace] != nil {
                    // Once the line has been typed into it — keys go to the window
                    // that has focus, and a parked window does not.
                    try? await Task.sleep(nanoseconds: line.isEmpty ? 100_000_000 : 700_000_000)
                    move(fresh.id, to: workspace)
                    NSLog("terminal: window \(fresh.id) sent to workspace \(workspace)")
                }
                return
            }
            NSLog("terminal: no new Ghostty window appeared in 8s")
        }
    }

    /// Ghostty instances with no windows are debris; one instance is the app. When
    /// there is more than one, the empty ones go. Run a moment after a window closes.
    private func reapEmptyTerminalInstances() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ghosttyBundle).filter { !$0.isTerminated }
        guard apps.count > 1 else { return }
        for app in apps where !registry.allSurfaces.contains(where: { $0.pid == app.processIdentifier }) {
            NSLog("terminal: quitting empty Ghostty instance \(app.processIdentifier)")
            app.terminate()
        }
    }

    /// Open a mail draft to support with everything that would otherwise have to be
    /// asked for: which build, which Mac, how many displays, and what the journal said
    /// just before. A bug report costs the reporter nothing but the description, which
    /// is the only part they can actually supply.
    private func reportBug() {
        let info = Bundle.main.infoDictionary ?? [:]
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)

        var report = """
            What happened:


            What you expected instead:


            How to make it happen again:


            ---- diagnostics, please leave this in ----
            hyprmac \(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))
            \(ProcessInfo.processInfo.operatingSystemVersionString)
            \(String(cString: model))
            displays: \(NSScreen.screens.count) · workspaces: \(config.workspaceCount) · windows: \(homeWorkspace.count)
            accessibility: \(Accessibility.isTrusted ? "allowed" : "NOT allowed")

            """
        // The tail of the journal, trimmed: a mailto that grows past a few thousand
        // characters is silently truncated by some mail clients, and a truncated
        // report is worse than a short one.
        if let log = try? String(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/hyprmac.log"), encoding: .utf8) {
            let tail = log.split(separator: "\n").suffix(40).joined(separator: "\n")
            report += "\nlast 40 log lines:\n" + String(tail.suffix(3500))
        }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        let subject = "hyprmac \(info["CFBundleVersion"] as? String ?? "") — bug report"
        guard let s = subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let b = report.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "mailto:support@wisp-os.com?subject=\(s)&body=\(b)")
        else { return }
        log("report: opening a bug report to support@wisp-os.com (\(report.count) characters)")
        NSWorkspace.shared.open(url)
    }

    /// Let go of a window whose app has hidden it rather than closed it.
    ///
    /// Some apps — Discord among them — answer their close button by hiding the window
    /// and keeping it alive. Accessibility still reports it, so nothing tells hyprmac
    /// it is gone, and the next relayout writes its frame: the window the user just
    /// closed reappears when they come back to that workspace.
    ///
    /// Only windows on the *active* workspace are considered, and that restriction is
    /// the whole safety of this. A parked window is not on screen either — measured:
    /// every Ghostty window on another workspace reads exactly the same as the hidden
    /// Discord one — so a check written against all windows would throw away every
    /// window the user was not currently looking at.
    private func dropWindowsTheirAppsHid() {
        guard let workspace = workspaces[activeWorkspace] else { return }
        guard let onScreen = Accessibility.onScreenWindowIDs() else { return }
        var stillMissing: Set<SurfaceID> = []
        for id in workspace.all {
            guard let surface = registry.surface(for: id) as? AXSurface else { continue }
            guard !onScreen.contains(surface.windowID) else { continue }
            // Say why, when it is off screen and kept anyway: the alternative is a
            // sweep that quietly does nothing and no way to tell which test refused.
            if parked.contains(id) || surface.isMinimized || hiddenApps.contains(surface.pid) {
                log("gone? \(surface.appName) [\(id)] off screen but kept — parked=\(parked.contains(id)) minimized=\(surface.isMinimized) appHidden=\(hiddenApps.contains(surface.pid))")
                continue
            }
            stillMissing.insert(id)
            guard missingFromScreen.contains(id) else {
                // First sighting. Confirm it in a moment rather than at the next
                // three-second tick: the tile is still drawn on the canvas until this
                // resolves, so the wait is something the user sits and looks at.
                scheduleMissingRecheck()
                continue
            }
            log("gone: \(surface.appName) [\(id)] is on this workspace but not on screen — its app hid it rather than closing it")
            registry.forget(id)
        }
        missingFromScreen = stillMissing
    }

    /// A second look, soon. Two sightings before letting go of a window is what keeps
    /// a momentary absence — an app mid-hide, a window not yet mapped — from being
    /// mistaken for one the user closed; 300 ms is long enough to tell those apart and
    /// short enough that nobody watches an empty tile waiting for it.
    private func scheduleMissingRecheck() {
        guard !recheckScheduled else { return }
        recheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.recheckScheduled = false
            self?.dropWindowsTheirAppsHid()
        }
    }

    /// Every window in every workspace, as its application's icon. Icons are cheap
    /// and need no permission; a thumbnail would need Screen Recording.
    private func overviewItems() -> [WorkspaceOverview.Item] {
        var icons: [pid_t: NSImage?] = [:]
        return (1...config.workspaceCount).map { index in
            let entries = (workspaces[index]?.all ?? []).compactMap { id -> WorkspaceOverview.Entry? in
                guard let surface = registry.surface(for: id) else { return nil }
                let icon = icons[surface.pid] ?? {
                    let found = NSRunningApplication(processIdentifier: surface.pid)?.icon
                    icons[surface.pid] = found
                    return found
                }()
                return WorkspaceOverview.Entry(id: id, icon: icon,
                                               title: "\(surface.appName) — \(surface.title)")
            }
            return WorkspaceOverview.Item(index: index,
                                          name: config.workspaceNames[index],
                                          entries: entries,
                                          isActive: index == activeWorkspace)
        }
    }

    private func controlFocus(_ id: SurfaceID) {
        if let home = homeWorkspace[id], home != activeWorkspace {
            workspaces[home]?.focused = id
            dispatch(.workspace(home))
        } else {
            if focused != id { previouslyFocused = focused }
            focused = id
            workspaces[activeWorkspace]?.focused = id
            registry.surface(for: id)?.focus()
            scheduleRelayout()
        }
    }
}
