#!/bin/bash
# Build the notifier apps ai-link sends its macOS notifications from: copies of terminal-notifier, each with an agent's logo.
# macOS takes a notification's icon from the sending app's bundle, and terminal-notifier 3.x ignores -appIcon, so a custom icon needs a custom copy.
#
#   make-notifier.sh [claude|codex|agy|all]     (default: all)
#     claude -> ~/.session-link/ai-link-notifier.app  (Claude Code mascot, shown as "ai-link")
#     codex  -> ~/.session-link/ai-link-codex.app     (Codex logo,         shown as "Codex")
#     agy    -> ~/.session-link/ai-link-agy.app       (Antigravity logo,   shown as "Antigravity")
# Logos are assets/*.png next to this folder. Needs `brew install terminal-notifier`. The first run of each app makes macOS ask to
# allow notifications; if they stay off, turn them on in System Settings > Notifications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$(brew --prefix terminal-notifier 2>/dev/null)/terminal-notifier.app"
[ -d "$SRC" ] || { echo "terminal-notifier not found: brew install terminal-notifier" >&2; exit 1; }
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# make <app dir name> <bundle id suffix> <display name> <logo png>
make() {
  local app="$HOME/.session-link/$1.app" png="$ROOT/assets/$4" tmp; tmp="$(mktemp -d)"
  [ -f "$png" ] || { echo "logo not found: $png" >&2; return 1; }
  mkdir -p "$tmp/i.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$png" --out "$tmp/i.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$png" --out "$tmp/i.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/i.iconset" -o "$tmp/i.icns"
  rm -rf "$app"; mkdir -p "$HOME/.session-link"
  cp -R "$SRC" "$app"; chmod -R u+w "$app"
  local plist="$app/Contents/Info.plist"
  cp "$tmp/i.icns" "$app/Contents/Resources/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist" | sed 's/\.icns$//').icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier fr.julienxx.oss.terminal-notifier.$2" -c "Set :CFBundleName $3" "$plist"
  codesign --force --deep --sign - "$app" >/dev/null 2>&1
  "$LS" -f "$app"
  open -n "$app" --args -title "$3" -message "ai-link notifications are on"
  rm -rf "$tmp"
  echo "$app"
}

case "${1:-all}" in
  claude) make ai-link-notifier ai-link ai-link claude-code.png ;;
  codex) make ai-link-codex ai-link-codex Codex codex.png ;;
  agy) make ai-link-agy ai-link-agy Antigravity antigravity.png ;;
  all) make ai-link-notifier ai-link ai-link claude-code.png; make ai-link-codex ai-link-codex Codex codex.png; make ai-link-agy ai-link-agy Antigravity antigravity.png ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
