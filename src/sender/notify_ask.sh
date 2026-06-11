#!/bin/bash
# PreToolUse(AskUserQuestion) hook: CC is asking you a question and is BLOCKED
# waiting. Always notify (no time guard, independent of arm state).
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
LABEL="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD" 2>/dev/null)"
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
curl -s --max-time 2 "${HDR[@]}" -G --data-urlencode "label=${LABEL}" \
  "http://localhost:${PORT}/ask" >/dev/null 2>&1 &
exit 0
