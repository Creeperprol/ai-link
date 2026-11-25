# AI Remote (Xcode / SwiftUI)

Control your local and LAN `ai-link` sessions (`claude`, `agy`, `codex`) from macOS or iOS.

## 1. Start the LAN & Remote Server on your Mac

```bash
node link-bridge/lan.mjs key    # prints your LAN key (first time only)
node link-bridge/lan.mjs        # starts UDP discovery + HTTP remote API on port 47812 + stuck-worker watchdog
```

## 2. Open in Xcode

Open `ai-remote/AILinkRemote.xcodeproj` in Xcode, choose **My Mac** or your **iPhone/iPad**, and run.

In the app's **Settings** (gear icon):
- **Server URL**: `http://127.0.0.1:47812` (same Mac) or `http://<your-mac-lan-ip>:47812` (from iOS)
- **LAN Key**: the key printed by `node link-bridge/lan.mjs key`
