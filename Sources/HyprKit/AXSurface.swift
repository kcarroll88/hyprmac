import ApplicationServices
import AppKit
import HyprCore

/// A real window belonging to another application, driven over the Accessibility API.
public final class AXSurface: Surface {
    public let id: SurfaceID
    public let element: AXUIElement
    public let pid: pid_t
    public let appName: String
    public let bundleID: String?

    /// Last frame we asked for. Used to skip redundant AX writes, which are
    /// synchronous round-trips into the target app and are the main cost of tiling.
    private var lastRequested: CGRect?

    public init?(element: AXUIElement, pid: pid_t, appName: String, bundleID: String?) {
        guard let wid = Accessibility.windowID(of: element) else { return nil }
        self.id = SurfaceID(UInt64(wid))
        self.element = element
        // Half a second, not the default six. An app that does not answer — hung,
        // or blocked waiting on us over the control socket — must not stall the
        // window manager, and nothing healthy takes longer than this.
        AXUIElementSetMessagingTimeout(element, 0.5)
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
    }

    public var title: String { element.attribute(kAXTitleAttribute) ?? "" }

    public var isAlive: Bool {
        // Any successful attribute read proves the element still resolves.
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw)
        return status != .invalidUIElement && status != .cannotComplete
    }

    public var isMinimized: Bool {
        (element.attribute(kAXMinimizedAttribute) as NSNumber?)?.boolValue ?? false
    }

    public var isFullscreen: Bool {
        (element.attribute("AXFullScreen") as NSNumber?)?.boolValue ?? false
    }

    public var isTileable: Bool {
        // Only real, standard windows. Sheets, drawers, popovers and palettes keep
        // their own geometry.
        guard let role: String = element.attribute(kAXRoleAttribute), role == kAXWindowRole else { return false }
        if let subrole: String = element.attribute(kAXSubroleAttribute), subrole != kAXStandardWindowSubrole {
            return false
        }
        guard !isMinimized, !isFullscreen else { return false }
        // A window we cannot move or resize can't participate in a tiling layout.
        return element.isSettable(kAXPositionAttribute) && element.isSettable(kAXSizeAttribute)
    }

    /// Which specific check rejects this window. Diagnostic only — a parallel probe
    /// from another process can disagree with what our own cached element sees.
    public var tileabilityReport: String {
        let role: String = element.attribute(kAXRoleAttribute) ?? "<nil>"
        let subrole: String = element.attribute(kAXSubroleAttribute) ?? "<nil>"
        return "role=\(role) subrole=\(subrole) min=\(isMinimized) full=\(isFullscreen) "
            + "setPos=\(element.isSettable(kAXPositionAttribute)) setSize=\(element.isSettable(kAXSizeAttribute))"
    }

    public var frame: CGRect {
        guard let origin = element.point(kAXPositionAttribute),
              let size = element.size(kAXSizeAttribute) else { return .zero }
        return CGRect(origin: origin, size: size)
    }

    /// The window was moved by something other than us — a title-bar drag — so the
    /// last frame we asked for says nothing about where it is. Without this, the
    /// snap-back after a drop was skipped as "already there" (measured: 11 pt off).
    public func forgetRequestedFrame() { lastRequested = nil }

    public func setFrame(_ rect: CGRect) {
        // Sub-pixel churn isn't worth a round-trip into the target app.
        if let last = lastRequested, last.isNearly(rect) { return }
        lastRequested = rect

        // Held for the duration of the writes below; restored on deinit.
        let suppression = EnhancedUserInterfaceSuppression(pid: pid)
        defer { withExtendedLifetime(suppression) {} }

        // Order matters. Setting size first lets a window that is growing claim the
        // space before it moves; the second size write fixes up apps that clamped
        // against their old position. Two writes is the price of AX not having an
        // atomic setFrame.
        element.set(kAXSizeAttribute, rect.size)
        element.set(kAXPositionAttribute, rect.origin)
        element.set(kAXSizeAttribute, rect.size)
    }

    public func focus() {
        element.set(kAXMainAttribute, true)
        element.perform(kAXRaiseAction)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// The id the WindowServer knows this window by — the same number that
    /// appears in `CGWindowListCopyWindowInfo`, which is how stacking is read.
    public var windowID: CGWindowID { CGWindowID(truncatingIfNeeded: id.raw) }

    /// Move the window into a bottom corner, where the WindowServer clamps it so
    /// that only a ~40x52pt sliver remains on screen — see `ParkingCover` for how
    /// that sliver is hidden. Position only: the size is left alone so coming back
    /// is a single write with no relayout inside the app.
    ///
    /// Measured at 1-6ms per window with no animation of any kind, which is the
    /// whole reason workspaces are done this way. Returns where it actually landed,
    /// so the cover can be sized to what is really visible.
    @discardableResult
    public func park(_ corner: ParkCorner) -> CGRect {
        let suppression = EnhancedUserInterfaceSuppression(pid: pid)
        defer { withExtendedLifetime(suppression) {} }
        element.set(kAXPositionAttribute, corner.target)
        // The next setFrame must go through even if it names the tile this window
        // already had, or it would stay parked while believing it was placed.
        lastRequested = nil
        return frame
    }

    /// Bring to the front *of its own application*. Never activates the app, so
    /// it cannot steal the keyboard — measured, since that is the whole reason it
    /// is safe to use for stacking a tile above its app's parked windows.
    public func raise() { element.perform(kAXRaiseAction) }

    /// Everything readable in the window, top to bottom, one node per line.
    ///
    /// Walks the accessibility tree collecting the value, title or description of
    /// every text-bearing element. Measured: a terminal hands over its visible grid
    /// as a single text node (~3K chars in 22ms); a browser page is a few hundred
    /// nodes (~19K chars in 45ms). Capped so a pathological page cannot stall the
    /// caller — the cap is on nodes visited as well as characters kept.
    /// The words in a window.
    ///
    /// Electron and Chromium apps — Discord, Slack, Chrome, VS Code, Notion, the
    /// ChatGPT and Claude desktop apps — build no accessibility tree at all until
    /// something asks for one, so this walk returned nothing but the title for every
    /// one of them. Wisper then read that title out as the window's contents, or
    /// decided the window did not exist (QA, 31 August: "The text on your Discord
    /// window is: Friends - Discord"). Setting `AXManualAccessibility` on the
    /// application is the documented way to ask; the tree takes a moment to appear,
    /// so the walk is done again after it.
    public func readableText(limit: Int = 12_000) -> String {
        let first = walkText(limit: limit)
        guard first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return first }
        guard Self.askForAccessibilityTree(pid: pid) else { return first }
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.25)
            let again = walkText(limit: limit)
            if !again.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return again }
        }
        return first
    }

    /// Chromium watches this attribute and turns its accessibility on when it is
    /// set. Harmless on an app that ignores it. Done once per process.
    private static var asked: Set<pid_t> = []
    private static func askForAccessibilityTree(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        let enabled = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        // Some apps use the older switch instead.
        if !enabled { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        let firstTime = asked.insert(pid).inserted
        return enabled || firstTime
    }

    private func walkText(limit: Int) -> String {
        var out: [String] = []
        var kept = 0
        var visited = 0
        func collect(_ e: AXUIElement, depth: Int) {
            guard visited < 4000, depth < 40, kept < limit else { return }
            visited += 1
            let role: String = e.attribute(kAXRoleAttribute) ?? ""
            if Self.textRoles.contains(role) {
                let text: String? = (e.attribute(kAXValueAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (e.attribute(kAXTitleAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (e.attribute(kAXDescriptionAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(text)
                    kept += text.count
                }
            }
            let children: [AXUIElement] = e.attribute(kAXChildrenAttribute) ?? []
            for child in children { collect(child, depth: depth + 1) }
        }
        collect(element, depth: 0)
        let joined = out.joined(separator: "\n")
        return joined.count > limit ? String(joined.prefix(limit)) + "\n[…truncated]" : joined
    }

    private static let textRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXButton", "AXMenuItem", "AXCell",
        "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXComboBox",
    ]

    public func minimize() { element.set(kAXMinimizedAttribute, true) }
    public func restore() { element.set(kAXMinimizedAttribute, false) }
    public func close() { (element.attribute(kAXCloseButtonAttribute) as AXUIElement?)?.perform(kAXPressAction) }
}

/// Where a parked window goes. Both clamp to a 40pt-wide sliver at the bottom of
/// the screen; two spots exist so a sliver can be put under whichever tile is
/// stacked above it.
public enum ParkCorner: Sendable, Equatable, CaseIterable {
    case bottomRight, bottomLeft

    var target: CGPoint {
        switch self {
        case .bottomRight: return CGPoint(x: 25000, y: 25000)
        case .bottomLeft:  return CGPoint(x: -25000, y: 25000)
        }
    }

    public var opposite: ParkCorner { self == .bottomRight ? .bottomLeft : .bottomRight }
}

private extension CGRect {
    func isNearly(_ other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}
