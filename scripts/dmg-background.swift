#!/usr/bin/env swift
// Draws the backdrop for the disk image.
//
//   scripts/dmg-background.swift <out.png> [--name hyprmac] [--tagline "…"] [--note "…"]
//                                          [--accent 0.49,0.64,0.96] [--scale 2]
//
// 640×420 points, the size make-dmg.sh gives the Finder window, rendered at 2× and
// stamped 144 DPI so it is not soft on a retina screen — the old one was 640×420 at
// 72 and looked it. The two icons sit at x=160 and x=480, y=210, so everything here
// is placed around them.
//
// The design is the app's own: hyprmac's icon is a dwindle layout — one focused pane
// outlined in periwinkle beside two quiet ones, on near-black. So the backdrop is
// that same layout at window scale, and the drag becomes what the app itself does,
// which is move a window into the slot beside it. Drawn rather than shipped as an
// asset: the wording and the colour are arguments, so Wisper's image comes out of
// the same twenty lines.
import AppKit
import UniformTypeIdentifiers

var arguments = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String, _ fallback: String) -> String {
    guard let i = arguments.firstIndex(of: "--" + name), i + 1 < arguments.count else { return fallback }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}
let name = flag("name", "hyprmac")
let tagline = flag("tagline", "A TILING WINDOW MANAGER FOR macOS")
let note = flag("note", "Then open it and allow Accessibility when asked")
let accentText = flag("accent", "0.49,0.64,0.96")
let scale = CGFloat(Double(flag("scale", "2")) ?? 2)
let out = URL(fileURLWithPath: arguments.first ?? "background.png")

let points = CGSize(width: 640, height: 420)
let pixels = CGSize(width: points.width * scale, height: points.height * scale)
let accentParts = accentText.split(separator: ",").compactMap { Double($0) }
let accent = accentParts.count == 3
    ? CGColor(red: accentParts[0], green: accentParts[1], blue: accentParts[2], alpha: 1)
    : CGColor(red: 0.49, green: 0.64, blue: 0.96, alpha: 1)

guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.scaleBy(x: scale, y: scale)
context.setAllowsAntialiasing(true)

func rgba(_ c: CGColor, _ alpha: CGFloat) -> CGColor { c.copy(alpha: alpha) ?? c }
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// The ground: the icon's own near-black, a touch lighter at the top left so the
// window has a direction to it.
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [CGColor(red: 0.11, green: 0.115, blue: 0.135, alpha: 1),
                                      CGColor(red: 0.055, green: 0.058, blue: 0.072, alpha: 1)] as CFArray,
                             locations: [0, 1]) {
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: points.height),
                               end: CGPoint(x: points.width, y: 0), options: [])
}

/// The two slots the icons sit in. The left one is focused — the app, about to be
/// moved — and the right one is where it goes.
func slot(centre: CGPoint, focused: Bool) {
    let side: CGFloat = 180
    let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    let path = CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil)

    if focused {
        // The focused pane in the icon is filled a shade above the ground and lit
        // from inside; the glow is what draws the eye to the thing you drag.
        context.saveGState()
        context.addPath(path); context.clip()
        if let inner = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [rgba(accent, 0.16), rgba(accent, 0.02)] as CFArray,
                                  locations: [0, 1]) {
            context.drawRadialGradient(inner, startCenter: CGPoint(x: centre.x, y: centre.y + 30), startRadius: 0,
                                       endCenter: centre, endRadius: 170, options: [])
        }
        context.restoreGState()
        context.saveGState()
        context.setShadow(offset: .zero, blur: 22, color: rgba(accent, 0.28))
        context.setStrokeColor(rgba(accent, 0.62))
        context.setLineWidth(1.6)
        context.addPath(path); context.strokePath()
        context.restoreGState()
    } else {
        context.saveGState()
        context.setStrokeColor(rgba(white, 0.13))
        context.setLineWidth(1.2)
        context.setLineDash(phase: 0, lengths: [5, 6])
        context.addPath(path); context.strokePath()
        context.restoreGState()
    }
}
slot(centre: CGPoint(x: 160, y: 214), focused: true)
slot(centre: CGPoint(x: 480, y: 214), focused: false)

// The move: a thin shaft and an open chevron, not a clip-art block arrow.
context.saveGState()
context.setStrokeColor(rgba(accent, 0.55))
context.setLineWidth(2)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 292, y: 222)); context.addLine(to: CGPoint(x: 344, y: 222))
context.strokePath()
context.move(to: CGPoint(x: 336, y: 213))
context.addLine(to: CGPoint(x: 345, y: 222))
context.addLine(to: CGPoint(x: 336, y: 231))
context.strokePath()
context.restoreGState()

func draw(_ text: String, at point: CGPoint, size fontSize: CGFloat, weight: NSFont.Weight,
          alpha: CGFloat, centred: Bool = false, tracking: CGFloat = 0, colour: CGColor? = nil) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: NSColor(cgColor: rgba(colour ?? white, alpha)) ?? .white,
        .kern: tracking,
    ]
    let line = NSAttributedString(string: text, attributes: attributes)
    let origin = CGPoint(x: centred ? point.x - line.size().width / 2 : point.x, y: point.y)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    line.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()
}

draw(name, at: CGPoint(x: 320, y: 356), size: 27, weight: .semibold, alpha: 0.96, centred: true, tracking: -0.4)
draw(tagline, at: CGPoint(x: 320, y: 336), size: 9.5, weight: .medium, alpha: 0.40, centred: true, tracking: 2.4)

// Close under the slots, where the hand is, rather than stranded at the bottom.
draw("Drag it into Applications", at: CGPoint(x: 320, y: 78), size: 14, weight: .medium, alpha: 0.80, centred: true)
draw(note, at: CGPoint(x: 320, y: 56), size: 10.5, weight: .regular, alpha: 0.36, centred: true)

// A vignette, so the corners sit back and the middle carries the window.
context.saveGState()
if let edge = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0),
                                  CGColor(red: 0, green: 0, blue: 0, alpha: 0.38)] as CFArray,
                         locations: [0.55, 1]) {
    context.drawRadialGradient(edge, startCenter: CGPoint(x: 320, y: 210), startRadius: 120,
                               endCenter: CGPoint(x: 320, y: 210), endRadius: 460, options: [])
}
context.restoreGState()

// 144 DPI on a 2× canvas: Finder lays it out at 640×420 points and shows every
// pixel of it on a retina display.
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
let dpi = 72 * Double(scale)
CGImageDestinationAddImage(destination, image, [
    kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
    kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGXPixelsPerMeter: Int(dpi / 0.0254),
                                    kCGImagePropertyPNGYPixelsPerMeter: Int(dpi / 0.0254)],
] as CFDictionary)
CGImageDestinationFinalize(destination)
