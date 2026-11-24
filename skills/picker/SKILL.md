---
name: picker
description: Open the AI Link full-screen session picker (3 big tables for agy, Claude, and Codex + tmux windows), or switch/resume/continue any live, past, or tmux session directly from chat. Use when the user invokes /picker or asks to open the session picker, switch sessions, or continue a past or tmux session.
---

# picker

Open the AI Link full-screen session picker for all running, past resumable, and tmux **agy**, **Claude**, and **Codex** sessions — or switch/resume/continue a session directly from chat just like the `picker` terminal command.

## Default action

Match what the user passed after `/picker` and run `picker` (falling back to `picker.sh`) immediately:

- **No arguments (`/picker`)**: open the full-screen 3-table picker window:
  ```bash
  picker -d "$PWD"
  ```
- **Switch to a live session or resume a past/tmux session (`/picker <name|id>`)**:
  ```bash
  picker -d "$PWD" --focus "<name|id>"
  ```
- **Continue the latest session (`/picker continue <claude|codex|agy>`)**:
  ```bash
  picker -d "$PWD" --continue "<cli>"
  ```
- **List all live, past, and tmux sessions (`/picker list`)**:
  ```bash
  picker -d "$PWD" --list
  ```
- **Open/resume inside tmux windows (`/picker --tmux` or `/picker tmux`)**:
  ```bash
  picker -d "$PWD" --tmux
  ```

If `picker` is not in `PATH`, run `"$HOME/Projects/ai-link/link-bridge/picker.sh"` with the same arguments. Report the command's output concisely back to the user.

## Interactive controls inside the picker window

- **Top-left clickable toolbar**: `[+Win]` add tmux window · `[+Split]` horizontal split · `[+VSplit]` vertical split · `[◀]` / `[▶]` resize pane · `[Zoom]` toggle zoom · `[Rename]` rename tmux window · `[×Kill]` close pane
- **Click / `Enter` / `1`–`9`**: switch to a live session, attach a tmux window, or resume a past (`↺`) session
- **`←` / `→` / `Tab`**: jump between **AGY**, **CLAUDE**, **CODEX**, and **TMUX WINDOWS**
- **`↑` / `↓` / `PageUp` / `PageDown`**: scroll sessions
- **`t`**: resume/open the selected session inside a tmux window
- **`n` / `s` / `v` / `[` `]` / `{` `}` / `z` / `m` / `K`**: tmux add window, h-split, v-split, resize width/height, zoom, rename, kill
- **`A` / `C` / `X`**: continue latest agy / Claude / Codex session
- **`a` / `c` / `x`**: open a new agy / Claude / Codex session
- **`p`**: toggle past sessions on/off · **`r`**: refresh · **`q`**: quit
