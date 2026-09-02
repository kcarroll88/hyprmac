#!/usr/bin/env bash
# Wisp OS (hyprmac + Wisper) — alpha installer for another Mac.
#
#   ./install.sh                 install everything (asks nothing; idempotent — run it again after fixing anything)
#   ./install.sh --check         say what would happen and what is missing; change nothing
#   ./install.sh --no-model      skip the 9 GB model download (copy it yourself to ~/wisp-host-llm/models/)
#   ./install.sh --no-agents     skip Claude Code and Codex
#   ./install.sh --force-config  overwrite ~/.config/wisp/*.conf with the packaged personal ones
#   ./install.sh --only hyprmac  just the window manager;  --only wisper  just Wisper (they work alone or together — together they are Wisp OS)
#
# Run it from the unpacked wisp-alpha folder. Needs: Apple Silicon, macOS 14+, the Xcode
# Command Line Tools (it asks macOS to install them if they are missing), and Homebrew.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK=0; MODEL=1; AGENTS=1; FORCE=0; ONLY=""
while [ $# -gt 0 ]; do case "$1" in
    --check) CHECK=1;; --no-model) MODEL=0;; --no-agents) AGENTS=0;; --force-config) FORCE=1;;
    --only) ONLY="$2"; shift; [ "$ONLY" = hyprmac ] || [ "$ONLY" = wisper ] || { echo "--only takes hyprmac or wisper" >&2; exit 2; };;
    *) echo "unknown option: $1" >&2; exit 2;;
esac; shift; done
WANT_WM=1; WANT_WISPER=1; [ "$ONLY" = wisper ] && WANT_WM=0; [ "$ONLY" = hyprmac ] && WANT_WISPER=0
# A one-product tarball says what it is by what it carries — no flag needed.
[ -d "$HERE/WisperMac" ]    || WANT_WISPER=0
[ -d "$HERE/mac-hyprland" ] || WANT_WM=0
[ "$WANT_WISPER" = 0 ] && { MODEL=0; AGENTS=0; }
[ "$WANT_WM" = 1 ] || [ "$WANT_WISPER" = 1 ] || { echo "nothing to install here: no mac-hyprland/ or WisperMac/ beside this script" >&2; exit 2; }

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '   \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$CHECK" = 1 ]; then printf '   (would) %s\n' "$*"; else "$@"; fi; }

MODEL_URL="https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf"
MODEL_FILE="$HOME/wisp-host-llm/models/Qwen3-14B-Q4_K_M.gguf"
MODEL_BYTES=9001752960

# ---- 1. the machine -------------------------------------------------------------
say "Checking the machine"
[ "$(uname -m)" = arm64 ] || die "Apple Silicon only (this is $(uname -m))"
ver="$(sw_vers -productVersion)"; [ "${ver%%.*}" -ge 14 ] || die "macOS 14 or newer needed (this is $ver)"
ok "macOS $ver on Apple Silicon"
if ! xcode-select -p >/dev/null 2>&1; then
    warn "the Command Line Tools are missing — macOS will offer to install them now; run this again when it is done"
    [ "$CHECK" = 1 ] || xcode-select --install || true
    exit 1
fi
DEV="$(xcode-select -p)"; ok "toolchain: $DEV ($(swift --version 2>&1 | head -1 | sed 's/.*Apple Swift version \([0-9.]*\).*/Swift \1/'))"
if ! command -v brew >/dev/null 2>&1; then
    die 'Homebrew is missing — install it first:  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
fi
ok "Homebrew at $(brew --prefix)"
[ "$WANT_WM" = 0 ]     || [ -d "$HERE/mac-hyprland" ] || die "mac-hyprland/ is not beside this script — run it from the unpacked folder"
[ "$WANT_WISPER" = 0 ] || [ -d "$HERE/WisperMac" ]    || die "WisperMac/ is not beside this script — run it from the unpacked folder"

# ---- 2. what Homebrew provides ----------------------------------------------------
say "Homebrew packages"
formulas=(); [ "$WANT_WISPER" = 1 ] && formulas=(llama.cpp ffmpeg uv jq w3m qodem bat node)
casks=(ghostty); [ "$AGENTS" = 1 ] && casks+=(claude-code codex)
have_f="$(brew list --formula 2>/dev/null || true)"; have_c="$(brew list --cask 2>/dev/null || true)"
# A package that will not install is a warning, never a stop: everything after this
# step is what actually makes the apps, and it must run. (First alpha: the codex cask
# refused to overwrite a codex already installed by npm, and the script died there.)
for f in ${formulas[@]+"${formulas[@]}"}; do   # empty-array-safe under set -u on bash 3.2
    if grep -qx "$f" <<<"$have_f"; then ok "$f"
    else warn "$f — installing"; run brew install "$f" || warn "$f did not install — carry on; install it by hand later"; fi
