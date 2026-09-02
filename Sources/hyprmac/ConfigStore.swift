import Foundation
import HyprCore

enum ConfigStore {
    /// `~/.config/wisp` — shared with the news reader, so hyprmac has one home.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wisp", isDirectory: true)
    }

    static var path: URL { directory.appendingPathComponent("hyprmac.conf") }
    /// The file from when the window manager was called hyprmac; moved on first launch.
    static var previousName: URL { directory.appendingPathComponent("wispos.conf") }

    /// Where the config lived under each previous name. Newest first, so a machine
    /// that went through both renames picks up the most recent state.
    private static var legacyHomes: [(directory: URL, config: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent(".config/hyprmac", isDirectory: true), "hyprmac.conf"),
            (home.appendingPathComponent(".config/mac-hyprland", isDirectory: true), "hyprland.conf"),
        ]
    }

    /// Move a pre-rename config across rather than silently writing a fresh default
    /// over the top of someone's edited binds, workspace names and session.
    private static func migrateIfNeeded() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: path.path) else { return }
        guard let legacy = legacyHomes.first(where: {
            manager.fileExists(atPath: $0.directory.appendingPathComponent($0.config).path)
        }) else { return }

        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? manager.moveItem(at: legacy.directory.appendingPathComponent(legacy.config), to: path)
        // The session and the workspace names live beside it and are just as much
        // the user's work.
        for name in ["session.json", "workspace-names.json"] {
            let from = legacy.directory.appendingPathComponent(name)
            let to = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: from.path), !manager.fileExists(atPath: to.path) {
                try? manager.moveItem(at: from, to: to)
            }
        }
        FileHandle.standardError.write(
            "hyprmac: migrated config from \(legacy.directory.path)\n".data(using: .utf8)!)
    }

    /// Reads the config, writing the default out first if the user has none.
    static func load() -> (Config, [ConfigParser.Diagnostic]) {
        migrateIfNeeded()
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: previousName.path) {
                try? FileManager.default.moveItem(at: previousName, to: path)
                FileHandle.standardError.write("hyprmac: renamed wispos.conf to hyprmac.conf\n".data(using: .utf8)!)
            } else {
                try? defaultConfig.write(to: path, atomically: true, encoding: .utf8)
            }
        }
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            return (ConfigParser.parse(defaultConfig).config, [])
        }
        return ConfigParser.parse(source)
    }

    /// ALT is the default modifier rather than SUPER. macOS reserves most of Cmd
    /// for applications — Cmd+Q, Cmd+W, Cmd+1 all mean something already — so
    /// binding a tiling WM to it fights the system. Change `$mod` if you disagree.
    static let defaultConfig = """
    # hyprmac configuration
    # ~/.config/wisp/hyprmac.conf

    $mod = ALT

    general {
        # Breathing room. Windows sit apart from each other and off the screen edge,
        # the way a hand-arranged Mac desktop does.
        gaps_in = 12
        gaps_out = 16

        # Matches the corner radius macOS gives a real window.
        rounding = 12
        border_size = 1

        # `accent` follows the colour you picked in System Settings > Appearance.
        col.active_border = accent
    }

    canvas {
        enabled = true

        # `system` repaints your own desktop picture, so the background stays yours.
        # A colour (0xff11111b) or an image path also work.
        wallpaper = system

        # Darken the wallpaper so tiled windows read as the foreground. 0 to 1.
        dim = 0

        # Keep Finder's desktop icons visible by sitting below them.
        desktop_icons = true

        # A soft shadow under each tile, like the one macOS gives a window.
        slot_shadow = true

        # Workspace dots in the menu bar, and a brief overlay when you switch.
        menu_bar_indicator = true
        workspace_hud = true
    }

    workspaces {
        # Five workspaces, fixed. Every one has a key bound to it below.
        #
        # Name a workspace after the project living on it. Names show in the menu
        # bar and the switch overlay, and can be bound directly:
        #     bind = $mod, M, workspace, wisp
        # 1 = wisp
        # 2 = notes
    }

    animations {
        # Crossfade through the desktop when switching workspace. Respects the
        # system's Reduce Motion setting regardless.
        enabled = true
        duration = 250      # milliseconds, the whole switch
    }

    gestures {
        # Three-finger horizontal swipe changes workspace.
        #
        # macOS binds three- or four-finger horizontal swipes to "Swipe between
        # full-screen applications". If yours is still on three fingers, both it
        # and this will fire — hyprmac's first-run screen offers to take it, or
        # System Settings > Trackpad > More Gestures sets it to four fingers.
        enabled = true
        fingers = 3

        # How far the fingers travel before it counts, as a fraction of the
        # trackpad. Lower is more sensitive: 0.06 is about macOS's own feel,
        # 0.12 wants a deliberate sweep.
        threshold = 0.06

        # Three fingers up or down opens the overview: every workspace, and every
        # window in it as its app's icon, click one to go to it. Either direction
        # toggles it. macOS binds three fingers up to Mission Control, which cannot
        # see parked windows — hyprmac's first-run screen offers to take the gesture.
        # Set false to leave the vertical swipe to macOS; ALT+` opens it either way.
        overview = true

        # true: workspaces move with your fingers (swipe right, go right).
        # false: inverted, the way macOS Spaces reads it.
        natural = true
    }

    # Windows that should never be tiled.
    windowrule {
        float = com.apple.systempreferences
        float = com.apple.ActivityMonitor
        float = com.apple.finder
    }

    # --- agents ------------------------------------------------------------------
    # Windows you can talk to by name. The message is percent-encoded and appended to
    # the URL, so any app registering a scheme works — nothing here is Wisper-specific.
    agent {
        wisper = wisper://ask?q=
    }

    # --- launching -------------------------------------------------------------
    # `open -a` only focuses an app that is already running; -n asks for a new
    # window. Add -g to spawn it without stealing focus.
    # Apps the window manager leaves alone entirely (Wisper is, by default: she is an
    # overlay, not a tile), and apps that should float rather than tile:
    #     windowrule {
    #         ignore = com.example.some-overlay
    #         float  = com.apple.systempreferences
    #     }

    bind = $mod, Return, terminal
    bind = $mod, B, exec, open -a Safari

    # Everything below hangs off $mod: $mod to focus, $mod+SHIFT to move,
    # $mod+CTRL to resize. One super key, the way a hyprland config reads.

    # --- focus -----------------------------------------------------------------
    # Vim keys, and arrow keys — both under the same $mod.
    bind = $mod, H, movefocus, l
    bind = $mod, J, movefocus, d
    bind = $mod, K, movefocus, u
    bind = $mod, L, movefocus, r

    bind = $mod, left,  movefocus, l
    bind = $mod, down,  movefocus, d
    bind = $mod, up,    movefocus, u
    bind = $mod, right, movefocus, r

    bind = $mod, Tab, cyclenext

    # --- move ------------------------------------------------------------------
    bind = $mod SHIFT, H, movewindow, l
    bind = $mod SHIFT, J, movewindow, d
    bind = $mod SHIFT, K, movewindow, u
    bind = $mod SHIFT, L, movewindow, r

    bind = $mod SHIFT, left,  movewindow, l
    bind = $mod SHIFT, down,  movewindow, d
    bind = $mod SHIFT, up,    movewindow, u
    bind = $mod SHIFT, right, movewindow, r

    # --- resize ----------------------------------------------------------------
    # Swap trades places with the neighbour; move relocates the window beside it.
    bind = $mod CTRL SHIFT, H, swapwindow, l
    bind = $mod CTRL SHIFT, J, swapwindow, d
    bind = $mod CTRL SHIFT, K, swapwindow, u
    bind = $mod CTRL SHIFT, L, swapwindow, r

    # --- resize ----------------------------------------------------------------
    bind = $mod CTRL, H, resizeactive, -60 0
    bind = $mod CTRL, L, resizeactive, 60 0
    bind = $mod CTRL, K, resizeactive, 0 -60
    bind = $mod CTRL, J, resizeactive, 0 60

    # --- window ----------------------------------------------------------------
    # Ask an agent. Type "wisper why is my disk full" and it is routed to the agent
    # named on the front; the same grammar the voice control uses, typed instead of
    # spoken. Agents are registered in the `agent` block below.
    bind = $mod, P, askagent
    # Bring her up, or send her away: ALT+space. Talk to her: tap CMD twice. A
    # window-manager command in what you said is done here without waiting on the model.
    bind = $mod, space, exec, open -g wisper://show
    doubletap = CTRL, exec, open -g wisper://listen

    bind = $mod, Q, killactive
    bind = $mod, V, togglefloating
    bind = $mod, F, fullscreen
    bind = $mod, S, togglesplit

    # --- workspaces ------------------------------------------------------------
    bind = $mod, 1, workspace, 1
    bind = $mod, 2, workspace, 2
    bind = $mod, 3, workspace, 3
    bind = $mod, 4, workspace, 4
    bind = $mod, 5, workspace, 5

    # Step through workspaces; the three-finger swipe does the same thing.
    bind = $mod, bracketright, workspace, +1
    bind = $mod, bracketleft,  workspace, -1

    # Reorder: take this workspace, its windows and its name along with it.
    bind = $mod SHIFT, bracketright, moveworkspace, +1
    bind = $mod SHIFT, bracketleft,  moveworkspace, -1

    bind = $mod SHIFT, 1, movetoworkspace, 1
    bind = $mod SHIFT, 2, movetoworkspace, 2
    bind = $mod SHIFT, 3, movetoworkspace, 3
    bind = $mod SHIFT, 4, movetoworkspace, 4
    bind = $mod SHIFT, 5, movetoworkspace, 5

    # --- session ---------------------------------------------------------------
    bind = $mod, R, renameworkspace
    # Every workspace at once. Three-finger swipe down does the same.
    bind = $mod, grave, overview
    bind = $mod, slash, cheatsheet
    bind = $mod SHIFT, C, reload
    bind = $mod SHIFT, Q, exit

    """
}
