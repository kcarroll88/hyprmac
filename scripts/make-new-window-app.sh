#!/bin/bash
# Builds a tiny launcher app so Spotlight can open a NEW window of an app,
# instead of refocusing one you already have.
#
#   ./scripts/make-new-window-app.sh Ghostty
#   ./scripts/make-new-window-app.sh Safari applescript
#
# The wrapper is named "<App> New Window" so the app name leads: typing "ghostty"
# into Spotlight surfaces it alongside the real app, rather than hiding behind a
# "New ..." prefix nobody starts a search with.
#
# `open -a Foo` means "activate Foo" — macOS hands you an existing window. The two
# ways around it are not equally good:
#
#   menu         Clicks the app's own File > New Window, the way you would. Reuses
#                the running instance, so one process and one Dock icon. Works for
#                anything with that menu item. Needs Automation permission once.
#   applescript  Asks a scriptable app for another window (Safari, Finder, Mail).
#   open         `open -na` launches a whole SECOND instance. Avoid: every call
#                leaves another process and another Dock icon behind, and apps
#                that expect to be alone will fight over one profile.
set -euo pipefail

TARGET="${1:?usage: make-new-window-app.sh <target app> [applescript|open] [wrapper name]}"
MODE="${2:-menu}"
APP_NAME="${3:-$TARGET New Window}"
DEST="$HOME/Applications/$APP_NAME.app"

TARGET_APP=""
for dir in /Applications /System/Applications "$HOME/Applications"; do
    [ -d "$dir/$TARGET.app" ] && TARGET_APP="$dir/$TARGET.app" && break
done
[ -n "$TARGET_APP" ] || { echo "cannot find $TARGET.app" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"

case "$MODE" in
applescript)
    cat > "$DEST/Contents/MacOS/launch" <<EOF
#!/bin/sh
osascript -e 'tell application "$TARGET" to make new document' >/dev/null 2>&1 \
    || open -a "$TARGET"
exec osascript -e 'tell application "$TARGET" to activate'
EOF
    ;;
open)
    cat > "$DEST/Contents/MacOS/launch" <<EOF
#!/bin/sh
exec open -na "$TARGET"
EOF
    ;;
*)
    # Launching an app that is not running already gives you a window; only ask
    # for an extra one when it is already up, or you get two.
    cat > "$DEST/Contents/MacOS/launch" <<EOF
#!/bin/sh
TARGET="$TARGET"
if [ "\$(osascript -e "application \"\$TARGET\" is running" 2>/dev/null)" != "true" ]; then
    exec open -a "\$TARGET"
fi
osascript -e "tell application \"\$TARGET\" to activate" >/dev/null 2>&1
osascript -e "tell application \"System Events\" to tell process \"\$TARGET\" to click menu item \"New Window\" of menu 1 of menu bar item \"File\" of menu bar 1" >/dev/null 2>&1 \
    || osascript -e "tell application \"System Events\" to keystroke \"n\" using command down" >/dev/null 2>&1
EOF
    ;;
esac
chmod +x "$DEST/Contents/MacOS/launch"

BUNDLE_ID="dev.keenancarroll.newwindow.$(echo "$TARGET" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
cat > "$DEST/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>launch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleIconFile</key><string>icon</string>
    <!-- Required before macOS will even ASK to let this send Apple Events.
         Without it the request is refused silently and the launcher no-ops. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>$APP_NAME opens a new $TARGET window by using $TARGET's own File menu.</string>
    <!-- It launches the real app and exits; no Dock icon, no bounce. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# The icon is rarely named after the app, so read it out of the target's plist.
ICON_NAME="$(defaults read "$TARGET_APP/Contents/Info" CFBundleIconFile 2>/dev/null || true)"
ICON="$TARGET_APP/Contents/Resources/${ICON_NAME%.icns}.icns"
[ -f "$ICON" ] || ICON="$(find "$TARGET_APP/Contents/Resources" -maxdepth 1 -name '*.icns' | head -1)"
[ -n "$ICON" ] && [ -f "$ICON" ] && cp "$ICON" "$DEST/Contents/Resources/icon.icns"

codesign --force --sign - "$DEST" 2>/dev/null || true
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" 2>/dev/null || true

echo "created: $DEST  (mode: $MODE)"
