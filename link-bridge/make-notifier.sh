#!/bin/bash
# Build ~/.session-link/ai-link-notifier.app: a copy of terminal-notifier with the Claude Code icon, which ai-link sends its macOS notifications from.
# macOS takes a notification's icon from the sending app's bundle, and terminal-notifier 3.x ignores -appIcon, so a custom icon needs a custom copy.
#
#   make-notifier.sh [ICON.icns]    (default: assets/claude-code.icns next to this folder)
# Needs `brew install terminal-notifier`. After the first run macOS asks to allow notifications for "ai-link"; if they stay off,
# turn them on in System Settings > Notifications > ai-link.
set -euo pipefail
ICON="${1:-$(cd "$(dirname "$0")/.." && pwd)/assets/claude-code.icns}"
SRC="$(brew --prefix terminal-notifier 2>/dev/null)/terminal-notifier.app"
APP="$HOME/.session-link/ai-link-notifier.app"
[ -d "$SRC" ] || { echo "terminal-notifier not found: brew install terminal-notifier" >&2; exit 1; }
[ -f "$ICON" ] || { echo "icon not found: $ICON" >&2; exit 1; }
mkdir -p "$HOME/.session-link"
rm -rf "$APP"
cp -R "$SRC" "$APP"
chmod -R u+w "$APP"
plist="$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist" | sed 's/\.icns$//').icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier fr.julienxx.oss.terminal-notifier.ai-link" -c "Set :CFBundleName ai-link" "$plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open -n "$APP" --args -title ai-link -message "ai-link notifications are on"
echo "$APP"
