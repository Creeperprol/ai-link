# session-link

A Claude Code plugin that links several Claude Code sessions on one machine.

- `/sessions`, `/tell <name> <msg>`, `/tellall <msg>`: list and message other sessions
- `/host`: make a session the host; `/assign <name|all> <task>` hands out work, results come back to `/board`
- `/spawn [dir] [-- first task]`: open a new Terminal.app window running `claude` (host only, macOS)
- Side pane ("Sessions"): peers, tasks, and a **Switch to** button that raises another session's Terminal.app window
- Model tools: `assign`, `report`, `rename`, `peers`, `spawn`

Pair it with [session-usage](https://github.com/Creeperprol/session-usage) for the usage side pane.

macOS and Terminal.app only for `/spawn` and Switch. Load it as a Claude Code mod from this folder.
