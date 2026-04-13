---
name: claude-watch
description: Launch the Agent Watcher bridge so Claude Code / Codex sessions stream to the iPhone, iPad, and Apple Watch app.
author: hanmin
version: 0.2.0
---

# Agent Watcher Bridge

Boot the local Node bridge server that forwards every Claude Code and Codex session to the Agent Watcher mobile / watch app.

## When invoked as `/claude-watch`

Run these steps in order. Stop if any step fails and report the error to the user.

1. **Check if the bridge is already up.**
   `curl -s --connect-timeout 1 http://127.0.0.1:7860/status`
   If it returns JSON, skip to step 5.

2. **Install bridge dependencies if needed.**
   If `skill/bridge/node_modules` is missing, run `./skill/setup.sh`.

3. **Install Claude Code hooks if needed.**
   If `~/.claude/settings.json` does not contain `/hooks/` URLs pointing at `127.0.0.1`, run `./skill/setup-hooks.sh`.
   This also installs `~/.local/bin/claude-watch` and `~/.local/bin/codex-watch`.

4. **Start the bridge.**
   Prefer foreground in a separate terminal so the user sees the pairing banner:
   `node skill/bridge/server.js`
   If you must run it from this session, launch it in the background: `node skill/bridge/server.js > /tmp/agent-watcher.log 2>&1 &` and tail the log for the pairing code.

5. **Report to the user.**
   Tell them:
   - The pairing code, IP, and port printed by the bridge banner.
   - To put `~/.local/bin` on `PATH` if they have not already.
   - To start their agent via `tmux new -s dev && claude-watch` (or `codex-watch`) so the tmux pane is adopted and survives bridge restarts.
   - Alternative: start a new session from the paired iPhone / iPad via the `+` button.

## What this skill installs

- `skill/bridge/server.js` — HTTP + SSE bridge, Bonjour advertiser (`_claude-watch._tcp`), session / tmux / PTY manager.
- `~/.claude/settings.json` hooks — forwards every `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `Notification`, and error event to the bridge.
- `~/.local/bin/claude-watch` — wrapper: registers the terminal (tty + pid + cwd) with the bridge, then `exec claude`.
- `~/.local/bin/codex-watch` — wrapper around `codex`; for `codex-watch exec ...` it also streams `--json` events to the bridge.

## Recommended launch flow

```bash
# Bridge (terminal 1)
node skill/bridge/server.js

# Agent (terminal 2, inside tmux for persistence)
tmux new -s dev
claude-watch        # or codex-watch
```

Or from the phone: tap `+` on the home screen → `New Claude Window` / `New Codex Window`.

## Uninstall

```bash
./skill/setup-hooks.sh --remove    # removes hooks + wrapper binaries
```

## Requirements

- Node.js 18+
- `curl`, `python3` (used by `setup-hooks.sh`)
- Optional: `tmux` for persistent sessions
- Apple Bonjour (built in on macOS) for LAN auto-discovery
