#!/bin/bash
# Stop hook: notify the Mac when a round finishes. Fire-and-forget.
PORT="${CC_NOTIFY_PORT:-28765}"
MIN="${CC_NOTIFY_MIN_SECONDS:-20}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
ARM_FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
START_FILE="$DIR/turn_start"
if [ "$MIN" -gt 0 ] && [ -f "$START_FILE" ]; then
  start=$(cat "$START_FILE" 2>/dev/null); now=$(date +%s)
  if [ -n "$start" ] && [ $((now - start)) -lt "$MIN" ]; then exit 0; fi
fi
if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi
curl -s --max-time 2 "http://localhost:${PORT}/${act}" >/dev/null 2>&1 &
exit 0
