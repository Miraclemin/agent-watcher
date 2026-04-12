#!/bin/bash
# Agent Watcher — Install global hooks so ALL Claude Code sessions stream to the bridge.
#
# Usage: ./setup-hooks.sh [port]
#   port: bridge server port (default: 7860)
#
# This writes HTTP hooks to ~/.claude/settings.json (global, all projects).
# To remove: ./setup-hooks.sh --remove

set -e

PORT="${1:-7860}"
BRIDGE_URL="http://127.0.0.1:${PORT}"
SETTINGS="$HOME/.claude/settings.json"

# ── Remove mode ──────────────────────────────────────────────────────────────
if [ "$1" = "--remove" ]; then
  # Remove codex wrapper
  rm -f "$HOME/.local/bin/codex-watch" 2>/dev/null && echo "Removed codex-watch wrapper" || true
  rm -f "$HOME/.local/bin/claude-watch" 2>/dev/null && echo "Removed claude-watch wrapper" || true

  if [ ! -f "$SETTINGS" ]; then
    echo "No settings file found at $SETTINGS"
    exit 0
  fi

  # Remove the hooks we added (identified by claude-watch URLs)
  python3 -c "
import json, sys

with open('$SETTINGS', 'r') as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
changed = False
for event in list(hooks.keys()):
    filtered = [
        entry for entry in hooks[event]
        if not any(
            h.get('url', '').startswith('http://127.0.0.1:') and '/hooks/' in h.get('url', '')
            for h in entry.get('hooks', [])
        )
    ]
    if len(filtered) != len(hooks[event]):
        changed = True
        if filtered:
            hooks[event] = filtered
        else:
            del hooks[event]

if changed:
    if not hooks:
        del settings['hooks']
    with open('$SETTINGS', 'w') as f:
        json.dump(settings, f, indent=2)
    print('Agent Watcher hooks removed from $SETTINGS')
else:
    print('No Agent Watcher hooks found.')
"
  exit 0
fi

# ── Install mode ─────────────────────────────────────────────────────────────

echo "Installing Agent Watcher hooks..."
echo "  Bridge URL: ${BRIDGE_URL}"
echo "  Settings:   ${SETTINGS}"
echo ""

# Verify bridge is reachable
if curl -s --connect-timeout 2 "${BRIDGE_URL}/status" > /dev/null 2>&1; then
  echo "  Bridge status: RUNNING"
else
  echo "  Bridge status: NOT RUNNING (hooks will work once you start the bridge)"
fi

# Create settings file if it doesn't exist
mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

# Merge hooks into existing settings using Python (preserves existing config)
python3 -c "
import json

BRIDGE = '${BRIDGE_URL}'

# The hooks we want to install
new_hooks = {
    'PostToolUse': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/tool-output',
            'timeout': 5
        }]
    }],
    'PreToolUse': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/tool-output',
            'timeout': 5
        }]
    }],
    'PermissionRequest': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/permission',
            'timeout': 600
        }]
    }],
    'Stop': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/stop',
            'timeout': 5
        }]
    }],
    'PostToolUseFailure': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/error',
            'timeout': 5
        }]
    }],
    'StopFailure': [{
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/error',
            'timeout': 5
        }]
    }],
    'Notification': [{
        'matcher': 'idle_prompt|permission_prompt',
        'hooks': [{
            'type': 'http',
            'url': f'{BRIDGE}/hooks/stop',
            'timeout': 5
        }]
    }]
}

with open('$SETTINGS', 'r') as f:
    settings = json.load(f)

existing_hooks = settings.get('hooks', {})

# Merge: add our hooks without removing user's existing hooks
for event, entries in new_hooks.items():
    if event not in existing_hooks:
        existing_hooks[event] = []

    # Remove any old claude-watch hooks for this event
    existing_hooks[event] = [
        entry for entry in existing_hooks[event]
        if not any(
            h.get('url', '').startswith('http://127.0.0.1:') and '/hooks/' in h.get('url', '')
            for h in entry.get('hooks', [])
        )
    ]

    # Add our new hooks
    existing_hooks[event].extend(entries)

settings['hooks'] = existing_hooks

