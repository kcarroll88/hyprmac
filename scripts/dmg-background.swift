#!/usr/bin/env swift
// Draws the backdrop for the disk image: scripts/dmg-background.swift <out.png>
//
// 640×420, the size make-dmg.sh gives the Finder window. The two icons sit at
// x=160 and x=480, y=210 from the top, so everything here is placed around them.
// Drawn rather than shipped as a binary asset: it is twenty lines of gradient and
// an arrow, and this way the wording can change without opening an image editor.
import AppKit
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png")
let size = CGSize(width: 640, height: 420)

guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// A quiet vertical gradient. Dark, because the icons are bright and a disk image
// window has no dark-mode variant to switch to.
let top = CGColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1)
let bottom = CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
}

// A soft glow behind the app icon, so the eye starts on the left.
context.saveGState()
if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [CGColor(red: 0.35, green: 0.45, blue: 0.75, alpha: 0.30),
                                  CGColor(red: 0.35, green: 0.45, blue: 0.75, alpha: 0)] as CFArray,
                         locations: [0, 1]) {
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 160, y: 210), startRadius: 0,
                               endCenter: CGPoint(x: 160, y: 210), endRadius: 190, options: [])
}
context.restoreGState()

// The arrow between the icons: a thick shaft and a solid head, no hairlines.
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
let shaft = CGRect(x: 268, y: 204, width: 78, height: 12)
context.fill(CGRect(x: shaft.minX, y: shaft.minY, width: shaft.width, height: shaft.height))
context.beginPath()
context.move(to: CGPoint(x: 346, y: 232))
context.addLine(to: CGPoint(x: 392, y: 210))
context.addLine(to: CGPoint(x: 346, y: 188))
context.closePath()
context.fillPath()

func draw(_ text: String, at point: CGPoint, size fontSize: CGFloat, weight: NSFont.Weight,
          alpha: CGFloat, centred: Bool = false, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: NSColor(white: 1, alpha: alpha),
        .kern: tracking,
    ]
    let line = NSAttributedString(string: text, attributes: attributes)
    let bounds = line.size()
    let origin = CGPoint(x: centred ? point.x - bounds.width / 2 : point.x, y: point.y)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    line.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()
}

draw("hyprmac", at: CGPoint(x: 320, y: 352), size: 30, weight: .semibold, alpha: 0.95, centred: true)
draw("A TILING WINDOW MANAGER FOR macOS", at: CGPoint(x: 320, y: 330), size: 10, weight: .medium, alpha: 0.45, centred: true, tracking: 2.2)
draw("Drag it into Applications", at: CGPoint(x: 320, y: 92), size: 15, weight: .regular, alpha: 0.72, centred: true)
draw("Then open it and allow Accessibility when asked", at: CGPoint(x: 320, y: 66), size: 11, weight: .regular, alpha: 0.38, centred: true)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
