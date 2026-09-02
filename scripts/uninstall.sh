#!/usr/bin/env bash
# Take hyprmac off this Mac.
#
#   scripts/uninstall.sh            → quit it, remove the app, keep your config
#   scripts/uninstall.sh --purge    → also remove the config, session, preferences,
#                                     log and the Accessibility grant: a Mac that has
#                                     never seen hyprmac, for testing a real install
#
# Nothing is deleted outright. Everything removed is moved to
# ~/Desktop/hyprmac-uninstalled-<date>/ and the script prints the one command that
# puts it all back.
set -euo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
[ $# -gt 0 ] && [ "${1:-}" != "--purge" ] && { echo "usage: uninstall.sh [--purge]" >&2; exit 2; }

BUNDLE="dev.keenancarroll.wispos"
BACKUP="$HOME/Desktop/hyprmac-uninstalled-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
moved=0

say() { printf '  %s\n' "$1"; }
keep() { # keep <path> [subdir]
    [ -e "$1" ] || return 0
    mkdir -p "$BACKUP/${2:-.}"
    mv "$1" "$BACKUP/${2:-.}/"
    say "moved $(basename "$1")"
    moved=1
}

echo "==> stopping hyprmac"
# SIGTERM, not SIGKILL: the handler puts every parked window back on screen first.
if pgrep -x hyprmac >/dev/null; then
    pkill -x hyprmac
    for _ in $(seq 1 40); do pgrep -x hyprmac >/dev/null || break; sleep 0.25; done
    say "quit, and parked windows restored"
else
    say "was not running"
fi

echo "==> removing the app"
for app in /Applications/hyprmac.app "$HOME/Applications/hyprmac.app"; do
    [ -e "$app" ] && { rm -rf "$app"; say "removed $app"; }
done
# A login item registered by the app itself lives in the user's launch services
# database; unregistering it needs the app, which is gone, so macOS drops it on its
# own at the next login. This clears an old-style System Events one if there is one.
osascript -e 'tell application "System Events" to delete (every login item whose name is "hyprmac")' >/dev/null 2>&1 || true

# Give the trackpad back before the preferences that record the loan are deleted.
# Taking macOS's three-finger swipe is the one change hyprmac makes outside its own
# files, and leaving it taken after the app is gone is a Mac whose trackpad quietly
# stopped working with nothing left on it to explain why.
echo "==> giving macOS back what was borrowed"
RELEASED="$(defaults read "$BUNDLE" releasedGestures 2>/dev/null | grep -oE 'Trackpad[A-Za-z]+' || true)"
if [ -n "$RELEASED" ]; then
    for key in $RELEASED; do
        for domain in com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad; do
            # Only what is still off — a value the user has since chosen themselves stands.
            current="$(defaults read "$domain" "$key" 2>/dev/null || echo missing)"
            [ "$current" = "0" ] && defaults write "$domain" "$key" -int 2
        done
        say "restored $key"
    done
    echo "   macOS reads this at login, so the swipe comes back when you next log in."
else
    say "nothing was borrowed"
fi

if [ "$PURGE" = 1 ]; then
    echo "==> removing what it wrote"
    keep "$HOME/.config/wisp/hyprmac.conf" config
    keep "$HOME/.config/wisp/session.json" config
    keep "$HOME/.config/wisp/workspace-names.json" config
    keep "$HOME/Library/Logs/hyprmac.log" logs
    keep "$HOME/Library/Logs/hyprmac.log.1" logs
    if defaults read "$BUNDLE" >/dev/null 2>&1; then
        defaults export "$BUNDLE" "$BACKUP/preferences.plist"
        defaults delete "$BUNDLE"
        say "cleared preferences (welcome screen, floated apps)"
        moved=1
    fi
    # The Accessibility grant. Resetting it is the only way to see the permission
    # flow a new user sees; it is granted again by the welcome screen's button.
    if tccutil reset Accessibility "$BUNDLE" >/dev/null 2>&1; then
        say "reset the Accessibility grant"
    else
        say "could not reset the Accessibility grant — remove hyprmac by hand in"
        say "System Settings ▸ Privacy & Security ▸ Accessibility"
    fi
    echo
    echo "Wisper's files in ~/.config/wisp (wisper.conf, dossiers, journal) were not touched."
fi

if [ "$moved" = 1 ]; then
    echo
    echo "Everything removed is in $BACKUP"
    echo "To put it back:"
    echo "  cp -R \"$BACKUP/config/\" ~/.config/wisp/ 2>/dev/null"
    echo "  defaults import $BUNDLE \"$BACKUP/preferences.plist\" 2>/dev/null"
else
    rmdir "$BACKUP" 2>/dev/null || true
fi
echo
echo "==> done. hyprmac is off this Mac."
[ "$PURGE" = 1 ] && echo "    Next launch will behave exactly like a first install."
exit 0
