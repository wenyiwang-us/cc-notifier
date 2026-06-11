#!/bin/bash
# Shared engine for the long attention alarms (cc_alarm.sh / cc_ask.sh).
# The caller sources this AFTER setting: SOUND, REPEATS, INTERVAL, TITLE, MSG,
# BUTTON, TIMEOUT. Plays SOUND, REPEATS times, INTERVAL seconds apart, while
# showing a persistent alert with one button; any click (or /stop) silences it.
find_bin(){ for p in "$@"; do [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

( for ((i = 1; i <= REPEATS; i++)); do
    afplay "$SOUND"
    [ "$i" -lt "$REPEATS" ] && sleep "$INTERVAL"
  done ) &
_BEEP=$!
_stop(){ kill "$_BEEP" 2>/dev/null; pkill -P "$_BEEP" afplay 2>/dev/null; }

ALERTER="$(find_bin "$(command -v alerter 2>/dev/null)" /opt/homebrew/bin/alerter /usr/local/bin/alerter)"
TN="$(find_bin "$(command -v terminal-notifier 2>/dev/null)" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier)"
if [ -n "$ALERTER" ]; then
  "$ALERTER" --title "$TITLE" --message "$MSG" --actions "${BUTTON:-Stop}" --timeout "${TIMEOUT:-60}" >/dev/null 2>&1
  _stop
elif [ -n "$TN" ]; then
  "$TN" -title "$TITLE" -message "$MSG" -group cc-notifier >/dev/null 2>&1; wait "$_BEEP" 2>/dev/null
else
  osascript -e "display notification \"$MSG\" with title \"$TITLE\"" >/dev/null 2>&1; wait "$_BEEP" 2>/dev/null
fi
