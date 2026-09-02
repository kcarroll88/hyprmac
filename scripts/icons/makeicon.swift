import AppKit
// makeicon hyprmac <out.png> | wisper <portrait.png> <out.png>   — 1024×1024 app icons in the projects' own vocabulary
let args = Array(CommandLine.arguments.dropFirst())
let size: CGFloat = 1024
func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a) }
let base = color(0x1e1e2e), crust = color(0x11111b), blue = color(0x89b4fa), text = color(0xcdd6f4), overlay = color(0x6c7086)
func render(_ draw: () -> Void, to path: String) {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .high; draw(); img.unlockFocus()
    let tiff = img.tiffRepresentation!; let rep = NSBitmapImageRep(data: tiff)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
// macOS icons: a rounded square that fills ~80% of the canvas, transparent margin, subtle top light.
let plate = CGRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
let radius = plate.width * 0.225
func drawPlate() {
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -14)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); base.setFill(); rounded(plate, radius).fill(); NSGraphicsContext.restoreGraphicsState()
    let g = NSGradient(colors: [NSColor.white.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0.0)])!
    NSGraphicsContext.saveGraphicsState(); rounded(plate, radius).addClip(); g.draw(in: plate, angle: -90); NSGraphicsContext.restoreGraphicsState()
    crust.withAlphaComponent(0.9).setStroke(); let edge = rounded(plate.insetBy(dx: 2, dy: 2), radius - 2); edge.lineWidth = 4; edge.stroke()
}
if args.first == "hyprmac", args.count == 2 {
    render({
        drawPlate()
        // The dwindle glyph from the build log, drawn to scale: one tall tile, two stacked, the first one active.
        let inset = plate.insetBy(dx: plate.width * 0.17, dy: plate.height * 0.19)
        let gap = inset.width * 0.06, r = inset.width * 0.06
        let left = CGRect(x: inset.minX, y: inset.minY, width: inset.width * 0.5 - gap / 2, height: inset.height)
        let rx = inset.minX + inset.width * 0.5 + gap / 2, rw = inset.width * 0.5 - gap / 2
        let top = CGRect(x: rx, y: inset.midY + gap / 2, width: rw, height: inset.height * 0.5 - gap / 2)
        let bottom = CGRect(x: rx, y: inset.minY, width: rw, height: inset.height * 0.5 - gap / 2)
        for (rect, on) in [(left, true), (top, false), (bottom, false)] {
            let p = rounded(rect, r); p.lineWidth = 14
            if on { blue.withAlphaComponent(0.22).setFill(); p.fill(); blue.setStroke() } else { overlay.setStroke() }
            p.stroke()
        }
    }, to: args[1])
} else if args.first == "wisper", args.count == 3, let portrait = NSImage(contentsOfFile: args[1]) {
    render({
        drawPlate()
        // Her portrait, full bleed inside the plate, with a thin accent ring and a soft vignette at the bottom.
        let clip = rounded(plate.insetBy(dx: 10, dy: 10), radius - 8)
        NSGraphicsContext.saveGraphicsState(); clip.addClip()
        let ps = portrait.size; let scale = max(plate.width / ps.width, plate.height / ps.height) * 1.08
        let w = ps.width * scale, h = ps.height * scale
        let dest = CGRect(x: plate.midX - w / 2, y: plate.midY - h / 2 + plate.height * 0.02, width: w, height: h)
        portrait.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
        let fade = NSGradient(colors: [base.withAlphaComponent(0.0), base.withAlphaComponent(0.55)])!
        fade.draw(in: CGRect(x: plate.minX, y: plate.minY, width: plate.width, height: plate.height * 0.35), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        blue.withAlphaComponent(0.9).setStroke(); let ring = rounded(plate.insetBy(dx: 10, dy: 10), radius - 8); ring.lineWidth = 8; ring.stroke()
    }, to: args[2])
} else { print("usage: makeicon hyprmac out.png | wisper portrait.png out.png"); exit(2) }
