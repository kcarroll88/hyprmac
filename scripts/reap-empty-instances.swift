#!/usr/bin/env swift
// Quits instances of an app that hold no windows.
//
//   swift scripts/reap-empty-instances.swift Ghostty
//
// `open -na` launches a whole second copy of an app, and each one keeps its own
// Dock icon whether or not it ever shows a window. The new-window launcher no
// longer works that way, but this cleans up debris left by anything that does.
import ApplicationServices
import AppKit
// Quits instances of an app that hold no windows — the debris `open -na` leaves
// behind. Anything with a window is left strictly alone.
let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Ghostty"
var reaped = 0
for app in NSWorkspace.shared.runningApplications where app.localizedName == target {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var raw: CFTypeRef?
    AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &raw)
    let count = ((raw as? [AXUIElement]) ?? []).count
    guard count == 0 else {
        print("keeping pid \(app.processIdentifier) (\(count) window(s))")
        continue
    }
    app.terminate()
    reaped += 1
    print("quitting empty pid \(app.processIdentifier)")
}
print("reaped \(reaped)")
