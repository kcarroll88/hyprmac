import CoreGraphics

/// What each window has proved it cannot shrink below.
///
/// Accessibility has no minimum-size attribute to ask for, and `AXSurface.setFrame`
/// is a request an app may decline: Electron and Catalyst windows keep a floor of
/// their own — measured on this machine, Discord 800×500, ChatGPT 480×600, Claude
/// 600×400. hyprmac used to write the frame and believe it, so once a tile fell
/// below one of those floors the window sat over its neighbours while the layout
/// said everything was fine. There is nothing to query, so the only way to know is
/// to ask and then look: `note` records what came back, and any window that keeps
/// more than it was given has told us its floor on that axis.
public struct MinimumSizes: Sendable, Equatable {
    private var learned: [SurfaceID: CGSize] = [:]
    /// Points of slack before a difference counts. Apps round to their own grid —
    /// a terminal to whole character cells — and that is not a refusal.
    public static let slack: CGFloat = 4

    public init() {}

    /// Record what a window became after being asked for `asked`. Returns true when
    /// it kept more than it was given, which is the window saying it cannot fit.
    @discardableResult
    public mutating func note(_ id: SurfaceID, asked: CGSize, got: CGSize) -> Bool {
        let refusedWidth  = got.width  > asked.width  + Self.slack
        let refusedHeight = got.height > asked.height + Self.slack
        guard refusedWidth || refusedHeight else { return false }
        // Only the axis it refused on says anything. A window given a tile too
        // narrow may be exactly as tall as asked, and claiming that height as a
        // floor would keep it floating forever.
        var floor = learned[id] ?? .zero
        if refusedWidth  { floor.width  = max(floor.width,  got.width) }
        if refusedHeight { floor.height = max(floor.height, got.height) }
        learned[id] = floor
        return true
    }

    /// Whether a window is known not to fit a tile of this size. Unknown windows
    /// fit: nothing has been measured, so nothing is assumed.
    public func fits(_ id: SurfaceID, in size: CGSize) -> Bool {
        guard let floor = learned[id] else { return true }
        return floor.width <= size.width + Self.slack && floor.height <= size.height + Self.slack
    }

    public func minimum(for id: SurfaceID) -> CGSize? { learned[id] }
    public mutating func forget(_ id: SurfaceID) { learned[id] = nil }
    public var count: Int { learned.count }
}
