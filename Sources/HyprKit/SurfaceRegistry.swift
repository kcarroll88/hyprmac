import ApplicationServices
import AppKit
import HyprCore

public protocol SurfaceRegistryDelegate: AnyObject {
    func registry(_ registry: SurfaceRegistry, didAdd surface: Surface)
    func registry(_ registry: SurfaceRegistry, didRemove id: SurfaceID)
    func registry(_ registry: SurfaceRegistry, didFocus id: SurfaceID)
    /// Minimize state changed. The manager decides whether this was its own doing
    /// (hiding a workspace) or the user's.
    func registry(_ registry: SurfaceRegistry, didChangeMinimized id: SurfaceID, isMinimized: Bool)
}

/// Tracks every tileable window on the system and reports changes.
///
/// Two sources feed it: AX observers per application (fast, event-driven) and a
/// full rescan on app launch/terminate (the safety net, because AX notifications
/// are not perfectly reliable and some apps create windows before they are
/// observable).
public final class SurfaceRegistry {
    public weak var delegate: SurfaceRegistryDelegate?

    private var surfaces: [SurfaceID: AXSurface] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    /// Bundle ids we never manage. The WM's own windows and the system UI.
    private var ignoredBundleIDs: Set<String> = [
        "com.apple.finder.desktop",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.dock",
        "com.apple.WindowManager",
    ]

    public init() {}

    public var all: [AXSurface] { Array(surfaces.values) }

    /// The window the system considers focused right now, read live rather than
    /// remembered. Notifications are best-effort and a missed one leaves a stale
    /// cache; a command about to move a window deserves ground truth.
    public var systemFocused: SurfaceID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = element.attribute(kAXFocusedWindowAttribute),
              let wid = Accessibility.windowID(of: window) else { return nil }
        return SurfaceID(UInt64(wid))
    }
    public func surface(for id: SurfaceID) -> AXSurface? { surfaces[id] }
    public var allSurfaces: [AXSurface] { Array(surfaces.values) }

    public func ignore(bundleIDs: [String]) { ignoredBundleIDs.formUnion(bundleIDs) }

    // MARK: Lifecycle

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        rescan()
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // A freshly launched app usually has no windows yet, and is often not
        // observable for a beat. Retry rather than miss its first window.
        attach(to: app, retriesRemaining: 10)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        detach(pid: app.processIdentifier)
        for (id, surface) in surfaces where surface.pid == app.processIdentifier {
            surfaces[id] = nil
            delegate?.registry(self, didRemove: id)
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = element.attribute(kAXFocusedWindowAttribute),
              let id = Accessibility.windowID(of: focused) else { return }
        delegate?.registry(self, didFocus: SurfaceID(UInt64(id)))
    }

    /// Full sweep of every running app. Cheap enough to call on a timer as a backstop.
    public func rescan() {
        for app in NSWorkspace.shared.runningApplications where isManageable(app) {
            attach(to: app, retriesRemaining: 0)
            adopt(windowsOf: app)
        }
        // Evict anything whose window has gone without us hearing about it.
        for (id, surface) in surfaces where !surface.isAlive {
            surfaces[id] = nil
            delegate?.registry(self, didRemove: id)
        }
    }

    private func isManageable(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular else { return false }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        if let bundle = app.bundleIdentifier, ignoredBundleIDs.contains(bundle) { return false }
        return true
    }

    private func adopt(windowsOf app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows: [AXUIElement] = element.attribute(kAXWindowsAttribute) else { return }
        for window in windows {
            guard let surface = AXSurface(element: window,
                                          pid: app.processIdentifier,
                                          appName: app.localizedName ?? "?",
                                          bundleID: app.bundleIdentifier) else { continue }
            guard surfaces[surface.id] == nil, surface.isTileable || surface.isMinimized else { continue }
            surfaces[surface.id] = surface
            delegate?.registry(self, didAdd: surface)
        }
    }

    // MARK: AX observers

    private func attach(to app: NSRunningApplication, retriesRemaining: Int) {
        let pid = app.processIdentifier
        guard isManageable(app), observers[pid] == nil else { return }

        var observer: AXObserver?
        let status = AXObserverCreate(pid, axCallback, &observer)
        guard status == .success, let observer else {
            if retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.attach(to: app, retriesRemaining: retriesRemaining - 1)
                }
            }
            return
        }

        let element = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification,
                     kAXUIElementDestroyedNotification,
                     kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification,
                     kAXFocusedWindowChangedNotification,
                     kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        adopt(windowsOf: app)
    }

    private func detach(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    fileprivate func handle(notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard let app = NSRunningApplication(processIdentifier: pid), isManageable(app) else { return }
            guard let surface = AXSurface(element: element, pid: pid,
                                          appName: app.localizedName ?? "?",
                                          bundleID: app.bundleIdentifier) else { return }
            guard surfaces[surface.id] == nil, surface.isTileable else { return }
            surfaces[surface.id] = surface
            delegate?.registry(self, didAdd: surface)

        case kAXUIElementDestroyedNotification:
            // A destroyed element can no longer report its own id, so find it by identity.
            guard let (id, _) = surfaces.first(where: { CFEqual($0.value.element, element) }) else { return }
            surfaces[id] = nil
            delegate?.registry(self, didRemove: id)

        case kAXWindowMiniaturizedNotification:
            // A minimized window still exists and keeps its place in the layout —
            // minimizing is how workspaces hide windows, so this must not evict.
            guard let (id, _) = surfaces.first(where: { CFEqual($0.value.element, element) }) else { return }
            delegate?.registry(self, didChangeMinimized: id, isMinimized: true)

        case kAXWindowDeminiaturizedNotification:
            if let (id, _) = surfaces.first(where: { CFEqual($0.value.element, element) }) {
                delegate?.registry(self, didChangeMinimized: id, isMinimized: false)
            } else {
                rescan()
            }

        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            // The element may be the window, or the application that owns it.
            // Dropping the second case silently loses every focus change between
            // two windows of the same app — which then leaves commands pointed at
            // whichever of its windows was focused before.
            if let wid = Accessibility.windowID(of: element) {
                delegate?.registry(self, didFocus: SurfaceID(UInt64(wid)))
                return
            }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard pid != 0 else { return }
            let app = AXUIElementCreateApplication(pid)
            guard let window: AXUIElement = app.attribute(kAXFocusedWindowAttribute),
                  let wid = Accessibility.windowID(of: window) else { return }
            delegate?.registry(self, didFocus: SurfaceID(UInt64(wid)))

        default:
            break
        }
    }
}

/// AX observer callbacks are C function pointers, so `self` rides along in refcon.
private func axCallback(observer: AXObserver, element: AXUIElement,
                        notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let registry = Unmanaged<SurfaceRegistry>.fromOpaque(refcon).takeUnretainedValue()
    registry.handle(notification: notification as String, element: element)
}
