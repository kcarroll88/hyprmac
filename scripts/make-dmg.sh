#!/usr/bin/env bash
# Build the download: hyprmac.app in a drag-to-Applications disk image.
#
#   scripts/make-dmg.sh                → dist/hyprmac-<version>.dmg, signed with whatever
#                                        identity this Mac has
#   scripts/make-dmg.sh --notarize     same, then submitted to Apple and stapled, so it
#                                        opens with a double-click and no warning
#
# Notarizing needs a Developer ID and credentials stored once:
#   xcrun notarytool store-credentials hyprmac-notary \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Without a Developer ID the image is still made and still works; macOS will say the
# developer cannot be verified, and the download page has to explain the right-click.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=0
CHECK=0
PROFILE="hyprmac-notary"
while [ $# -gt 0 ]; do case "$1" in
    --notarize) NOTARIZE=1 ;;
    --check) CHECK=1 ;;
    --profile) PROFILE="${2:?}"; shift ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
esac; shift; done

find_identity() {
    security find-identity -v -p codesigning 2>/dev/null | grep -oE "\"$1[^\"]*\"" | head -1 | tr -d '"' || true
}

# --check answers one question: is this Mac ready to put out a download that opens
# with a double-click? Everything but the certificate can be true before enrolment
# finishes, so it says which of the four is missing rather than just "no".
if [ "$CHECK" = 1 ]; then
    ready=1
    echo "==> notarization readiness"
    # Read the signature into a variable rather than piping into `grep -q`: grep
    # exits at the first match, codesign takes SIGPIPE, and `set -o pipefail` then
    # reports the whole pipeline as failed. The match becomes a miss, and the check
    # tells you the opposite of the truth.
    signature="$( [ -d build/hyprmac.app ] && codesign -d --verbose=4 build/hyprmac.app 2>&1 || true)"
    if [ -d build/hyprmac.app ] && [ "${signature#*"(runtime)"}" != "$signature" ]; then
        echo "  ok    hardened runtime is on (Apple will not notarize without it)"
    elif [ -d build/hyprmac.app ]; then
        echo "  MISS  hardened runtime is off — scripts/bundle.sh signs with --options runtime"; ready=0
    else
        echo "  --    no build yet; scripts/bundle.sh will sign with --options runtime"
    fi
    if xcrun --find notarytool >/dev/null 2>&1; then echo "  ok    notarytool is installed"
    else echo "  MISS  notarytool missing — install the Command Line Tools"; ready=0; fi
    ID="$(find_identity 'Developer ID Application')"
    if [ -n "$ID" ]; then echo "  ok    certificate: $ID"
    else
        echo "  MISS  no 'Developer ID Application' certificate in this keychain"
        echo "        Once enrolment is confirmed: Xcode ▸ Settings ▸ Accounts ▸ your Apple ID ▸"
        echo "        Manage Certificates ▸ + ▸ Developer ID Application. Then check again."
        ready=0
    fi
    # Ask notarytool, not the keychain. It keeps these in the data-protection
    # keychain, which the `security` tool cannot see at all: looking for a generic
    # password there reports "missing" about credentials that are present and
    # working, and no amount of storing them again will change its mind.
    notary="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1 || true)"
    if ! printf '%s' "$notary" | grep -q "No Keychain password item found"; then
        echo "  ok    notarytool credentials stored as '$PROFILE'"
    else
        echo "  MISS  no stored credentials named '$PROFILE'"
        echo "        Make an app-specific password at appleid.apple.com ▸ Sign-In and Security,"
        echo "        then: xcrun notarytool store-credentials $PROFILE \\"
        echo "                     --apple-id <you@example.com> --team-id <TEAMID> --password <that password>"
        ready=0
    fi
    echo
    if [ "$ready" = 1 ]; then echo "Ready: scripts/make-dmg.sh --notarize"
    else echo "Not ready yet. scripts/make-dmg.sh still builds a working image; macOS will"
         echo "warn about an unidentified developer until the four above are all ok."; fi
    exit 0
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
# Every build carried the same name and the same version, and telling two of them
# apart meant hashing them. A machine three builds behind looked identical to a
# current one — which is exactly how a fixed bug went on being reported. The stamp is
# minutes-resolution UTC: sortable, unambiguous, and visible in Finder without opening
# anything.
BUILD="$(date -u +%Y%m%d-%H%M)"
NAME="hyprmac"
DMG="dist/$NAME-$VERSION-$BUILD.dmg"
VOLUME="$NAME $VERSION"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$STAGE.dmg" 2>/dev/null || true' EXIT

