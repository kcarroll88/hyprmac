# Bug log

Found during the 0.1.0 beta, to be fixed in a batch. Newest first. Each entry says
what was seen, not what I guess is wrong — a diagnosis written before the repro is
run is how the last three of these took several attempts each.

Status: **open** unless marked otherwise.

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
