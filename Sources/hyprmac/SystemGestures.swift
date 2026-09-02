import AppKit
import Foundation
import HyprCore

/// macOS's own trackpad gesture settings, read and written where System Settings
/// keeps them.
///
/// Two domains, because a Mac can have both a built-in trackpad and a Magic
/// Trackpad and they are configured separately — a user who fixes one and swipes
/// on the other would think nothing had happened. Written with `AnyHost`, which is
/// where System Settings itself puts these (there is no per-host copy on a machine
/// that has only ever used the pane).
enum SystemGestures {
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]
    private static let horizontalKey = "TrackpadThreeFingerHorizSwipeGesture"
    private static let verticalKey = "TrackpadThreeFingerVertSwipeGesture"

    private static func mode(_ key: String) -> Int? {
        // Whichever trackpad is set to three fingers is the one that will clash.
        var found: Int?
        for domain in domains {
            guard let value = CFPreferencesCopyValue(key as CFString, domain as CFString,
                                                     kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber
            else { continue }
            if GestureConflict.isThreeFinger(value.intValue) { return value.intValue }
            found = found ?? value.intValue
        }
        return found
    }

    /// How many desktops the busiest display has. Spaces of type 0 are desktops;
    /// a full-screen app gets a space of its own and is not what is meant here.
    static var desktopCount: Int {
        guard let config = CFPreferencesCopyValue("SpacesDisplayConfiguration" as CFString,
                                                  "com.apple.spaces" as CFString,
                                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any],
              let management = config["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]]
        else { return 1 }
        let counts = monitors.map { monitor -> Int in
            let spaces = (monitor["Spaces"] as? [[String: Any]]) ?? []
            return spaces.filter { ($0["type"] as? Int ?? 0) == 0 }.count
        }
        return max(counts.max() ?? 1, 1)
    }

    /// `usesVertical` says whether hyprmac is using the up-and-down swipe. When it
    /// is not — the default — Mission Control on three fingers up is not a clash at
    /// all, and there is no reason to mention it or to touch it.
    static func conflict(usesVertical: Bool) -> GestureConflict {
        GestureConflict(horizontal: GestureConflict.isThreeFinger(mode(horizontalKey)),
                        vertical: usesVertical && GestureConflict.isThreeFinger(mode(verticalKey)),
                        desktops: desktopCount,
                        pendingLogout: changedSinceLogin)
    }

    /// Whether the trackpad preferences have been written since this login session
    /// began. The Dock is restarted at login, so its launch date is when the session
    /// started; a preference file newer than that has not been read by anything.
    static var changedSinceLogin: Bool {
        // `NSRunningApplication.launchDate` is nil for the Dock: launchd starts it,
        // not LaunchServices, and only the latter fills that in. Measured — it read
        // nil while the process had plainly been up for five days, and the check
        // silently answered "nothing to report". The kernel knows.
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let session = startTime(of: dock.processIdentifier) else { return false }
        return domains.contains { domain in
            let path = NSHomeDirectory() + "/Library/Preferences/\(domain).plist"
            guard let written = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { return false }
            return written > session
        }
    }

    /// When a process actually started, from the kernel rather than LaunchServices.
    private static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }

    /// Log out, which is the only way to make the window server re-read them. macOS
    /// asks for confirmation itself, so this is a request, not an execution.
    static func logOut() {
        let script = "tell application \"System Events\" to log out"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    /// Hand the three-finger swipe to hyprmac. Only the three-finger modes are
    /// touched, and only where they are actually set to three fingers: a user who
    /// has already moved macOS to four fingers keeps that, and every other trackpad
    /// preference is left exactly as it was.
    /// What hyprmac turned off, so the uninstaller can turn it back on. Only keys
    /// hyprmac itself changed are listed: a user who had already set the gesture to
    /// four fingers, or turned it off by hand, gets their choice left alone.
    static let releasedKey = "releasedGestures"

    @discardableResult
    static func release(vertical alsoVertical: Bool) -> Bool {
        var changed = false
        var released = Set(UserDefaults.standard.stringArray(forKey: Self.releasedKey) ?? [])
        defer { UserDefaults.standard.set(Array(released).sorted(), forKey: Self.releasedKey) }
        let keys = alsoVertical ? [horizontalKey, verticalKey] : [horizontalKey]
        for domain in domains {
            for key in keys {
                let current = CFPreferencesCopyValue(key as CFString, domain as CFString,
                                                     kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber
                guard GestureConflict.isThreeFinger(current?.intValue) else { continue }
                CFPreferencesSetValue(key as CFString, NSNumber(value: 0), domain as CFString,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                released.insert(key)
                changed = true
            }
            CFPreferencesAppSynchronize(domain as CFString)
        }
        log("gestures: \(changed ? "took the sideways three-finger swipe from macOS\(alsoVertical ? " and Mission Control's" : ", leaving Mission Control alone")" : "macOS was not using the three-finger swipe")")
        return changed
    }
}