echo "==> building $NAME $VERSION ($BUILD)"
# Stamp it into the bundle too, so the app can say which build it is and the log and
# the setup screen agree with the file name.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
scripts/bundle.sh release >/dev/null

# A Developer ID is what makes the difference between "double-click it" and "macOS
# says this is from an unidentified developer". Prefer it; fall back to whatever is
# here so the image can always be built.
DEVELOPER_ID="$(find_identity 'Developer ID Application')"
if [ -n "$DEVELOPER_ID" ]; then
    # No --deep: there is no nested code in this bundle, and Apple discourages it.
    # --timestamp is not optional for notarization; a signature without a secure
    # timestamp is rejected.
    echo "==> signing the app with: $DEVELOPER_ID"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" build/hyprmac.app
else
    echo "==> no Developer ID on this Mac; the app keeps its local signature"
    [ "$NOTARIZE" = 1 ] && { echo "    (--notarize needs one; stopping)" >&2; exit 1; }
fi
codesign --verify --strict build/hyprmac.app

echo "==> laying out the disk image"
mkdir -p dist "$STAGE/.background"
cp -R build/hyprmac.app "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
scripts/dmg-background.swift "$STAGE/.background/background.png" >/dev/null

# A volume of this name already mounted is not a curiosity, it is a trap: the new
# image mounts as "<name> 1", the Finder script below addresses the disk by name and
# styles the OLD one, and the image ships with no layout at all — which is exactly
# how a perfectly good-looking disk image turned into a plain list of files.
while mount | grep -q "on /Volumes/$VOLUME "; do
    echo "==> unmounting an already-mounted $VOLUME"
    hdiutil detach "/Volumes/$VOLUME" -quiet || { echo "could not unmount /Volumes/$VOLUME — close it and try again" >&2; exit 1; }
    sleep 1
done

rm -f "$DMG" "$STAGE.dmg"
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
               -format UDRW -quiet "$STAGE.dmg"
# Same care as above: take all of hdiutil's output, then pick the mount point out
# of it, rather than letting `head` close the pipe under its feet.
ATTACHED="$(hdiutil attach -readwrite -noverify -noautoopen "$STAGE.dmg")"
MOUNT="$(printf '%s\n' "$ATTACHED" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | sed -n '1p')"
[ -n "$MOUNT" ] || { echo "could not find the mount point in: $ATTACHED" >&2; exit 1; }
# Address the disk by the name it actually got, never by the name asked for.
DISK="$(basename "$MOUNT")"

# Finder does the styling, and it needs permission to be scripted. Best effort: an
# unstyled image still installs perfectly, it just looks like nobody tried.
if ! osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 840, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set background picture of opts to file ".background:background.png"
        set position of item "$NAME.app" of container window to {160, 210}
        set position of item "Applications" of container window to {480, 210}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT
then
    echo "    (Finder would not take the layout — the image is fine, just plain."
    echo "     Grant Terminal permission to control Finder in System Settings ▸ Privacy & Security ▸ Automation.)"
fi

# Styling is what makes this a download rather than a folder, so check it landed
# instead of hoping. Finder writes the window's layout to .DS_Store on the volume.
if [ ! -s "$MOUNT/.DS_Store" ]; then
    echo "    WARNING: Finder wrote no layout — this image will open as a plain file list." >&2
    echo "    Nothing else is wrong with it; the app inside is fine." >&2
fi

chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$STAGE.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet

if [ -n "$DEVELOPER_ID" ]; then
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
fi

if [ "$NOTARIZE" = 1 ]; then
    echo "==> notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "==> stapled; this opens with a plain double-click"
fi

rm -f dist/latest.dmg && ln -s "$(basename "$DMG")" dist/latest.dmg
echo "==> done: $DMG ($(du -h "$DMG" | cut -f1))"
echo "    build $BUILD — the same string is in the app, the log and the setup screen"
[ -z "$DEVELOPER_ID" ] && echo "    unsigned by Apple: first launch needs right-click ▸ Open"
exit 0
