#!/bin/bash
# Stop hook: notify the Mac when a round finishes. Fire-and-forget.
#
# Stands down when Claude Code is merely PAUSED on a background task it will
# auto-resume (not truly done). The Stop payload (CC >= 2.1.145) carries a
# `background_tasks` array listing in-flight work — non-empty means standby — and
# `stop_hook_active` (a forced-continuation loop). Either => stay silent.
# Falls back to notifying if the payload/parser is unavailable (never over-suppresses).
PORT="${CC_NOTIFY_PORT:-28765}"
MIN="${CC_NOTIFY_MIN_SECONDS:-20}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
ARM_FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
START_FILE="$DIR/turn_start"

PAYLOAD="$(cat 2>/dev/null)"
if [ -n "$PAYLOAD" ]; then
  PYBIN="$(command -v python3 || echo /usr/bin/python3)"
  verdict="$(printf '%s' "$PAYLOAD" | "$PYBIN" -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("suppress" if (d.get("background_tasks") or d.get("stop_hook_active")) else "notify")' 2>/dev/null)"
  [ "$verdict" = "suppress" ] && exit 0
fi

# Skip trivial/quick turns.
if [ "$MIN" -gt 0 ] && [ -f "$START_FILE" ]; then
  start=$(cat "$START_FILE" 2>/dev/null); now=$(date +%s)
  if [ -n "$start" ] && [ $((now - start)) -lt "$MIN" ]; then exit 0; fi
fi

if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi
LABEL="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD" 2>/dev/null)"
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
curl -s --max-time 2 "${HDR[@]}" -G --data-urlencode "label=${LABEL}" \
  "http://localhost:${PORT}/${act}" >/dev/null 2>&1 &
exit 0
