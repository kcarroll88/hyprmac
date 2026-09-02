import Foundation

/// A remembered window and the workspace it belongs on.
public struct WindowIdentity: Codable, Equatable, Sendable {
    /// The OS window id. Stable while the owning application keeps running, which
    /// covers restarting the window manager but not restarting the app.
    public let id: UInt64
    public let bundleID: String?
    public let title: String
    public let workspace: Int

    public init(id: UInt64, bundleID: String?, title: String, workspace: Int) {
        self.id = id
        self.bundleID = bundleID
        self.title = title
        self.workspace = workspace
    }
}

/// Puts windows back where they were after a restart.
///
/// Identity degrades in three steps, strongest first, because no single signal
/// survives everything:
///
///   1. **Window id** — exact, and correct whenever the app kept running.
///   2. **Bundle and title** — survives an app restart, as long as the title is
///      the same. Terminals and editors usually keep theirs; browsers do not.
///   3. **Bundle alone** — the third Ghostty window goes wherever the third
///      Ghostty window went last time.
///
/// Each remembered window is claimed at most once, so two windows of the same app
/// cannot both land on the same remembered workspace by accident.
public enum SessionMatcher {
    /// Claim the best record for a window, removing it from the pool.
    /// Returns nil when nothing matches and the caller should use its default.
    public static func claim(id: UInt64, bundleID: String?, title: String,
                             from pool: inout [WindowIdentity]) -> Int? {
        if let exact = pool.firstIndex(where: { $0.id == id }) {
            return pool.remove(at: exact).workspace
        }
        // Only match on title when there is a bundle to pair it with: two apps
        // can easily share a window title ("Untitled").
        if let bundleID, !title.isEmpty,
           let titled = pool.firstIndex(where: { $0.bundleID == bundleID && $0.title == title }) {
            return pool.remove(at: titled).workspace
        }
        if let bundleID,
           let sameApp = pool.firstIndex(where: { $0.bundleID == bundleID }) {
            return pool.remove(at: sameApp).workspace
        }
        return nil
    }

    /// Drop the records of apps that have kept running since the session was
    /// saved — the ones a window matched by exact id, which only survives while the
    /// app does. Such an app's real windows were all found in the first sweep, so
    /// what is left of it is windows that closed; left in the pool, a record like
    /// that claims the app's next new window by title, or by app alone, and sends
    /// it off to the workspace it was closed on. An app not running at launch —
    /// starting at login, back after an afternoon — matches nothing by id and
    /// keeps its records for the launch grace. Returns how many were dropped.
    @discardableResult
    public static func dropRecords(ofApps bundles: Set<String>, from pool: inout [WindowIdentity]) -> Int {
        let before = pool.count
        pool.removeAll { $0.bundleID.map(bundles.contains) ?? false }
        return before - pool.count
    }
}

/// The shape of one workspace: which window sits where.
///
/// Remembering only which workspace a window lives on was not enough — the
/// dwindle tree got rebuilt in whatever order the Accessibility API happened to
/// enumerate windows, so a workspace arranged with care came back rearranged
/// every restart.
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public var root: Tile?
    /// Floating windows and their rects, keyed by raw window id.
    public var floating: [UInt64: CGRect]

    public init(root: Tile?, floating: [UInt64: CGRect] = [:]) {
        self.root = root
        self.floating = floating
    }
}

/// Everything worth restoring about a session.
public struct SessionState: Codable, Equatable, Sendable {
    public var windows: [WindowIdentity]
    public var activeWorkspace: Int
    public var layouts: [Int: WorkspaceLayout]

    public init(windows: [WindowIdentity] = [], activeWorkspace: Int = 1,
                layouts: [Int: WorkspaceLayout] = [:]) {
        self.windows = windows
        self.activeWorkspace = activeWorkspace
        self.layouts = layouts
    }

    private enum CodingKeys: String, CodingKey { case windows, activeWorkspace, layouts }

    /// Tolerates a session written before layouts existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windows = try c.decodeIfPresent([WindowIdentity].self, forKey: .windows) ?? []
        activeWorkspace = try c.decodeIfPresent(Int.self, forKey: .activeWorkspace) ?? 1
        layouts = try c.decodeIfPresent([Int: WorkspaceLayout].self, forKey: .layouts) ?? [:]
    }
}

public extension Tile {
    /// The best tree to rebuild from, out of whatever survived: the one that
    /// contains the returning window and overlaps most with the windows present.
    ///
    /// At sleep the desktop tears down one window at a time, so the records hold
    /// trees of every size — the first-removed window's has everything, the
    /// last-removed one is a single leaf. Restoring each window from its own
    /// record let a late arrival's one-leaf tree wipe the arrangement already
    /// rebuilt: `3013 | 7598` woke up as `7598 | 3013`. Pick by evidence, not
    /// by ownership.
    static func richest(of candidates: [Tile?], containing id: SurfaceID, present: Set<SurfaceID>) -> Tile? {
        candidates.compactMap { $0 }.filter { $0.contains(id) }
            .max { Set($0.surfaces).intersection(present).count < Set($1.surfaces).intersection(present).count }
    }
}