with open('$SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)

print('Hooks installed successfully!')
print()
print('Events hooked:')
for event in new_hooks:
    print(f'  • {event}')
"

echo ""

mkdir -p "$HOME/.local/bin"

# ── Claude wrapper ────────────────────────────────────────────────────────────

if command -v claude &>/dev/null; then
  echo "Claude detected. Installing Claude wrapper..."
  CLAUDE_WRAPPER="$HOME/.local/bin/claude-watch"

  cat > "$CLAUDE_WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
# claude-watch: Runs Claude and pre-registers the current terminal with Agent Watch.
BRIDGE_URL="http://127.0.0.1:${CLAUDE_WATCH_PORT:-7860}"

if curl -s --connect-timeout 1 "${BRIDGE_URL}/status" > /dev/null 2>&1; then
  TTY_PATH="$(tty 2>/dev/null || true)"
  if [ -n "$TTY_PATH" ] && [ "$TTY_PATH" != "not a tty" ]; then
    python3 - <<'PY' "$BRIDGE_URL" "$PWD" "$$" "$TTY_PATH"
import json, sys, urllib.request

bridge_url, cwd, pid, tty = sys.argv[1:5]
payload = json.dumps({
    "source": "claude",
    "cwd": cwd,
    "pid": int(pid),
    "tty": tty,
}).encode("utf-8")

req = urllib.request.Request(
    f"{bridge_url}/hooks/register-terminal",
    data=payload,
    headers={"Content-Type": "application/json"},
)
try:
    urllib.request.urlopen(req, timeout=1)
except Exception:
    pass
PY
  fi
fi

exec claude "$@"
WRAPPER_EOF

  chmod +x "$CLAUDE_WRAPPER"
  echo "  Created: $CLAUDE_WRAPPER"
  echo "  Use 'claude-watch' instead of 'claude' for precise tmux session mapping"
  echo ""
fi

# ── Codex hooks ──────────────────────────────────────────────────────────────

CODEX_CONFIG="$HOME/.codex/config.toml"

if command -v codex &>/dev/null; then
  echo "Codex detected. Installing Codex hooks..."
  mkdir -p "$(dirname "$CODEX_CONFIG")"

  # Codex doesn't have HTTP hooks like Claude Code.
  # Instead, create a wrapper script that pipes --json events to the bridge.
  WRAPPER="$HOME/.local/bin/codex-watch"

  cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
# codex-watch: Runs Codex and streams events to Agent Watcher bridge.
# Drop-in replacement for `codex` — use `codex-watch` instead.
BRIDGE_URL="http://127.0.0.1:${CLAUDE_WATCH_PORT:-7860}"

register_terminal() {
  local agent_pid="$1"
  local tty_path

  if ! curl -s --connect-timeout 1 "${BRIDGE_URL}/status" > /dev/null 2>&1; then
    return 1
  fi

  tty_path="$(tty 2>/dev/null || true)"
  if [ -z "$tty_path" ] || [ "$tty_path" = "not a tty" ]; then
    return 1
  fi

  python3 - <<'PY' "$BRIDGE_URL" "$PWD" "$agent_pid" "$tty_path"
import json, sys, time, urllib.request

bridge_url, cwd, pid, tty = sys.argv[1:5]
payload = json.dumps({
    "source": "codex",
    "cwd": cwd,
    "pid": int(pid),
    "tty": tty,
    "createdAt": int(time.time() * 1000),
}).encode("utf-8")

req = urllib.request.Request(
    f"{bridge_url}/hooks/register-terminal",
    data=payload,
    headers={"Content-Type": "application/json"},
)
try:
    urllib.request.urlopen(req, timeout=1)
except Exception:
    pass
PY
}

# If bridge isn't running, just run codex normally
if ! curl -s --connect-timeout 1 "${BRIDGE_URL}/status" > /dev/null 2>&1; then
  exec codex "$@"
fi

case "$1" in
  exec|e)
    FIFO_PATH="$(mktemp -u "${TMPDIR:-/tmp}/codex-watch.XXXXXX")"
    mkfifo "$FIFO_PATH"
    codex "$@" --json 2>/dev/null > "$FIFO_PATH" &
    CODEX_PID=$!
    register_terminal "$CODEX_PID"
    while IFS= read -r line; do
      TYPE=$(echo "$line" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('type',''))" 2>/dev/null || true)
      case "$TYPE" in
        item.completed)
          # Forward the whole event — let the bridge parse it
          curl -s -X POST "${BRIDGE_URL}/hooks/tool-output" \
            -H "Content-Type: application/json" \
            -d "$(echo "$line" | python3 -c "
import sys,json
e=json.load(sys.stdin)
item=e.get('item',{})
t=item.get('type','')
out={}
if t=='command_execution':
    out={'tool_name':'Bash','tool_input':{'command':item.get('command','')},'tool_output':item.get('aggregated_output',''),'source':'codex'}
elif t in ('file_edit','file_create'):
    out={'tool_name':'Edit','tool_input':{'file_path':item.get('file_path','')},'source':'codex'}
elif t=='file_read':
    out={'tool_name':'Read','tool_input':{'file_path':item.get('file_path','')},'source':'codex'}
elif t=='agent_message':
    out={'tool_name':'CodexMessage','tool_input':{},'tool_output':item.get('text',''),'source':'codex'}
if out:
    print(json.dumps(out))
else:
    print('{}')
" 2>/dev/null)" > /dev/null 2>&1 &
          ;;
        turn.completed)
          curl -s -X POST "${BRIDGE_URL}/hooks/stop" \
            -H "Content-Type: application/json" \
            -d '{"source":"codex"}' > /dev/null 2>&1 &
          ;;
      esac
    done < "$FIFO_PATH"
    wait "$CODEX_PID"
    STATUS=$?
    rm -f "$FIFO_PATH"
    exit "$STATUS"
    ;;
  ""|resume|-*)
    register_terminal "$$"
    exec codex "$@"
    ;;
  *)
    exec codex "$@"
    ;;
esac
WRAPPER_EOF

  chmod +x "$WRAPPER"
  echo "  Created: $WRAPPER"
  echo "  Use 'codex-watch exec \"prompt\"' instead of 'codex exec'"
  echo ""
else
  echo "Codex not detected — skipping Codex hooks."
  echo ""
fi

echo "Done! Sessions will stream to the bridge."
echo ""
echo "Usage:"
echo "  1. Start bridge:  cd skill/bridge && node server.js"
echo "  2. Claude Code:   use 'claude-watch' for precise terminal/session binding"
echo "  3. Codex:         use 'codex-watch exec \"prompt\"' for bridged exec flows"
echo ""
echo "To remove:  ./setup-hooks.sh --remove"
