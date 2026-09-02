# Bug log

Found during the 0.1.0 beta, to be fixed in a batch. Newest first. Each entry says
what was seen, not what I guess is wrong — a diagnosis written before the repro is
run is how the last three of these took several attempts each.

Status: **open** unless marked otherwise.

---

## 7. Safari opens a blank window here and the page in a tab over there

**Build:** 20260902-1312 · **Reported:** 2 Sep

**What happens.** Something asks Safari to open a page. Safari puts it in a new tab of
the window it already has — on another workspace — and hyprmac adds an empty Safari
window on the workspace you are standing on. You end up with a blank window in front of
you and the thing you asked for somewhere you cannot see.

**Cause — this is the cost of a feature added the same day, and it is mine.** When an
app is activated and has no window on the current workspace, hyprmac presses File ▸ New
Window in that app's own menu bar, so that clicking Safari in the Dock gives you a
Safari window *here* rather than teleporting you to wherever Safari happens to live.
That is right for "activate Safari" and wrong for "open this URL in Safari": in the
second case Safari has already handled the request, in a tab, in the window it already
had — and hyprmac's extra window is empty and unwanted. From the activation alone the
two are indistinguishable, which is the whole difficulty.

**What it should do** (the reported preference, and it is the right rule): the request
should land where it was made — a new window on this workspace, or a new tab if that
app already has a window here.

**Options, none free.**

1. **Wait before pressing.** On activation with nothing here, hold ~800 ms. If the app
   produces a window of its own in that time, use that one — moving it here if it
   opened elsewhere — and never press New Window. Fixes the case where Safari opens a
   window, does nothing for the case where it opens a *tab*, and delays the Dock-click
   path for everyone.
2. **Notice the app handled it.** An existing window's title changing right after the
   activation means the request was absorbed by a tab. Detectable, and fragile: it is a
   heuristic about timing dressed up as a fact.
3. **Fix what hyprmac controls.** hyprmac's own `exec` binds that open URLs can ask for
   a new window explicitly rather than letting the app choose. Correct and complete for
   hyprmac's own binds, and does nothing for a link clicked in another app.

(1) and (3) together cover most of it honestly. Worth remembering that the feature this
breaks was itself a fix for a real complaint, so the answer is not to remove it.

---

## 6. A window sometimes changes workspace when switching quickly

**Build:** 20260902-1312 · **Reported:** 2 Sep

**What happens.** Switching workspaces in quick succession occasionally leaves a window
on a different workspace than the one it was on. Intermittent.

**Narrowed 2 Sep: it happens when picking a workspace from the overview.** That is a
specific enough path to read, and there is an ordering problem in it.

```swift
panel.onPick = { self?.hide(); self?.onPick?(index) }   // hide() → dismiss(), then switch
func dismiss() { let restore = previouslyActive; fadeOut { restore?.activate() } }
```

`hide()` starts a 0.22-second fade and schedules `restore?.activate()` for when it
finishes; `onPick` then dispatches the workspace switch **immediately**. So the
workspace changes first, and a fifth of a second later hyprmac re-activates whatever
app was frontmost *before* the overview opened — an app whose windows have just been
parked by that very switch.

An activation of an app with nothing on the current workspace is precisely what the
parked-focus logic in `didFocus` exists to interpret, and it has three branches: follow
the parked window to its home workspace, focus a window of that app here, or — the one
added most recently — **ask the app for a new window here** via File ▸ New Window.
That last branch creates a window on the workspace you just arrived at, from an
activation the user never performed. `lastSwitch` guards this for half a second, and a
0.22-second fade plus activation latency plus the AX notification is close enough to
that boundary to be a race rather than a rule, which fits "sometimes".

**Where to look first:** the journal will name it — `[added surface#…]` right after a
`workspace` dispatch means the new-window branch fired.

**Fix direction.** The restore in `dismiss()` is for *cancelling* the overview, not for
committing to a choice: picking a workspace should not re-activate the app you were
looking at before. Separating dismiss-by-escape from dismiss-by-pick is likely the
whole fix, and `lastSwitch` should cover the activation that follows either way.

