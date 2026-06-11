#!/bin/bash
# UserPromptSubmit hook: record turn start + cancel any active alarm.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
mkdir -p "$DIR"; date +%s > "$DIR/turn_start" 2>/dev/null
curl -s --max-time 2 "http://localhost:${PORT}/stop" >/dev/null 2>&1 &
exit 0
