#!/bin/bash
# Builds hyprmac.app.
#
# A bundle rather than a bare binary because macOS keys the Accessibility grant to
# a code signature, and a loose SwiftPM binary gets a fresh one on every rebuild —
# meaning you would re-approve the WM after every single build.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_DIR:=/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

CONFIG="${1:-release}"
APP="build/hyprmac.app"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --product hyprmac

BIN="$(swift build -c "$CONFIG" --product hyprmac --show-bin-path)/hyprmac"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/hyprmac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a stable Developer ID if one exists: an ad-hoc signature changes every
# build, which silently revokes the Accessibility grant.
# The `|| true` is load-bearing under `set -euo pipefail`: with no identity in the
# keychain grep exits 1, pipefail promotes that to the whole substitution, and a failing
# ASSIGNMENT under `set -e` kills the script — right before the else-branch written to
# handle exactly that case. The bundle then never gets codesigned at all while the log
# reads as a clean success, and `codesign --verify` fails with "code has no resources but
# signature indicates they must be present".
# Preference order: a real Apple identity if one exists, otherwise the local
# self-signed one from scripts/make-signing-cert.sh. Any stable identity will do —
# what breaks the Accessibility grant is the signature *changing*, not who issued it.
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE "\"$1[^\"]*\"" | head -1 | tr -d '"' || true
}
IDENTITY="$(find_identity 'Developer ID Application')"
[ -n "$IDENTITY" ] || IDENTITY="$(find_identity 'Apple Development')"
[ -n "$IDENTITY" ] || IDENTITY="$(find_identity 'Wisp OS Local Signing')"
# The identity from before the rename signs just as well: a stable signature is
# all the Accessibility grant cares about, not the name on it.
[ -n "$IDENTITY" ] || IDENTITY="$(find_identity 'hyprmac Local Signing')"

if [ -n "$IDENTITY" ]; then
    echo "==> signing with: $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "==> signing ad-hoc (no stable identity found)"
    echo "    note: the Accessibility grant will need re-approving after each rebuild."
    echo "    run ./scripts/make-signing-cert.sh once to stop that happening."
    codesign --force --sign - "$APP"
fi

echo "==> done: $APP"
