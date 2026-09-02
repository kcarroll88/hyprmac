#!/usr/bin/env swift
// scripts/window-census.swift [app name] — every window the window server knows about
// for an app, next to what hyprmac thinks. The two disagreeing is the whole question
// when a window "closes" but comes back: an app that hides a window rather than
// destroying it leaves hyprmac managing something the user believes is gone, and the
// next relayout writes its frame, which puts it back on screen.
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.dropFirst().first
for onScreenOnly in [true, false] {
    let options: CGWindowListOption = onScreenOnly
        ? [.optionOnScreenOnly, .excludeDesktopElements]
        : [.optionAll, .excludeDesktopElements]
    let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let rows = list.filter { info in
        guard let owner = info[kCGWindowOwnerName as String] as? String else { return false }
        return wanted == nil || owner.localizedCaseInsensitiveContains(wanted!)
    }
    print(onScreenOnly ? "on screen:" : "all windows (including hidden):")
    if rows.isEmpty { print("  none") }
    for info in rows {
        let n = info[kCGWindowNumber as String] as? Int ?? -1
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        let name = info[kCGWindowName as String] as? String ?? ""
        let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        print(String(format: "  %-10s id=%-7d layer=%-3d %4.0fx%-4.0f @ %5.0f,%-5.0f  %@",
                     (owner as NSString).utf8String!, n, layer,
                     b["Width"] ?? 0, b["Height"] ?? 0, b["X"] ?? 0, b["Y"] ?? 0, name))
    }
}
