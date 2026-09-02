# hyprmac

> **Names.** `hyprmac` is this window manager. **Wisp OS** is the package: hyprmac and [Wisper](../WisperMac) together — the two names the user chose on 30 August. Each installs alone (`install.sh --only hyprmac` / `--only wisper`); together they are Wisp OS. The bundle id is still `dev.keenancarroll.wispos` so the Accessibility grant survives the rename; it changes once, at release.

A tiling window manager for macOS, in the shape of [hyprland](https://hyprland.org):
dwindle layout, gaps, a `hyprland.conf` config, vim-style keybinds, and workspaces —
plus a canvas that paints the desktop underneath your windows, and
[Wisper](../WisperMac), a local model that can see the desktop and act on it.

Wisp OS started as a privacy-hardened Arch Linux distro. This is the same idea
rebuilt macOS-native: the window manager is the shell, Wisper is the brain.

Native Swift, no dependencies, **SIP stays on**.

## Status

v0. Tiling, config, keybinds, workspaces and the canvas work. See [Roadmap](#roadmap).

## Install (beta)

Download `hyprmac-<version>.dmg`, drag hyprmac into Applications, open it, and allow
Accessibility when it asks. No Terminal, no build, no downloads on first run — the
window manager is a 1 MB app that links nothing but the system frameworks, writes its
own config on first launch, and needs no part of this source tree at runtime. (That
was always true; the tarball below exists because *Wisper* needs a 9 GB model and a
build, and hyprmac was being carried along with it.)

**Closing the welcome window killed hyprmac.** Reported as "I closed the window
because it was in the way and it quit hyprmac altogether", and it was worse than a
quit: a crash, in `objc_release` inside an autorelease pool pop, with a report in
`~/Library/Logs/DiagnosticReports` to prove it. An `NSWindow` built in code defaults
to `isReleasedWhenClosed = true`, so AppKit released the window on close while ARC
released it too through the property holding it, and the second release landed on
freed memory. One line — `window.isReleasedWhenClosed = false` — and the window is
owned by exactly one thing again.

**One restart, never a loop.** Restarting on the grant assumes the new process can
see it. When it cannot, the assumption costs everything: grant seen, restart, not
seen, wait, grant seen — a Mac that relaunches hyprmac forever and never works, with
nothing on screen saying why. Reported from a work machine, and the worst failure this
project has produced, because it is unattended and self-inflicted. hyprmac now records
when it restarts itself and refuses to do it twice: the second untrusted start inside
ninety seconds stops and explains instead. The likeliest explanation is named outright
when it applies — an app opened from a disk image or Downloads is run by macOS from a
randomised read-only copy (App Translocation), somewhere new every launch, so no
permission can ever stick to it and the grant is given to a copy that will not exist
next time. `Bundle.main.bundleURL` says so plainly, and the screen then asks for the
one thing that fixes it: quit, drag it into Applications, open it from there.

**hyprmac no longer exits when Accessibility is missing.** It used to `exit(1)` before
the app object existed, with a message on a stderr nobody sees, which made the welcome
screen — the one thing that explains the permission — unreachable on precisely the
machine that needs it. A new user saw macOS's own prompt and nothing else, because
hyprmac had already gone. Now it runs, manages nothing, says what it is waiting for,
and polls; the moment the grant lands it restarts itself, because the grant only
reaches a newly launched process. Closing that window leaves it waiting rather than
stopping it, and there is a Quit button for saying no.

**The overview shows the windows, not a count of them.** It listed each workspace with
"3 windows", which tells you how full a workspace is and nothing about whether the
thing you are looking for is in it. Every window now appears as its application's
icon, with its title as a tooltip, and clicking one goes straight to it — workspace
and focus together. Icons rather than thumbnails deliberately: a live picture of a
window needs Screen Recording, and a window manager asking for that is a red flag
whatever its reason. This is the job Mission Control is usually put to, on the windows
Mission Control cannot do it for — parked windows sit in a screen corner, which is
exactly where it will not look. The three-finger swipe opens it either way up: which
direction means "show me everything" is not worth being right about, and a gesture
that works one way and silently does nothing the other reads as broken.

**Borrowing a system setting means being able to give it back.** Taking macOS's
three-finger swipe is the one change hyprmac makes outside its own files, and the
usual way to remove a Mac app — drag it to the Trash — runs nothing, so nothing gives
it back. The user is left with a trackpad gesture that quietly does nothing and no app
left to blame. There is no fixing that from inside a deleted bundle, so three things
make it survivable: hyprmac records exactly which keys it turned off, so
`scripts/uninstall.sh` restores those and only those; and the screen that borrows the
gesture says, in the same breath, that removing hyprmac later means turning it back on
in System Settings ▸ Trackpad ▸ More Gestures.

There is a faster way out than the logout, and the card offers it when it applies. A
sideways swipe changes desktop only when there is another desktop to change to: on a
Mac with one, macOS's copy of the gesture is invisible whatever the setting says —
which is why this was so easy to miss on the machine hyprmac is written on. So when
the clash is waiting on a logout and there is more than one desktop, the card also
says to close the others in Mission Control, because hyprmac's workspaces are what
those desktops were for and closing them works immediately. Measured on a machine
whose window server had been up since 27 August against preferences written on 1
September, with two desktops: the swipes were read correctly and acted on
(`gesture: swipe down — overview`, `swipe left`, `swipe right` in the journal, which
is why that line exists), and macOS switched desktops underneath anyway.

The offer itself had the same shape of bug, and it was found the same way: reinstall
after an uninstall, and the gesture card never appeared. Uninstalling hands the swipe
back to macOS, so the clash is real again — but "have I offered this?" was written as a
one-way flag, and hyprmac had already decided it asked once and would not ask again.
The user is left with a swipe that changes desktop, an app that knows why, and nothing
on screen to say so. Whether to offer is a question about the situation, not about the
lifetime of an install: the flag is cleared whenever the clash is absent, so a clash
that comes back is offered again, and `Setup…` in the menu bar opens the screen at any
time, for anyone who dismissed it and wants it back.

An `Uninstall hyprmac…` menu item did all of it — windows unparked, gesture returned,
login item dropped, app to the Trash — and was taken out again. It worked, but it can
only remove the copy that is running, and a machine with a copy in `/Applications` and
another in `build/` will have the wrong one disappear while the one you were looking
at stays put. For a menu item whose whole purpose is to leave nothing behind, "removed
something, possibly not the thing you meant" is worse than not offering it: turning the
gesture back on is one switch in System Settings, and that is what the screen says.

**The three-finger swipe, and macOS's claim on it.** hyprmac reads the trackpad
through MultitouchSupport, which *observes* fingers — it never consumes the event.
macOS's own handler lives in the WindowServer, upstream of anything an application
can intercept, so on a machine where the system gesture is still on, one swipe does
two things: hyprmac changes workspace while macOS changes desktop, and three fingers
up opens Mission Control as well as the overview. No amount of care inside hyprmac
can fix that; the only cure is for macOS to let the gesture go.

This is invisible on a Mac with a single desktop — the system swipe has nowhere to
go — which is exactly the machine hyprmac was written on, and exactly why it was
nearly shipped. The welcome screen now reads the real settings
(`TrackpadThreeFingerHorizSwipeGesture` and its vertical twin, in both the built-in
and Magic Trackpad domains, since a Mac can have one of each configured separately)
and the live desktop count, and only says anything when macOS is actually holding
the gesture. A setting can be off on disk and still running, and that state has to be shown or
the whole feature reads as broken. The window server reads the trackpad preferences
once, at login: measured here, a session begun on 27 August against preferences
written on 1 September — `0` in the file, still switching desktops on screen. hyprmac
compares the preference files' modification time against the Dock's start time (the
kernel's, via `sysctl`; `NSRunningApplication.launchDate` is nil for the Dock, since
launchd starts it and only LaunchServices fills that in — it read nil for a process
plainly five days old, and the check answered "nothing to report"). When the change
has not taken effect the card says *waiting for a logout* and offers to do it, rather
than reading the file, seeing the gesture already off, and concluding there is nothing
to offer — which is exactly the state a user is in immediately after using it.

One button hands it over: by default it clears only the *sideways*
three-finger swipe, because three fingers up is Mission Control — the way people find
a window on a Mac — and taking that away to duplicate it is a poor trade. So hyprmac
leaves the vertical swipe alone and does not use it (`gestures { overview = false }`;
`ALT+\`` opens the overview and always has). Set `overview = true` and the offer
covers both. It clears nothing else, leaves a user who has already moved macOS to
four fingers alone, and
says plainly that the window server reads the setting at login, so a swipe that still
misbehaves wants a logout. How far the fingers must travel is `gestures { threshold }`, a fraction of the
trackpad: the default is 0.06, which is about macOS's own feel, where 0.12 wanted a
deliberate sweep and read as unresponsive next to the system gesture. `GestureConflict`
decides the rest and is tested; the
value macOS stores is a mode rather than a flag — 2 means three fingers, 1 means four
— so "on" is not the same question as "in the way".

The first launch opens the one screen hyprmac has: what Accessibility is for, a
button that opens the right pane of System Settings, a switch for opening at login,
and the keys worth knowing. It notices the grant landing and offers the restart that
makes it take, because Accessibility observers are registered at startup. Until then
a tiling window manager can do nothing at all, and nothing in the app used to say so
— launched on a fresh Mac it came up, failed every call in silence, and looked broken.

```
scripts/make-dmg.sh              # → dist/hyprmac-<version>.dmg
scripts/make-dmg.sh --notarize   # same, submitted to Apple and stapled
```

The image is built, laid out and signed by that one script: the app on the left, an
Applications alias on the right, an arrow between them on a drawn backdrop
(`scripts/dmg-background.swift` — code rather than a binary asset, so the wording can
change without an image editor). It signs with a Developer ID if the Mac has one and
falls back to the local identity otherwise, so the image can always be built; only
notarizing is refused without one, since Apple would refuse it anyway. Notarizing
needs credentials stored once:

```
xcrun notarytool store-credentials hyprmac-notary \
      --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Without notarization macOS says the developer cannot be verified and the first launch
needs right-click ▸ Open — worth saying plainly on the download page rather than
letting people meet it cold.

`scripts/make-dmg.sh --check` answers the only question that matters before a
release — whether this Mac can put out a download that opens with a double-click —
and names which of the four pieces is missing:

```
==> notarization readiness
  ok    hardened runtime is on (Apple will not notarize without it)
  ok    notarytool is installed
  MISS  no 'Developer ID Application' certificate in this keychain
  MISS  no stored credentials named 'hyprmac-notary'
```

Three of the four are true before enrolment finishes; only the certificate has to be
waited for. When it arrives: make a **Developer ID Application** certificate (Xcode ▸
Settings ▸ Accounts ▸ Manage Certificates ▸ + ), make an app-specific password at
appleid.apple.com, `xcrun notarytool store-credentials`, then `--check` again and
`scripts/make-dmg.sh --notarize`.

One surprise to expect once, on your own Mac: a Developer ID signature is a different
signature, and the Accessibility grant is keyed to the signature, not the name. The
first Developer-ID-signed build is a stranger to System Settings, so hyprmac has to be
allowed again — once, and never again after that, since every later release carries
the same identity. That is also the reason a downloaded release keeps its grant across
updates where a locally rebuilt one does not.

One failure mode is worth naming, because it produced a download that worked
perfectly and looked like nobody had tried. Finder is told to style the disk *by
name*, and a volume of that name already mounted — the last release, still open in
someone's Downloads — takes the new image's place: `hdiutil` mounts the staging copy
as "hyprmac 0.1.0 1", the script styles the older volume, and the image ships with no
`.DS_Store` and therefore no background, no icon positions, nothing. The build says
"done" either way. Now any volume of that name is unmounted before the image is
created, the Finder script addresses the disk by the name it actually got rather than
the one asked for, and the layout is checked afterwards: an image that failed to style
says so loudly instead of being posted.

Two things in that script are written the way they are on purpose. `codesign` is not
given `--deep` — there is no nested code in the bundle and Apple discourages it — and
neither the readiness check nor the mount-point parse pipes into `grep -q` or `head`,
because those exit at the first match, the writer upstream takes `SIGPIPE`, and
`set -o pipefail` turns a successful match into a failed pipeline. The check reported
"hardened runtime is off" about a binary that had it on, which is a worse failure than
not checking at all.

## Putting Wisp OS on another Mac (alpha)

```
scripts/make-alpha.sh --personal      # → ~/Desktop/wisp-alpha-YYYYMMDD.tar.gz, ~20 MB
```

AirDrop that, unpack it, and in Terminal: `cd wisp-alpha && ./install.sh --check`, then
`./install.sh`. The installer is idempotent and asks nothing: it checks the machine
(Apple Silicon, macOS 14+, the Command Line Tools — it triggers their install if
missing — and Homebrew), installs the packages (llama.cpp, ffmpeg, uv, jq, w3m, qodem,
bat, node; the Ghostty, Claude Code and Codex casks), copies both source trees to
`~/mac-hyprland` and `~/WisperMac`, downloads the 9 GB model with resume (or
`--no-model` if you copied it), installs the personal config and Wisper's dossiers
without overwriting anything already there, makes the self-signed signing identity,
builds and signs both apps, prepares the speech environment, adds both apps to
Login Items, and launches them — then tells you which
permissions macOS will ask for. `--personal` in the packer carries your
`~/.config/wisp/*` (both configs, workspace names, the voice clip) and `~/Wisper/docs`.

Why a tarball and a script rather than a DMG: the apps use the source trees at
runtime (the news and dial scripts, the speech sidecar), the model is 9 GB and
public, and the Accessibility grant is keyed to a signing identity that has to be
made on the machine itself. Tested by unpacking the tarball elsewhere and building
both apps from it with the Command Line Tools toolchain only — no Xcode: 28 s and
signed for Wisp OS, Wisper likewise.

## Drag a window onto another and they swap

For people who will not learn `⌥⇧` + arrows: drag a tiled window by its title bar
onto another tile and the two swap places; drop it anywhere else and it snaps back.
The tile under the pointer lights up on the canvas while you drag. macOS moves the
window under the mouse on its own — hyprmac only watches, with global mouse monitors
under the Accessibility grant it already has: a press on a tile's title strip is a
candidate, a drag past six points is a drag, and the release swaps in the tree
(`Tile.swapping`) or leaves it, then relays out.

Measured with a scripted drag, the way everything here is: the swap worked first
time; the snap-back did not. The window came to rest 11 points off its tile, twice,
identically — a rule, not timing. `AXSurface.setFrame` skips a write when the frame is
"nearly" the last one it *requested*, and after a drag by the user the last request
is exactly the tile the window should return to. Now the dragged window (and its
target) forget their requested frame at the drop, and again before each of three
settle relayouts (0.25, 0.8, 1.6 s), because the first relayout re-records the tile
as requested and macOS's own drag-to-screen-edge tiling zooms the window *after*
that. Self-drop: snapped back. Menu-bar drop (macOS's edge zone): snapped back.
Swap: swapped. If you use macOS's edge tiling on purpose, hyprmac will undo it on a
tiled window; turn it off in System Settings → Desktop & Dock if the zoom flash
bothers you.

**QA, and the second version.** Used by hand, the first version glitched — the
window and the mouse parting company mid-drag, and drops that did not flip. Both had
causes. Every change of drop target redrew the canvas through a full relayout, which
wrote window frames under the mouse; and the three settle relayouts after a drop kept
firing for 1.6 s, so a second drag begun quickly had its window yanked back. A drop
only counted inside a tile, so a release over a gap or a border did nothing; and the
grab was judged against the layout's tile, so a window slightly off its slot could
not be picked up. Now: the highlight redraws the canvas only (`refreshCanvas`, no
frame writes); settle relayouts check a drag generation and stand down when a new
drag has begun; the grab uses the window's actual frame; a drop within 48 points of
a tile counts as that tile.

**Drop zones.** The middle of a tile means swap. A side of it means *put me in that
half*: the target splits along that axis and the dragged window takes the side it was
dropped on (`DropZone`, `Workspace.move(beside:)`, both tested); the canvas lights the
half, not the whole tile, so you see it before you let go. Two questions, answered by
two different things (`DropZone.hit`, tested). *Which tile* is the one the window
covers most — not the one under the pointer, which rides the title bar and is
routinely over the tile above the one you mean. *Which side of it* is where the
window's centre sits inside that tile, with a dead band of ±0.3 of the tile's
half-extent around the middle that means swap. An axis on which the window covers the
tile end to end says nothing — it is over both halves, whole — so a window dropped
square on a tile smaller than itself is a swap, the only thing it can sensibly mean.

The band has been wrong twice, and each way was found by hand. Judged by the pointer,
dragging a window *down* over its neighbour read as *above* it, since the pointer sits
at the window's top edge: the flip worked upward and not downward. Judged by how much
of each half the window *covered*, a window the size of its target had to be hauled a
quarter of the screen sideways before either half won a 65/35 majority — and two
windows is exactly the case where each one is half the screen, so the halves went out
of reach altogether. The centre is the measure that moves point for point with the
drag, so the band is a distance you can feel, and it is independent of the window's
own size, so a half-height window let go in the lower half of a tall tile is not
sitting on the boundary — which was the sweet spot the covering rule was written to
cure. `WindowDrag` keeps the grab offset from the press and carries the window's frame
along with the pointer, since macOS honours the offset through a drag — except against
the menu bar, where it pins the window and lets the pointer go on alone. The pointer
speaks only from there: in the menu bar it means *above* the topmost tile, which
neither covering nor the centre can say, since a window cannot get above a tile it is
already as high as. A drop that would change nothing — "above the one I am already
above" — swaps instead (`Tile.splits(_:then:along:)`, tested): nobody drags a window
to leave it put. A
scripted QA (`dragqa.py`) drags a real window through the cases: swap, then an
immediate swap back; a drop in the gap; a drop on the left, bottom, right and top
edges of two different tiles with three windows up, each checked for adjacency and
for every window sitting exactly where a relayout would put it. Eight of eight.

The ninth check was the probe's own lesson. Sampling the window's position during a
continuous synthetic drag showed it well behind the pointer — and it showed the same
lag, to the hundredth, with hyprmac stopped entirely. That lag is macOS's handling of
a synthesized drag, not the window manager's; on this build hyprmac writes nothing
under the mouse. (The first version's glitch was real and is on record: erratic
offsets, from relayouts under the drag.)

## Icons

`scripts/make-icons.sh` renders both app icons from the projects' own material and
writes the `.icns` files the bundle scripts copy in: hyprmac's is the dwindle glyph
from the build log — one tall tile, two stacked, the first one in Catppuccin blue —
on the `#1e1e2e` base with a `#11111b` edge; Wisper's is a frame of her resting
portrait (`idle.mp4`, half a second in), full bleed on the same plate, with a thin
blue ring and a soft fade at the bottom. AppKit draws them at 1024 px
(`scripts/icons/makeicon.swift`), `sips` makes the ten sizes, `iconutil` packs them.
Change the portrait clip or the palette and run the script again.

## Requirements

- macOS 14+
- Xcode (the toolchain's test macros need a full Xcode, not just Command Line Tools)

## Build

```sh
./scripts/make-signing-cert.sh   # once — see below
./scripts/bundle.sh              # → build/WispOS.app

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`swift test` needs `DEVELOPER_DIR` pointing at a full Xcode. Under Command Line
Tools the build fails with `TestingMacros ... plugin not found`, because the
testing macros are not shipped there.

**Run `make-signing-cert.sh` once, before your first build.** macOS keys the
Accessibility grant to a code signature, and with no identity on the machine
`bundle.sh` signs ad-hoc — a fresh signature every build, so the grant is revoked
every build. The symptom is nastier than it sounds: the app dies at launch while
System Settings still shows its checkbox **on**, because the row is keyed to the
bundle id and the authorisation underneath is keyed to a code hash that no longer
exists. Toggling it off and on rewrites the same dead record; it has to be removed
(the `−` button, or `tccutil reset Accessibility dev.keenancarroll.wispos`).

The script creates a local self-signed code-signing identity — no Apple ID, no
expiry — and `bundle.sh` picks it up automatically, preferring a Developer ID or
Apple Development certificate if you have one. Any stable identity will do; what
breaks the grant is the signature *changing*.

One trap worth knowing if you write something similar: OpenSSL 3 writes PKCS#12
with an SHA-256 MAC that macOS's Security framework cannot read, and `security
import` rejects it as `MAC verification failed (wrong password?)` — which sounds
like a typo and is not one. The script pins the legacy SHA1/3DES algorithms.

> Launched from a terminal the app inherits *the terminal's* Accessibility grant,
> so it can run fine there while failing from Finder. Test with `open` when you are
> debugging a permissions problem, or you will be debugging the wrong process.

## Run

One at a time: a second launch of the app — Spotlight, `open -a`, a stale bundle in
another folder — sees the first by bundle id and exits before it touches a window. Two
managers on one desktop each tiled the same windows against the other; that was the
day "open the build doc" launched the app twice.

```sh
./build/WispOS.app/Contents/MacOS/wispos --dry-run   # log layouts, touch nothing
./build/WispOS.app/Contents/MacOS/wispos             # for real
```

Grant Accessibility on first launch: System Settings → Privacy & Security →
Accessibility. Quit with `ALT+SHIFT+Q`.

> **Use `--dry-run` while developing.** Running for real rearranges every window you
> have open, and there is no undo.

## Talking to it: `wispctl`

The `hyprctl` of Wisp OS. A Unix socket at `$TMPDIR/wispos.sock` — macOS's
per-user equivalent of `XDG_RUNTIME_DIR`, mode 0700 — takes one JSON object per
line and answers with one:

```sh
./scripts/wispctl status                 # workspaces, windows, what is focused, the date
./scripts/wispctl windows                # every managed window, flat, with ids
./scripts/wispctl screen [id]            # readable text of the focused (or named) window
./scripts/wispctl dispatch workspace 3   # any dispatcher from the config
./scripts/wispctl focus <id>             # switch to that window's workspace and focus it
./scripts/wispctl say "focus left"        # spoken words through the voice grammar; done here if a command
```

`screen` walks the window's accessibility tree and returns what a person could
read — a terminal hands over its visible grid as one node (~3K chars in 22ms), a
browser page a few hundred nodes (~19K chars in 45ms), capped so a pathological
page cannot stall the caller. Asked while Wisper is frontmost, it reads the window
you were on *before* her: asking her focuses her, and she should not answer about
her own transcript.

This is the only door Wisper uses to see the screen or touch a window, so exactly
one process holds the Accessibility grant and there is one place to audit what she
was allowed to do. Her `do` tool carries a fixed allowlist of dispatchers — nothing
that runs a command, closes a window, or launches an app.

## Debugging

`~/Library/Logs/hyprmac.log` is the trace, timestamped, kept across launches (rotated
once at 2 MB). Launched from the Dock there is no stderr, and "workspace 1 rearranged
itself" had nothing to read. Every workspace whose shape changes gets one line there
with the cause it changed under:

```
15:03:40.372 tree ws5: (8319 | 8317) / 8321  ->  8319 / 8321   [minimized surface#8317]
15:03:42.694 tree ws5: 8319 / 8321  ->  (8319 | 8317) / 8321   [un-minimized surface#8317, back in its slot]
```

`|` is side by side, `/` a stack, first before second. Causes: `added … into its saved
slot / inserted at the focused tile`, `closed …`, `minimized …`, `dispatch swapwindow(…)`,
`drag swap … with …`. If a workspace comes back wrong, `grep "tree ws1"` there says
which step did it.

```sh
./scripts/state.sh    # dump the live layout tree to wispos's stderr
```

It prints the tree, and for each surface its planned frame versus its actual one —
the fastest way to tell a layout bug from an app that refused to be resized.

## Configuration

Written to `~/.config/wisp/wispos.conf` on first run.

```conf
$mod = ALT

general {
    gaps_in = 12          # breathing room between windows
    gaps_out = 16         # and off the screen edge
    rounding = 12         # matches the macOS window corner radius
    col.active_border = accent   # follows System Settings > Appearance
}

canvas {
    wallpaper = system    # your own desktop picture; or a colour, or an image path
    dim = 0.15            # darken it so tiled windows read as the foreground
    desktop_icons = true  # sit below Finder's icons so they stay visible
    menu_bar_indicator = true
    workspace_hud = true
}

workspaces {
    1 = wisp              # names show in the menu bar and the switch overlay,
    2 = notes             # and can be bound: bind = $mod, M, workspace, notes
}

animations {
    enabled = true        # crossfade through the desktop on a workspace switch
    duration = 250        # milliseconds, the whole switch; Reduce Motion wins
}
```

```conf
windowrule {
    ignore = com.example.some-overlay   # never tiled, parked, or listed
    float  = com.apple.systempreferences
}
```

Wisper is ignored by default: she is an overlay along the bottom of the screen
while you talk to her, not a tile.

**There are five workspaces, and the number is fixed.** hyprland grows them on
demand because a Linux desktop has nowhere else to put them; macOS already has
Spaces, and a workspace with no key bound to it is one you can see in the menu bar
and step into but never jump to — which reads as a broken hotkey rather than an
unbound one. A config still carrying the old `count` setting is told it was removed
rather than that it is unknown.

### Keybindings

`⌥/` opens a sheet listing everything currently bound, built from the live config.

| | |
|---|---|
| **Focus** | `⌥ H J K L` or `⌘ ← ↓ ↑ →` |
| **Move window** | `⌥⇧ H J K L` or `⌘⇧ ← ↓ ↑ →` |
| **Resize** | `⌃⌥ H J K L` |
| **Workspace** | `⌥ 1…5`, move window there with `⌥⇧ 1…5` |
| **Window** | `⌥Q` close · `⌥V` float · `⌥F` fullscreen · `⌥S` flip split |
| **Wisper** | `⌥Space` bring her up / send her away · tap `⌃` twice (either side) to talk, twice again when done · `⌥P` ask her (typed) |
| **Session** | `⌥/` keybindings · `⌥⇧C` reload · `⌥⇧Q` quit |

Global hotkeys are consumed system-wide, so every arrow binding costs you whatever
macOS already used it for. `⌘`+arrows costs **line-start/line-end** in text fields,
and **enclosing folder / open** in Finder. `⌃⌥`+arrows would have collided with
macOS's own built-in window tiling, and plain `⌥`+arrows with word-wise cursor
movement — there is no free arrow cluster left on a modern Mac.

If the text-editing loss bites, `⌘⌥`+arrows is the least contested alternative
(it only shadows browser tab switching); change `SUPER` to `SUPER ALT` on the eight
arrow binds.

**Why `ALT` and not `SUPER`?** macOS has already claimed most of Cmd — `Cmd+Q`,
`Cmd+W`, `Cmd+1` all mean something to the focused app. A WM bound to Cmd fights the
system on every keystroke. Change `$mod` if you disagree.

A modifier tapped twice on its own is a bind too — `doubletap = CTRL, exec, open -g
wisper://listen` — either control key; laptop keyboards have only the left one. A
side can be named — `RCTRL`, `LALT`, `RSUPER` — because a
`flagsChanged` event carries the modifier key's own key code (62 is right control);
a plain `SUPER` means either ⌘. It was `SUPER` first, and ⌘ is a bad tap: two quick
presses while reaching for C or V brought Wisper up and took the paste. Right
control is a key nobody taps by accident. (`-g` so `open` does not activate Wisper
first — she brings herself forward.) There is no key in it, so it is not a hotkey the system can
register; Wisp OS watches modifier changes and counts a tap as one short, clean
press-and-release with nothing else pressed while the modifier was held. Two within
0.4s fire it. A hotkey firing cancels any tap in progress — Carbon consumes the
keystroke, so without that `⌥H` followed by one tap of `⌥` read as a double tap.
Measured, then fixed. ⌘ shortcuts inside apps are not consumed by Wisp OS, so
`⌘C` is seen as a key and cannot count as a tap either.

`terminal` opens a new window in the *running* Ghostty — File ▸ New Window over
Accessibility — where `exec, open -na Ghostty` started a second Ghostty per press, each
with a Dock icon that outlived its window (four, measured). The control socket has the
same as `terminal [dir] [cmd]`: the window appears, is focused, and one line is typed
into its shell — `cd 'dir' && clear && cmd` — so Wisper's agents land in the one Ghostty
too. When a Ghostty window closes and more than one instance is running, the empty
instances are quit. `activate <bundle>` on the socket brings an app forward on
another app's behalf — Wisper's own `NSApp.activate()` is a request macOS may
decline (it did), and this process, under the Accessibility grant, is not asking.
It replies before it acts: the Accessibility push needs the target's main thread,
and when the target is the one asking, that thread is waiting on the reply —
measured as 1.5 s per ⌥Space on the AX timeout until the order was swapped.
One more thing the old way caused: recent Ghostty asks *Allow
Ghostty to execute "/opt/homebrew/bin/claude"?* for any command handed to it from
outside (`--args -e …`) — its guard against URL-driven execution. A line typed into a
shell is not from outside, so the question is gone with the launcher.

Dispatchers: `terminal` `exec` `killactive` `movefocus` `movewindow` `resizeactive`
`togglefloating` `fullscreen` `togglesplit` `workspace` `movetoworkspace`
`cyclenext` `reload` `exit`.

## Architecture

```
HyprCore/    pure Swift — no AppKit, fully unit tested
  Tile         the dwindle tree: insert / remove / swap / resize / neighbour
  Workspace    a tree plus floating windows
  Config       hyprland.conf parser → typed config + diagnostics
  Keys         hyprland key names → macOS virtual key codes

HyprKit/     macOS glue
  Surface           the protocol a tile holds  ← the extension point
  AXSurface         a real app window, over the Accessibility API
  SurfaceRegistry   window discovery + AX observers
  Displays          AX ↔ AppKit coordinate conversion

wispos/      the app
  Canvas            the desktop-level canvas window
  Hotkeys           Carbon global hotkeys
  WindowManager     dispatchers, workspaces, parking
  ParkingCover      hides the parked windows' slivers
```

The layout engine never learns what a tile contains. `Surface` has one
implementation today (`AXSurface`) and is designed for a second: `HostedSurface`,
a pane rendered inside the canvas rather than owned by another app. Hosted panes
would get what AX can never give — real animation, rounded corners, opacity —
without changing the tree, the config, or a single keybind.

## How it works, and what it costs

macOS has no Wayland. `WindowServer` is closed, so this is not a compositor: it
drives other applications' windows through the Accessibility API.

**Workspaces without disabling SIP.** A workspace you aren't looking at has its
windows **parked**: pushed into the bottom-right corner, where the WindowServer
clamps them so that about 40×52pt of each stays on screen — and a small panel,
painted with your wallpaper, sits over that corner and hides every sliver at once.
Switching back is one position write per window.

Three mechanisms were built and measured before settling on this one:

```
park / unpark a window          1-6ms each, no animation          per window
hide / unhide an application    0-17ms, no animation              whole app only
un-minimize a window            ~500-700ms each, serialized       per window
```

**Minimizing** was the first. Correct, and unusably slow: the Dock plays the genie
once per window, in sequence, and *un*-minimizing is the expensive direction — six
windows on a workspace meant three seconds of watching them return.

**Hiding applications** (the `Cmd+H` path) was the second. Instant, but all-or-
nothing per app: unhiding brings back every window the app owns, so an app with
windows on both sides of a switch still had to minimize the ones that didn't
belong, and pay the same ~500ms each to bring them back. A terminal with a window
on every workspace made every switch slow. `AXHidden` is not settable on a window
(`-25205`); there is no per-window hide in the Accessibility API.

**Parking** was actually the first idea, abandoned because of the sliver. Every
candidate position was measured, and none escape the clamp:

```
asked -25000,-25000 -> got  -583,30     visible 40x683    top-left: whole height shows
asked  25000, 25000 -> got  1670,1060   visible 40x52     bottom-right
```

But every window clamps to the *same* corner, so the sliver is one fixed spot, and
one cover hides all of them. The cover is sized from where the windows actually
landed, with room for their shadows, rather than a constant — a different macOS
clamp rule changes its size, not its correctness.

**What the cover paints, and why it needs no permission.** The cover has to sit
above the parked windows, which puts it above any tile that reaches into the
corner as well — and it cannot go lower, because the tiles and the parked windows
belong to other apps whose stacking is not ours. A live screen capture of the
corner would solve it, and was built and then removed: a window manager asking for
Screen Recording is a red flag no matter how good the reason.

Instead the manager arranges for every sliver to sit *under* a tile that is stacked
above it, and the cover cuts a hole there so the tile does the hiding. Three levers
exist without any permission: an app with no window on the workspace is hidden
outright (no sliver at all); within one app a tile can be raised above that app's
own parked windows; and there are two corners, so a sliver can go under whichever
tile the real stacking order — readable from `CGWindowListCopyWindowInfo` — shows
above it. The one case left is a sliver of the focused app on a workspace where that
app owns neither bottom corner; there the cover paints wallpaper over the tile's
corner rather than let a piece of title bar show through.

**The switch is a crossfade.** Nothing public can fade another app's window, so
Wisp OS fades a window of its own: an overlay painted as the desktop with the
*next* workspace's empty slots, which fades in over the current windows (40% of
the duration), covers the switch itself, and fades out (60%) to reveal the new
windows already in the slots it showed. The windows read as dissolving into the
desktop and back; the parking moves happen while only the overlay is on screen.
A second switch mid-fade lands under the overlay and restarts the fade out, so
holding `⌥]` steps cleanly. Off under the system's Reduce Motion setting, or with
`animations { enabled = false }`.

**Unhiding an app moves its parked windows.** Measured: after `unhide()`, AppKit
puts an app's off-screen windows back on screen — Safari cascades them 16pt from
where they last were, Ghostty returns them to an older position. Wisp OS hides
apps with nothing on the current workspace, so every unhide is followed by parking
that app's windows a second time, and a parked window found anywhere but a screen
edge is parked again on the next relayout regardless of how it got there.

**Layouts survive a restart.** The session stores each workspace's dwindle tree and
floating rects, not just which workspace a window belongs on. Windows are
rediscovered one at a time after launch; at each step the saved tree pruned to the
windows present so far is a valid layout, so the workspace converges on the shape
you left it in whatever order they arrive. The saved shape is discarded twenty
seconds after launch — past that, a window reappearing with the same id is a
re-adoption, not a restore.

A window's *tree slot* survives its removal, too. Accessibility drops and re-reports
windows — a notification missed, the rescan re-adopting — and such a window came back
to the right workspace (its record is kept) and was then dwindle-inserted at whatever
tile had focus: workspace 1 "rearranging itself" with nobody touching it. Now the
workspace's tree is kept as it was the moment a window left, for ten minutes, and a
returning window prunes its way back into it; a record added by a removal also
survives the launch-pool expiry. Measured across a restart: workspace 1's tree
byte-identical before and after.

**Sleep is not time passing.** Both of those memories — the closed-window records and
the per-workspace tree slots — expire ten minutes after they are made, and both used
to be stamped with the wall clock. At sleep, Accessibility drops every window and
hyprmac writes exactly these records; at wake it re-reports them and they are claimed
back. So the ten minutes that decide whether your desktop survives a night were being
measured against a clock that ran all night. `NSWorkspace.didWakeNotification` was
meant to cover it, by adding the slept interval back to every stamp — but the wake
notification and the first re-reported window are two events in a race, and when the
window won, the expiry had already binned every record: each window then landed on
the workspace the machine went to sleep on, all of them in a heap. It only ever showed
on a machine that sleeps for hours; a lunch-break sleep is inside the ten minutes and
comes back right, which is why it took a work laptop to find. The stamps are now
`CACurrentMediaTime`, which stops when the machine does — measured here: 5.1 days since
boot, 47.7 h of it on the monotonic clock, the other 74.4 h asleep. Ten minutes of use
is what the records were always meant to survive, and now that is what they measure.
The wake handler has nothing left to put right and only writes the journal line, so
the ordering it used to race no longer exists.

**A keybind that does not take says so.** `RegisterEventHotKey` can refuse — most
often because hyprmac has restarted faster than the outgoing instance released its
hotkeys — and the refusal used to be written to stderr alone, which is thrown away
when the app is launched from the Dock or by `open`. The startup line still read "55
binds registered", because it counted the binds in the config rather than the ones
that took. Found the way every user will find it: `ALT+Return` stopped opening a
terminal, with nothing anywhere to say why, while the same dispatcher over the control
socket worked perfectly. Now a refusal is named in the journal — which bind, and what
took — and retried three times at 1.5 s, since the usual cause clears itself in about
a second. Verified by synthesising the keystroke: `ALT+Return` posted to the event tap,
a Ghostty window on the workspace a moment later.

**A window you float by hand stays floated — including the next one.** `ALT+V` took a
window out of the tiling and the choice died with the window: close it, open another,
and it tiled again, because the only record was the floating rect in the live
workspace and a window's id does not survive its close. Remembering it against the
window remembers nothing. The choice is really about the app — it is made because
*this program* does not want to be tiled — so floating a window by hand now adds its
bundle to a list hyprmac keeps (`floatedApps`, in the app's own preferences, so it
survives a restart), and the next window of that app floats on arrival. `ALT+V` on a
floating window undoes both: that window tiles, and the app goes back to tiling by
default. The same window re-reported by Accessibility after a drop keeps its exact
rect, since its closed-window record now carries it. That is what the download page
means by "the app that fights you only fights you once", and it was not true when it
was written: measured before, a floated Ghostty window closed and reopened came back
tiled; measured after, it floats, and one `ALT+V` puts the app back to tiling for good.

**A window that will not fit is floated.** `setFrame` is a request, and Electron and
Catalyst apps decline it: they keep a minimum size of their own — measured here,
Discord 800×500, ChatGPT 480×600, Claude 600×400. hyprmac used to write the frame and
believe it, so the first time a workspace held six windows, three of them sat over
their neighbours in a heap while the layout said everything was fine: every position
right, every size far too big. Accessibility has no minimum-size attribute to ask
for, so the only way to know is to ask and then look. A beat after each relayout —
the write returns before a slow app has finished resizing — every tiled window's
frame is read back and compared with the tile it was given, and a window that kept
more than it was given has named its floor on that axis (`MinimumSizes`, tested; only
the axis it refused on counts, since a window given a tile too narrow may take the
height it was offered). Such a window is floated: centred, at its own smallest size,
and the tiling closes ranks around it. Once its floor is known it is floated before
the write rather than after, so the overlap flashes once and never again, and `ALT+V`
puts it back by hand for good — a window the user tiles themselves is never floated
automatically again. Measured end to end: ChatGPT tiled happily at 626×683, and when a
fifth window cut its tile to 626×336 it kept 600 of height, was caught, and floated.

A closed window's record is a different thing from a launch record, and it took a
second bug to learn it. The launch pool matches by id, then app-and-title, then app
alone — right for an app relaunched after a restart, whose windows have new ids. A
record made when a window *closes* was going into the same pool, and "same app" is
the matcher's last resort: close a Ghostty window on workspace 4 and the next new
Ghostty window matched it and landed on 4 (reproduced with a probe: WRONG). Closed
windows now keep their own list, claimed by exact id only — a re-adopted window is
the window that left; a new one never is — for ten minutes; the record still goes
into the saved session, so an app quit for an afternoon comes back by title at the
next launch, and only then. Same probe after: RIGHT.

The remembered *assignments* expire with the layouts, twenty seconds after launch.
They did not, at first: a record nothing had claimed — a Ghostty on workspace 4 from
a session days ago — sat in the pool and claimed the next new Ghostty window, which
appeared on the workspace you were on, was sent to 4, and was parked out of sight:
"windows from Spotlight pop up and disappear". Messages always landing on workspace 1
was the same record, older. After the grace, a new window is new and lands where you
are; measured on workspace 2 for both. Inside the grace there was still a hole, and
it opened after every restart of the window manager rather than at login: the records
of windows *closed* earlier go into the saved session (for the app quit for an
afternoon), and after a restart, with the app still running and its real windows
found by id, those records had nothing to claim but the app's next new window —
measured: a terminal opened on workspace 4 within twenty seconds of a restart landed
on 3, where one with that title had been closed. A window matched by exact id proves
its app has run since the save, so once the first sweep is done (3.5 s) every
unclaimed record of such an app is dropped (`SessionMatcher.dropRecords(ofApps:)`,
tested); at login nothing matches by id and the launch pool works as before.

**The rule, stated once.** A new window lands on the workspace you are looking at.
That is where you opened it, and where you are is the only thing the window manager
knows about what you meant. The windows that go elsewhere are not new: the same
window re-reported after Accessibility dropped it (claimed by exact id), and windows
found at launch that the saved session places. Nothing else — not the app, not the
title, not where a window like it once lived — decides. The same rule for focus:
an app's own focus report never moves you; only your gesture does (`Cmd+Tab`, a Dock
click, `open -a` of a running app), and a launch of yours holds still until its
window arrives. You organise the spaces; hyprmac keeps them as you left them.

The gesture that is not a launch follows the same rule. Click Safari in the Dock, or
open it from Spotlight, on a workspace with no Safari window: macOS activates Safari
and hands it its key window, parked on another workspace, and hyprmac used to take
you there. "Safari, here" was the meaning, and here, with none of the app here,
means a new window: hyprmac presses File ▸ New Window in the app's own menu bar
over Accessibility and holds for it the way it holds for a launch of its own, so
the window lands where you are and nothing flashes. If the app does have a window
on this workspace, that one takes focus instead. `Cmd+Tab` is the one gesture that
means *switch to that app*, and it still takes you to the parked window; it is told
apart by how it ends — the app activates on the release of ⌘, where a Dock click
ends in a mouse-down and Spotlight in a Return (global monitors see all three). An
app whose File menu has no "New Window" is followed as before. The journal says
"took focus with none of the app on ws3 — asked it for a new window here".

What parking costs: a parked window is still on screen as far as macOS is
concerned, so Mission Control and `Cmd+Tab` show it. Switching to one by `Cmd+Tab`
takes you to its workspace rather than leaving the keyboard in a window you cannot
see. The corner under the cover is a small dead zone for clicks.

That rule had a false positive: launching an app *activates* it first, and macOS
hands an activated app its old key window — for an app with windows on other
workspaces, one we parked. Measured from an empty workspace 4: opening Ghostty
(Spotlight, the "New Window" helper, `open -a`, the `terminal` bind alike) reported
focus on its parked workspace-2 window, hyprmac followed it to 2, and the new window
landed there. Now a parked window's focus is held for 350 ms before it is followed.
A new window of the same app arriving inside the hold means the focus was the
launch's echo: the hold is dropped and the window lands where you are (measured:
the helper's window arrives 130–160 ms after the echo, the `terminal` bind's in 1 ms).
A launch slow enough to outlast the hold still gets a second chance: for one second
after a follow, a new window of that app goes to the workspace you were on and takes
you back — so `Cmd+Tab` to a parked Ghostty and a new window within a second of it
land on the workspace you came from; anything later lands where you are. That
second chance still showed: a follow and a return is the workspace flashing away
and back, and Ghostty took 1 ms to 1772 ms to produce a window across one evening
(three of twelve launches outlasted the hold), so no hold short enough for a
`Cmd+Tab` covers it. But most launches are ones hyprmac makes itself — the `terminal`
bind, an `exec` of `open -na App` (`-n` and `-a` together; plain `open -a` activates
a running app and makes no window, and the Safari bind counts on being followed),
and a Dock click or Spotlight launch answered with File ▸ New Window (above). For five
seconds after one, a parked focus of that app is held with no timer at all: the
window is coming, however long it takes, and it clears the expectation when it
arrives — wherever it goes, since a remembered window goes back to its old slot.
Only a parked focus with neither a launch nor a gesture behind it — an app
activating itself — still runs the 350 ms race. The "New Window" Spotlight helpers
(`scripts/make-new-window-app.sh`) are retired: a Dock click or Spotlight does the
same now. The journal says "took focus N ms after we launched the app — holding
for its window". The other false positive was closing an app's last window on a workspace: macOS focuses the
app's next window, parked elsewhere, and you were teleported off the workspace you
had just emptied. That focus arrives *before* the close is reported; the close
cancels the hold and you stay. `Cmd+Tab` and a Dock click to a parked window still
take you there, 350 ms later than before. The journal names each case: "launch: …
staying on ws4", "… back to ws4", "the app's refocus, staying on ws4".

Quitting, and `SIGINT`/`SIGTERM`/`SIGHUP`, unpark everything first; a `SIGKILL`
will not, and would leave windows wedged in the corner with no running WM to fetch
them — drag them out by the title bar sliver, or relaunch Wisp OS and quit it.

**The canvas sits *below* your windows,** and by default below Finder's desktop
icons too, so they stay where they are. It repaints your own desktop picture rather
than replacing it with a flat colour. Its stroke shows in the gap ring around each
window, never on top of one.

### Looking like a Mac

The temptation with a project like this is to ship a Linux ricing aesthetic — a
status bar across the top, hard accent borders, a fixed dark palette. All of that
reads as foreign on macOS, so none of it is here:

- **Workspaces live in the menu bar.** There is already a bar across the top of the
  screen; putting a second one under it is the most out-of-place thing this could do.
- **Focus is shown with depth, not an outline.** macOS never draws a border around
  the focused window — it uses shadow. The active tile gets a soft halo in your
  accent colour rather than a hard 2px stroke, which in a 12pt gap reads as a
  harsh divider.
- **Your accent colour, your wallpaper, your appearance.** `col.active_border =
  accent` follows System Settings, and the canvas repaints your own desktop picture.
- **The workspace overlay** uses the system HUD material, like the volume overlay.

### Honest limits

| | |
|---|---|
| Rounded corners on real windows | impossible without private SkyLight APIs |
| Smooth window animation | AX exposes position and size, nothing else |
| Mission Control shows workspaces | it sees one Space; workspaces are ours, not macOS's |
| Hiding a window completely | off-screen positions get clamped back; a ~40×52pt sliver always remains, hidden under a cover |
| Apps that refuse to resize | skipped — `isTileable` checks settability first |

## Roadmap

- [ ] `hyprctl`-style IPC socket
- [ ] Multi-display: one workspace set per screen (a change of primary display — a monitor plugged in, the lid closed — already relays out and re-parks)
- [ ] Screenshot-based move animation (capture → animate the image → snap the window)
- [ ] `HostedSurface`: terminal and web panes rendered inside the canvas
- [ ] Master and scrolling layouts
- [ ] Window rules beyond float-by-bundle-id