**Still worth catching in the wild,** in case it also happens without the overview: hyprmac writes a line for
every tree change with the cause that made it — `tree ws2: … -> … [dispatch
moveToWorkspace(3)]`, `[added surface#…]`, `[drag swap …]`. When this happens next,
note roughly when, and `~/Library/Logs/hyprmac.log` will name the mechanism rather
than leaving us to guess between the candidates below.

**Candidates, in the order I would check them.**

1. **A window re-adopted mid-switch lands where you are.** Accessibility drops and
   re-reports windows, and the three-second rescan re-adopts them. A new window is
   placed on the *active* workspace by design; a re-adopted one is meant to be caught
   by its closed-window record, which is keyed by exact id. If a window is re-reported
   without ever having been seen to close, there is no record to catch it, and it will
   be treated as new — landing wherever you happen to be standing at that moment. Rapid
   switching widens that window of opportunity considerably.
2. **The parked-focus follow, racing the switch.** `didFocus` ignores focus reports for
   half a second after a switch (`lastSwitch`) precisely because switches generate
   their own focus echoes. Switching faster than that guard is exactly what the guard
   assumes cannot happen.
3. **Frame writes crossing a switch.** Parking a window is a frame write, and a relayout
   scheduled before a switch can land after it.

---

## 5. Discord reopens its window when you return to the workspace

**Build:** 20260902-1312 · **Reported:** 2 Sep

**What happens.** Close the Discord window. Discord keeps running with no window, which
is expected on a Mac. Switch to another workspace and back to the one Discord was on,
and the Discord window has opened itself again.

**Cause — likely, and testable.** Returning to a workspace unhides the apps that belong
to it (`WindowManager.swift`, the `hiddenApps.intersection(activeApps)` loop calling
`NSRunningApplication.unhide()`), because hyprmac hides an app whole when it has nothing
on the workspace you are looking at — that is what stops a parked window's sliver
showing through. Electron apps routinely respond to being activated or unhidden with no
open windows by creating one; that is the framework's default `activate` behaviour, and
Discord is Electron. hyprmac then sees a genuinely new window and places it on the
workspace you are standing on, which is the one it just came back to — so it looks like
the window restored itself.

**Worth checking first:** whether Discord is in `hiddenApps` at all once its last window
is closed, since an app with no windows has nothing to park and might never be hidden.
If it is not, the cause is elsewhere and the next suspect is the closed-window record
placing a recreated window back on its old workspace.

**The fix is about not waking apps that have nothing here.** An app with no windows on
any workspace should not be unhidden by a workspace switch, and possibly should not have
been hidden by one either.

---

## 4. Dragging a floating window drags the tiled window underneath it too

**Build:** 20260902-1312 · **Reported:** 2 Sep

**What happens.** A Safari extension's automatic picture-in-picture window sits on top
of the tiling. Dragging that PiP window by hand also starts hyprmac's own window drag on
whatever tiled window is beneath it, so one gesture moves two windows and can end in a
swap nobody asked for. The two need treating as separate things.

**Cause — high confidence, from reading `windowDrag.candidate` (`WindowManager.swift`).**
The candidate for a drag is chosen on geometry alone:

```swift
for id in ws.tiled {
    guard let f = registry.surface(for: id)?.frame, f.contains(p), p.y - f.minY < 34 else { continue }
    return (id, f)
}
```

A press within the top 34 points of a tiled window's *frame* starts a drag of that
window. Nothing checks what is actually under the pointer. A PiP window — floating,
borrowed by another app, and not in hyprmac's registry at all, since the registry only
adopts tileable windows — is invisible to that test: press its title area where it
overlaps a tiled window's strip, and hyprmac grabs the window underneath. The same must
be true of any floating window, any dialog, and any window hyprmac does not manage.

**The fix is to ask who is really there, not to guess from rectangles.** Options, best
first:

1. `AXUIElementCopyElementAtPosition` for the press point, walk up to its window, and
   only proceed if that window is the tiled one we think we are grabbing. Correct for
   every case — floating windows, unmanaged windows, other apps' overlays — because it
   asks the system rather than reasoning from hyprmac's own incomplete picture.
2. `Accessibility.stackingOrder()` is already used by `placeSlivers`, and could reject a
   candidate that is not topmost at that point. Cheaper, but only knows about windows
   hyprmac has seen, which is exactly what a PiP window is not.
3. Reject presses that land inside any window in `workspace.floating`. Fixes floating
   windows hyprmac knows about and does nothing for this bug.

