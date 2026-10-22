# AI Link

*(plugin id: `ai-link`)* A Claude Code plugin that links several Claude Code sessions on one machine. For other CLIs (Codex, Qwen, Antigravity) use the [`link-bridge/`](link-bridge/) MCP server in this repo, which is the other half of AI Link. One-shot helpers there let Claude use Antigravity (`agy-image.sh`, `agy-worker.sh`) and Codex (`codex-agent.sh`) as agents.

- `/sessions`, `/tell <name> <msg>`, `/tellall <msg>`: list and message other sessions
- Loading the `multi-window` skill makes the session the host automatically (a `skill.prompt` hook), unless it is a worker holding a task or another host is still running
- `/host`: make a session the host; `/assign <name|auto|all> <task>` hands out work (`auto` picks the least-loaded worker), results come back to `/board`
- The host's model is told how to run workers (contract first, even sizing, verify reports); a worker holding a task works silently and reports with its context size
- `/spawn [dir] [--model <name>] [--difficulty easy|medium|hard] [--limit <n>] [-- task]`: open a new Terminal.app window running `claude` (host only, macOS). With a task the worker starts on it at once (no join, rename or assign step), silent, and the board binds the task to whoever reports it. `--model` runs the worker on a cheaper model; workers get a 100k auto-compact window and start lean (`--strict-mcp-config --disable-slash-commands`, about 15% cheaper and 32% faster than the full environment in a measured run; the tool's `lean: false` restores the full environment). The tool takes `task`, `model`, `difficulty` and `limit` too. `--difficulty easy|medium|hard` picks haiku, sonnet or opus (an explicit `--model` wins). There is no built-in worker cap: `--limit N` (the `limit` field) caps the workers one task may have at once (running in that folder plus windows opened in the last 15 s that have not joined), set per task by the person; the `maxWorkers` plugin option is an optional hard ceiling
- `spawn` reads `~/.claude.json` first and refuses a folder Claude Code does not trust yet (a window there would hang on the trust prompt); it only reads, never changes trust
- Side pane ("Sessions"): an **Agents** screen (this session's subagents and teammates with status, and a **View** button that opens one's transcript in the main view, **Back to main** returns), peers, tasks, and a **Switch to** button that raises another session's Terminal.app window
- `/run <session|all> /cost`: host runs a slash command in a worker. Only session settings are allowed (compact, clear, cost: commands that open no dialog); the worker obeys only the registered host
- Model tools: `assign`, `report`, `rename`, `command`, `peers`, `spawn`

Pair it with [session-usage](https://github.com/Creeperprol/session-usage) for the usage side pane.

macOS and Terminal.app only for `/spawn` and Switch. Load it as a Claude Code mod from this folder.

## Commands and tools

| Slash command | Model tool | What it does |
| --- | --- | --- |
| `/sessions` | `peers` | List the other sessions |
| `/tell <name> <msg>`, `/tellall <msg>` | | Message one session, or all of them |
| `/host` | | Make this session the host |
| `/assign <name\|auto\|all> <task>` | `assign` | Host hands a task to a worker |
| `/board`, `/board clear` | `report` | Results come back here (`clear` empties the board and messages); a worker calls `report` when done |
| `/spawn [dir] [-- task]` | `spawn` | Open a new Terminal.app window running `claude` (host only) |
| `/run <session\|all> /<command>` | `command` | Host runs a slash command in a worker |
| `/setname <session> <new name>` | `rename` | Host renames a worker |
| `/link` | | Open the Sessions side pane |

`/run` and `command` accept only: compact, clear, cost (commands that open a picker, like /model, would leave the worker stuck on a dialog). Only the registered host may send them.

## Development

Run the tests with:

```
claude plugin test <this folder>
```

It runs every `*.test.ts` and `*.test.tsx` in the folder, each file in its own child process. Each line is `(pass)` or `(fail)` with a test name and time; the tail shows `N pass`, `N fail` and the number of tests run. The exit code is 1 if any test fails.

## Safety

- A worker obeys task, rename and command messages only from the registered host.
- Commands are limited to the allowlist above: commands that open no dialog, nothing that runs code, edits files or changes permissions.
- Destructive commands are refused while a task is unfinished.

## link-bridge (the cross-CLI half)

[`link-bridge/`](link-bridge/) is a dependency-free MCP server (Node 18+) that lets Claude Code, Codex, Qwen Code and the Antigravity CLI (`agy`) find each other, message each other and hand out work, plus one-shot helpers for using `agy` and Codex as agents. It does not need this plugin and this plugin does not need it; they keep separate registries (this plugin pushes messages between Claude sessions, the bridge is pull-based).

```
claude mcp add link --scope user -e LINK_CLI=claude -- node /path/to/ai-link/link-bridge/server.mjs
agy mcp add --env LINK_CLI=agy link "$(command -v node)" /path/to/ai-link/link-bridge/server.mjs
```

See [`link-bridge/README.md`](link-bridge/README.md) for the tools, the Antigravity and Codex notes (permissions, folder trust, quota) and the helpers `agy-worker.sh`, `agy-image.sh` and `codex-agent.sh`. Its tests: `node --test link-bridge/test.mjs`.

