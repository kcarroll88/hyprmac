#!/bin/bash
# Renders both app icons from the projects' own material and writes the .icns files:
#   hyprmac — the dwindle glyph on the Catppuccin base            → Resources/AppIcon.icns
#   Wisper  — a frame of her resting portrait on the same plate   → ~/WisperMac/Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
: "${DEVELOPER_DIR:=$(xcode-select -p)}"; export DEVELOPER_DIR
swiftc -O -o "$T/makeicon" scripts/icons/makeicon.swift
icns() {  # icns <1024.png> <out.icns>
    local set="$T/$(basename "$2" .icns).iconset"; mkdir -p "$set"
    for s in 16 32 128 256 512; do sips -z $s $s "$1" --out "$set/icon_${s}x${s}.png" >/dev/null; d=$((s*2)); sips -z $d $d "$1" --out "$set/icon_${s}x${s}@2x.png" >/dev/null; done
    iconutil -c icns "$set" -o "$2"; echo "wrote $2"
}
"$T/makeicon" hyprmac "$T/hyprmac.png"; icns "$T/hyprmac.png" Resources/AppIcon.icns
WISPER="${WISPER_DIR:-$HOME/WisperMac}"
if [ -d "$WISPER" ]; then
    ffmpeg -loglevel error -y -ss 0.5 -i "$WISPER/Sources/Wisper/Emotes/idle.mp4" -frames:v 1 "$T/portrait.png"
    "$T/makeicon" wisper "$T/portrait.png" "$T/wisper.png"; icns "$T/wisper.png" "$WISPER/Resources/AppIcon.icns"
fi
