import AppKit
import HyprCore

/// Supplies the image the canvas paints behind the tiles.
///
/// The default is whatever macOS is already showing, read per display via
/// `NSWorkspace.desktopImageURL(for:)`. That is the single biggest thing keeping
/// this from looking like a Linux desktop bolted onto a Mac: the background stays
/// the user's own.
enum Wallpaper {
    nonisolated(unsafe) private static var cache: [URL: NSImage] = [:]

    static func image(for screen: NSScreen, source: WallpaperSource) -> NSImage? {
        switch source {
        case .color:
            return nil
        case .file(let path):
            return load(URL(fileURLWithPath: path))
        case .system:
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
            return load(url)
        }
    }

    /// Forget cached images so a wallpaper change is picked up on the next redraw.
    static func invalidate() { cache.removeAll() }

    private static func load(_ url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url] = image
        return image
    }

    /// The rect to draw `size` into so it covers `bounds` without distortion —
    /// the same "Fill Screen" behaviour macOS uses for desktop pictures.
    static func aspectFillRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - scaled.width / 2,
                      y: bounds.midY - scaled.height / 2,
                      width: scaled.width, height: scaled.height)
    }
}
