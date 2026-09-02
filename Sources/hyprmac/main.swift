import AppKit
import HyprCore
import HyprKit

// One window manager at a time. A stale bundle with the same id launched beside the
// live one (measured: two, fighting over every window) — the newcomer quits.
if let me = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: me).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        FileHandle.standardError.write("hyprmac: already running (pid \(others.map { String($0.processIdentifier) }.joined(separator: ", "))); this one quits\n".data(using: .utf8)!)
        exit(0)
    }
}


/// The WM has no dock icon and no menu bar presence; it is a background agent
/// that happens to draw a desktop.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let isDryRun: Bool
    private var manager: WindowManager?
    private var signalSources: [DispatchSourceSignal] = []

    init(dryRun: Bool) {
        self.isDryRun = dryRun
    }

    /// Polls for the Accessibility grant while the app is running without it.
    private var trustPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without Accessibility every AX call fails silently, so hyprmac used to
        // exit here rather than limp along. That made the welcome screen — the one
        // thing that explains the permission — unreachable on precisely the machine
        // that needs it: a new user saw macOS's own prompt, and hyprmac was already
        // gone. Now it runs, manages nothing, and says what it is waiting for.
        guard Accessibility.isTrusted else {
            Accessibility.requestTrust()
            log("waiting for Accessibility — no window is managed until it is granted")
            WelcomeWindow.shared.showWaitingForAccessibility()
            // The grant only reaches a newly launched process, so when it lands the
            // only useful thing to do is start again. Closing the window does not
            // stop this: it goes on waiting in the background.
            if WelcomeWindow.isTranslocated {
                log("running from an App Translocation copy — no permission can stick to it; move hyprmac to /Applications")
            }
            // One restart, never a loop. Restarting only helps if the new process can
            // see the grant; when it cannot, doing it again gives a Mac that relaunches
            // hyprmac forever and never works, with nothing on screen saying why.
            if WelcomeWindow.restartDidNotHelp {
                log("Accessibility still not seen after restarting — stopping rather than restarting again")
            } else {
                trustPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                    guard Accessibility.isTrusted else { return }
                    timer.invalidate()
                    self?.trustPoll = nil
                    log("Accessibility granted — restarting to pick it up")
                    WelcomeWindow.relaunch()
                }
            }
            return
        }

        WelcomeWindow.noteTrusted()
        let (config, diagnostics) = ConfigStore.load()
        for diagnostic in diagnostics {
            log("config:\(diagnostic.line): \(diagnostic.message)")
        }

        let manager = WindowManager(config: config, dryRun: isDryRun)
        self.manager = manager
        installSignalHandlers()
        manager.start()

        if isDryRun {
            log("DRY RUN — computing layouts, not touching any window")
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("running — build \(build), config at \(ConfigStore.path.path)")
        // What actually took is reported by `bindHotkeys` itself, and only when
        // something did not: this line is the greeting, not the evidence.
        log("\(config.binds.count) binds in \(ConfigStore.path.lastPathComponent); ALT+SHIFT+Q to quit")

        // First run, or a run without the one permission it needs: say so, rather
        // than failing every Accessibility call in silence and looking broken.
        if !isDryRun { WelcomeWindow.shared.showIfNeeded(usesVerticalSwipe: config.gestureOverview) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.unparkAll()
    }

    /// `applicationWillTerminate` never fires for a plain `kill`, which would strand
    /// every parked window at (-25000, -25000) with no way for the user to reach it.
    /// These handlers make SIGTERM and SIGINT recover the same way a clean quit does.
    private func installSignalHandlers() {
        // SIGUSR1 dumps state instead of quitting.
        signal(SIGUSR1, SIG_IGN)
        let dump = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        dump.setEventHandler { [weak self] in self?.manager?.dumpState() }
        dump.resume()
        signalSources.append(dump)

        for number in [SIGINT, SIGTERM, SIGHUP] {
            // The default disposition must go, or the process dies before the
            // dispatch source ever runs.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                log("caught signal \(number); restoring windows")
                self?.manager?.unparkAll()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// `~/Library/Logs/hyprmac.log`, beside stderr. Launched from the Dock, stderr is
/// nowhere, and "the windows rearranged again" had nothing to read. Rotated once
/// at 2 MB to `.1`.
enum LogFile {
    static let handle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let url = dir.appendingPathComponent("hyprmac.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let old = dir.appendingPathComponent("hyprmac.log.1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        try? h.seekToEnd()
        return h
    }()
    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
}

func log(_ message: String) {
    FileHandle.standardError.write("hyprmac: \(message)\n".data(using: .utf8)!)
    if let data = "\(LogFile.stamp.string(from: Date())) \(message)\n".data(using: .utf8) { LogFile.handle?.write(data) }
}

let arguments = CommandLine.arguments
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    hyprmac — a tiling window manager for macOS, with Wisper as its brain

    usage: hyprmac [--dry-run]

      --dry-run   Discover windows and compute layouts, logging what it would do,
                  without moving anything. Use this while developing.
      --help      This message.

    Config: ~/.config/wisp/wispos.conf (written on first run)
    """)
    exit(0)
}

let dryRun = arguments.contains("--dry-run")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(dryRun: dryRun)
app.delegate = delegate
app.run()
