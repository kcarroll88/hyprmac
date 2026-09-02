#!/usr/bin/env bash
# Pack Wisp OS + Wisper for another Mac: both source trees, the installer, and — with
# --personal — your configs, dossiers, journal and voice clip.
#
#   scripts/make-alpha.sh                    → ~/Desktop/wisp-alpha-YYYYMMDD.tar.gz  (~40 MB)
#   scripts/make-alpha.sh --personal         same, plus ~/.config/wisp/* and ~/Wisper/docs
#   scripts/make-alpha.sh --only hyprmac     just the window manager, for a machine that gets no assistant
#   scripts/make-alpha.sh --only wisper      just Wisper
#
# AirDrop it, double-click to unpack, then in Terminal:  cd ~/Downloads/wisp-alpha && ./install.sh
# Not in the tarball: the 9 GB model (the installer downloads it, or copy
# ~/wisp-host-llm/models/Qwen3-14B-Q4_K_M.gguf across yourself and use --no-model).
set -euo pipefail
PERSONAL=0; ONLY=""
while [ $# -gt 0 ]; do case "$1" in
    --personal) PERSONAL=1 ;;
    --only) ONLY="${2:-}"; shift; case "$ONLY" in hyprmac|wisper) ;; *) echo "--only hyprmac|wisper" >&2; exit 2 ;; esac ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
esac; shift; done
STAMP="$(date +%Y%m%d)"
NAME="${ONLY:+$ONLY-alpha}"; NAME="${NAME:-wisp-alpha}"
WORK="$(mktemp -d)"; ROOT="$WORK/$NAME"; OUT="$HOME/Desktop/$NAME-$STAMP.tar.gz"
mkdir -p "$ROOT"
EXCLUDES=(--exclude .build --exclude build --exclude .venv --exclude '*.egg-info' --exclude auditions --exclude .git --exclude .DS_Store)
[ "$ONLY" = wisper ]  || rsync -a "${EXCLUDES[@]}" "$HOME/mac-hyprland/" "$ROOT/mac-hyprland/"
[ "$ONLY" = hyprmac ] || rsync -a "${EXCLUDES[@]}" "$HOME/WisperMac/"    "$ROOT/WisperMac/"
cp "$HOME/mac-hyprland/scripts/install.sh" "$ROOT/install.sh"; chmod +x "$ROOT/install.sh"
if [ "$PERSONAL" = 1 ]; then
    mkdir -p "$ROOT/personal/config" "$ROOT/personal/Wisper-docs"
    for f in hyprmac.conf wisper.conf workspace-names.json voice-reference.wav; do
        [ -f "$HOME/.config/wisp/$f" ] && cp "$HOME/.config/wisp/$f" "$ROOT/personal/config/"
    done
    [ -d "$HOME/Wisper/docs" ] && rsync -a "$HOME/Wisper/docs/" "$ROOT/personal/Wisper-docs/"
fi
if [ "$ONLY" = hyprmac ]; then
cat > "$ROOT/README.md" <<README
# hyprmac — alpha ($STAMP)

A tiling window manager for macOS in the shape of Hyprland. This copy is the window
manager alone — no assistant, no model, nothing leaves the machine.

1. Unpack (double-click) and open Terminal in this folder.
2. \`./install.sh --check\` to see what it will do; \`./install.sh --only hyprmac\` to do it.
   It installs a few Homebrew packages, copies the source to ~/mac-hyprland, makes a free
   signing identity, builds the app, adds it to Login Items, and launches it.
3. Grant Accessibility to hyprmac when macOS asks. \`⌥1\`–\`5\` switch workspaces;
   \`⌥\\\`\` is the overview; the keybinding sheet is in the menu bar.

No personal configuration in this copy: hyprmac writes a default config on first launch
(\`~/.config/wisp/hyprmac.conf\`). Everything else is in \`mac-hyprland/README.md\`.
README
tar -C "$WORK" -czf "$OUT" "$NAME"; rm -rf "$WORK"
printf 'wrote %s (%s) — hyprmac only\n' "$OUT" "$(du -h "$OUT" | cut -f1)"; exit 0
fi
cat > "$ROOT/README.md" <<README
# Wisp OS + Wisper — alpha ($STAMP)

1. Unpack (double-click) and open Terminal in this folder.
2. \`./install.sh --check\` to see what it will do; \`./install.sh\` to do it.
   It installs Homebrew packages (llama.cpp, ffmpeg, uv, jq, w3m, qodem, bat, node; Ghostty,
   Claude Code and Codex), copies the source trees to ~/mac-hyprland and ~/WisperMac, downloads
   the 9 GB model (resumable), makes a signing identity, builds both apps, prepares the speech
   environment, adds both apps to Login Items, and launches them.
3. Grant Accessibility to hyprmac and the microphone to Wisper when macOS asks.

$( [ "$PERSONAL" = 1 ] && echo "This copy carries personal configuration (\`personal/\`): Wisp OS and Wisper settings, workspace names, the voice reference clip, and Wisper's dossiers and journal. Existing files on the target are kept unless \`--force-config\`." || echo "No personal configuration in this copy: Wisp OS writes a default config on first launch; Wisper starts with an empty memory." )

Everything else is in \`mac-hyprland/README.md\` and \`WisperMac/README.md\`.
README
tar -C "$WORK" -czf "$OUT" "$NAME"
rm -rf "$WORK"
printf 'wrote %s (%s)%s\n' "$OUT" "$(du -h "$OUT" | cut -f1)" "$( [ "$PERSONAL" = 1 ] && echo ' — with personal config' )"