Worth measuring the cost of (1) on mouse-down before committing to it: it is an AX
round-trip on every click, and the press handler runs on a global monitor.

---

## 3. The swipe needs a much bigger movement on one Mac than the other

**Build:** 20260902-1312 · **Reported:** 2 Sep

**What happens.** On the personal Mac (Magic Trackpad, wireless) the three-finger
swipe feels right. On the work Mac (built-in laptop trackpad) the same gesture needs a
noticeably longer swipe. Not noticed on the personal laptop's own trackpad last night.

**First thing to check, before anything else** — on the work machine:

```
grep threshold ~/.config/wisp/hyprmac.conf
```

**Cause — confirmed 2 Sep.** The work machine's config reads `threshold = 0.12`.
Nothing to do with the trackpads. Immediate fix on that machine:

```
sed -i '' 's/threshold = 0.12/threshold = 0.06/' ~/.config/wisp/hyprmac.conf
```

then `ALT+SHIFT+C` to reload. The entry stays **open** for the design problem below,
which is the part worth fixing properly.

**Why it happened, and it is not the hardware.** `ConfigStore.load`
writes the default config *only when the file does not exist*. The work machine was
installed from the old tarball, whose config had `threshold = 0.12`; reinstalling from
the DMG left that file untouched, because reinstalling should not throw away someone's
settings. So the work machine is still running the old, deliberately-sluggish value
while this machine runs 0.06. If the grep says `0.12`, that is the whole story.

**The real problem behind it.** A default that only reaches new installs is not a
default, it is a first-run value. Every setting tuned from here on will silently miss
everyone who already has a config, and they will experience it as the app being worse
on one machine than another — which is exactly what happened. Worth deciding how
config evolves: leave values alone but add new keys with comments; or record which
values were written by hyprmac rather than by the user, and update the untouched ones;
or say plainly in the config that it is yours now and defaults will not reach it.

**Second point, still worth measuring.** The threshold is a fraction of the
trackpad, and MultitouchSupport reports positions normalised per device — so the same
fraction is a different physical distance on a Magic Trackpad than on a built-in one.
One number cannot feel identical on both. Worth measuring the two devices before
choosing whether to keep a fraction, switch to a physical distance, or keep separate
values per device.

---

## 2. Closing the setup window leaves hyprmac running invisibly

**Build:** 20260902-1312 · **Reported:** 2 Sep

**What happens.** Launch hyprmac without the Accessibility grant. The setup window
appears and hyprmac waits — it manages nothing. Close that window. hyprmac is still
running, with no Dock icon (`LSUIElement`) and no menu bar item, so there is nothing
on screen to say it exists and no way to quit it. Trying to delete the app then fails:
macOS refuses because it is still running.

**Expected.** Either hyprmac is visible and quittable, or closing the window while it
has never started ends it.

**Suspected cause — high confidence.** `applicationDidFinishLaunching` returns early
when untrusted, so `manager.start()` never runs, and the status item is installed by
`manager.start()`. Waiting mode therefore has no menu bar presence by construction.
The window is the only handle on the process, and closing it was deliberately made
non-fatal (so the app keeps waiting for the grant) — which is right for someone who
is about to grant it, and a trap for someone who has changed their mind.

**Worth deciding, not just fixing.** Options: install the status item before the
manager starts, so waiting mode is visible and quittable; or quit on close when
nothing has ever started; or both. Second one is simplest, first is kinder.

---

## 1. The overview stays open after clicking a window

**Build:** 20260902-1312 · **Reported:** 2 Sep

**What happens.** Three-finger swipe up to open the overview, then click one of the
window icons. It goes to that window, but the overview panel stays on screen and only
goes away once you interact with it again.

**Expected.** Clicking a window closes the overview and takes you to the window.

**Not yet diagnosed.** `WorkspaceOverview` calls `hide()` before `onPickWindow`, so
the intent is there and something is undoing it or the click is arriving by a path
that skips it. Candidates worth checking in order: whether the click lands on the
`IconButton` at all or on the card beneath it; whether `refresh()` — added so the
overview follows workspace switches — rebuilds and re-presents the panel after
`controlFocus` relayouts; whether `dismiss()` completes when the panel is not key.
The middle one is the newest code and the most likely.

---