done
present() {   # a cask counts as present when the thing it provides is already here
    case "$1" in
        ghostty)     [ -d /Applications/Ghostty.app ] || grep -qx ghostty <<<"$have_c";;
        claude-code) command -v claude >/dev/null 2>&1 || grep -qx claude-code <<<"$have_c";;
        codex)       command -v codex  >/dev/null 2>&1 || grep -qx codex <<<"$have_c";;
        *)           grep -qx "$1" <<<"$have_c";;
    esac
}
for c in "${casks[@]}"; do
    if present "$c"; then ok "$c (already here)"
    else warn "$c — installing"; run brew install --cask "$c" || warn "$c did not install — carry on; install it by hand later"; fi
done

# ---- 3. the source trees ---------------------------------------------------------
say "Source trees → ~/mac-hyprland and ~/WisperMac"
for t in mac-hyprland WisperMac; do
    [ "$t" = WisperMac ] && [ "$WANT_WISPER" = 0 ] && continue
    run rsync -a --exclude .build --exclude build --exclude .venv "$HERE/$t/" "$HOME/$t/"
    ok "$t"
done

# ---- 4. the model ------------------------------------------------------------------
say "The model (Qwen3-14B, Q4_K_M, 9 GB)"
size=0; [ -f "$MODEL_FILE" ] && size="$(stat -f %z "$MODEL_FILE")"
if [ "$size" = "$MODEL_BYTES" ]; then ok "already here: $MODEL_FILE"
elif [ "$WANT_WISPER" = 0 ]; then ok "not needed (hyprmac only)"
elif [ "$MODEL" = 0 ]; then warn "skipped (--no-model); copy it to $MODEL_FILE"
else
    warn "downloading — resumable, so a lost connection just means running this again"
    run mkdir -p "$(dirname "$MODEL_FILE")"
    if [ "$CHECK" = 0 ]; then
        curl -L -C - --progress-bar -o "$MODEL_FILE.part" "$MODEL_URL"
        [ "$(stat -f %z "$MODEL_FILE.part")" = "$MODEL_BYTES" ] || die "download is the wrong size; run again to resume"
        mv "$MODEL_FILE.part" "$MODEL_FILE"; ok "downloaded"
    else printf '   (would) curl -L -C - %s\n' "$MODEL_URL"; fi
fi

