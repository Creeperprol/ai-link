# AI Remote (Xcode / SwiftUI)

Control your `ai-link` sessions (`claude`, `agy`, `codex`) from macOS or iOS, from anywhere, through a Cloudflare Worker relay.

```
AI Remote app  <->  Cloudflare Worker (ai-remote/cloud)  <->  link-bridge/cloud-agent.mjs on your Mac
```

## 1. Deploy the relay (once)

```bash
cd ai-remote/cloud
KEY=$(openssl rand -hex 24)
printf %s "$KEY" | npx wrangler secret put KEY
npx wrangler deploy                      # prints https://ai-link-relay.<you>.workers.dev
printf '{"url":"https://ai-link-relay.<you>.workers.dev","key":"%s"}\n' "$KEY" > ~/.ai-link/cloud.json
chmod 600 ~/.ai-link/cloud.json
```

## 2. Run the agent on your Mac

```bash
node link-bridge/cloud-agent.mjs
```

It pushes your sessions every 3 s and runs the prompts, nudges and spawns the app queues. Sessions need a tmux pane (or a Terminal.app tab) to receive text; viewing a pane needs tmux.

## 3. Open the app

Open `AILinkRemote.xcodeproj`, run on **My Mac** or your iPhone, then in **Settings** set the server URL and access key from `~/.ai-link/cloud.json`. On a phone you can tap a pairing link instead: `ailink://pair?url=<relay url>&key=<key>`. To build the app already paired, create the gitignored `AILinkRemote/Local.xcconfig` with `AILINK_CLOUD_URL = https:/$()/<relay host>` and `AILINK_CLOUD_KEY = <key>`; it replaces saved settings that are empty, localhost or the old Supabase relay.

Debug builds accept a `-mock` launch argument that shows sample sessions.

The key is the only protection on the relay: keep `cloud.json` private and never commit it.
