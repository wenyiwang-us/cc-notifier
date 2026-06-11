#!/bin/bash
# Instant local stop — bind to a hotkey (Karabiner / Shortcuts: Run Shell Script).
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="$(cd "$(dirname "$0")" && pwd)"
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
curl -s --max-time 2 "${HDR[@]}" "http://localhost:${PORT}/stop" >/dev/null 2>&1
