# session-link

A Claude Code plugin that links several Claude Code sessions on one machine.

- `/sessions`, `/tell <name> <msg>`, `/tellall <msg>`: list and message other sessions
- `/host`: make a session the host; `/assign <name|auto|all> <task>` hands out work (`auto` picks the least-loaded worker), results come back to `/board`
- The host's model is told how to run workers (contract first, even sizing, verify reports); a worker holding a task works silently and reports with its context size
- `/spawn [dir] [-- first task]`: open a new Terminal.app window running `claude` (host only, macOS)
- Side pane ("Sessions"): peers, tasks, and a **Switch to** button that raises another session's Terminal.app window
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
| `/board` | `report` | Results come back here; a worker calls `report` when done |
| `/spawn [dir] [-- task]` | `spawn` | Open a new Terminal.app window running `claude` (host only) |
| `/run <session\|all> /<command>` | `command` | Host runs a slash command in a worker |
| | `rename` | Host renames a worker |

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
