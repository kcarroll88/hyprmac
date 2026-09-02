import AppKit
import CoreGraphics

/// One physical screen, in the WM's global AX coordinate space.
public struct Display: Identifiable, Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    /// Full bounds, AX coordinates.
    public let frame: CGRect
    /// Bounds minus menu bar and Dock — the area we actually tile into.
    public let visibleFrame: CGRect
    public let isPrimary: Bool
}

/// AppKit puts the origin at the bottom-left of the primary screen and grows y
/// upward. The Accessibility API puts it at the top-left and grows y downward.
/// Every rect in this project is AX-space; conversion happens only here.
public enum Displays {
    /// The y coordinate AppKit considers the top of the primary screen. Flipping
    /// pivots around this.
    public static var flipHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    public static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: flipHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func toCocoa(_ rect: CGRect) -> CGRect {
        // The flip is its own inverse.
        CGRect(x: rect.minX, y: flipHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func all() -> [Display] {
        let screens = NSScreen.screens
        return screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
            return Display(
                id: CGDirectDisplayID(number?.uint32Value ?? UInt32(index)),
                name: screen.localizedName,
                frame: toAX(screen.frame),
                visibleFrame: toAX(screen.visibleFrame),
                isPrimary: index == 0
            )
        }
    }

    /// The display a rect mostly sits on, by intersection area. Falls back to the
    /// primary so a window dragged off-screen still lands somewhere sane.
    public static func containing(_ rect: CGRect) -> Display? {
        let displays = all()
        return displays.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        } ?? displays.first
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : width * height }
}