# ---- 5. configuration ----------------------------------------------------------------
say "Configuration → ~/.config/wisp"
run mkdir -p "$HOME/.config/wisp" "$HOME/Wisper/docs"
if [ -d "$HERE/personal/config" ]; then
    for f in "$HERE"/personal/config/*; do
        name="$(basename "$f")"
        if [ -e "$HOME/.config/wisp/$name" ] && [ "$FORCE" = 0 ]; then ok "$name kept (yours; --force-config to replace)"
        else run cp "$f" "$HOME/.config/wisp/$name"; ok "$name (personal copy)"; fi
    done
    if [ -d "$HERE/personal/Wisper-docs" ]; then run rsync -a --ignore-existing "$HERE/personal/Wisper-docs/" "$HOME/Wisper/docs/"; ok "dossiers and journal → ~/Wisper/docs (existing files kept)"; fi
else
    ok "Wisp OS writes its own ~/.config/wisp/hyprmac.conf on first launch"
    if [ "$WANT_WISPER" = 0 ]; then :
    elif [ ! -f "$HOME/.config/wisp/wisper.conf" ]; then
        if [ "$CHECK" = 0 ]; then cat > "$HOME/.config/wisp/wisper.conf" <<'CONF'
# Wisper — which model is her brain, and what asks first. See ~/WisperMac/README.md.
brain = local
spec = none
# search_asks = off   # and write_asks, delete_asks, delegate_asks, dial_asks, open_asks — "always" on the bar writes these
CONF
        fi; ok "wisper.conf (default: local brain, everything asks)"
    else ok "wisper.conf kept"; fi
fi

# ---- 6. a signing identity, so the Accessibility grant survives rebuilds ---------------
say "Code signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Local Signing"; then ok "a Local Signing identity is in the keychain"
else warn "making a self-signed identity (one time; keeps macOS from revoking Accessibility on every rebuild)"; run "$HOME/mac-hyprland/scripts/make-signing-cert.sh"; fi

# ---- 7. build both apps ------------------------------------------------------------------
say "Building (a few minutes the first time)"
export DEVELOPER_DIR="$DEV"
if [ "$CHECK" = 0 ]; then
    [ "$WANT_WM" = 1 ] && (cd "$HOME/mac-hyprland" && scripts/bundle.sh) && ok "~/mac-hyprland/build/hyprmac.app"
    [ "$WANT_WISPER" = 1 ] && (cd "$HOME/WisperMac" && scripts/bundle.sh) && ok "~/WisperMac/build/Wisper.app"
else
    built=""; [ "$WANT_WM" = 1 ] && built="hyprmac.app"; [ "$WANT_WISPER" = 1 ] && built="${built:+$built and }Wisper.app"
    printf '   (would) build %s with DEVELOPER_DIR=%s\n' "$built" "$DEV"
fi

# ---- 8. her ears and voice ------------------------------------------------------------------
say "Speech environment (Python 3.12 + MLX; the models arrive on first use, ~2.5 GB)"
if [ "$WANT_WISPER" = 0 ]; then ok "skipped (hyprmac only)"
elif [ "$CHECK" = 0 ]; then (cd "$HOME/WisperMac/speech" && uv sync --python 3.12 >/dev/null) && ok "uv environment ready"; else printf '   (would) uv sync --python 3.12 in ~/WisperMac/speech\n'; fi

# ---- 9. helpers and login --------------------------------------------------------------------
say "Helpers and login items"
apps=(); [ "$WANT_WM" = 1 ] && apps+=("$HOME/mac-hyprland/build/hyprmac.app"); [ "$WANT_WISPER" = 1 ] && apps+=("$HOME/WisperMac/build/Wisper.app")
for app in "${apps[@]}"; do
    name="$(basename "$app" .app)"
    if osascript -e 'tell application "System Events" to get name of every login item' 2>/dev/null | tr ',' '\n' | grep -q "^ *$name$"; then ok "$name starts at login"
    elif [ "$CHECK" = 0 ]; then osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$app\", hidden:false}" >/dev/null && ok "$name will start at login"
    else printf '   (would) add %s to Login Items\n' "$name"; fi
done

# ---- 10. first launch --------------------------------------------------------------------------
say "First launch"
if [ "$CHECK" = 0 ]; then
    [ "$WANT_WM" = 1 ] && open "$HOME/mac-hyprland/build/hyprmac.app"; sleep 2; [ "$WANT_WISPER" = 1 ] && open "$HOME/WisperMac/build/Wisper.app"
fi
if [ "$WANT_WISPER" = 1 ]; then cat <<'NEXT'

   What macOS will ask, and what to do:
   1. Accessibility for hyprmac — System Settings → Privacy & Security → Accessibility → turn on hyprmac,
      then quit and reopen hyprmac once. (Its signing identity is stable now, so this is one time.)
   2. Microphone (and Speech Recognition) for Wisper — allow when asked.
   3. Wisper's first start fetches the speech models (~2.5 GB) in the background: her status bar
      says when the sidecar is ready. The 14B loads in ~10 s on every start.
   4. Agents: run `claude` once in a terminal to log in; `codex` likewise.

   Keys: ⌥Space brings Wisper up and sends her away · tap right ⌃ twice to talk, twice again when done ·
         ⌥1–5 workspaces · ⌥Return a terminal · ⌥/ the cheatsheet.
NEXT
else cat <<'NEXT'

   What macOS will ask: Accessibility for hyprmac — System Settings → Privacy & Security →
   Accessibility → turn on hyprmac, then quit and reopen it once. (One time: the signing
   identity is stable.)

   Keys: ⌥1–5 workspaces · ⌥]/⌥[ step · ⌥` overview · ⌥Return a terminal · ⌥/ the cheatsheet ·
         drag a window onto another to swap, onto its edge to split.
NEXT
fi
[ "$CHECK" = 1 ] && printf '\n   (--check: nothing was changed)\n'
exit 0
