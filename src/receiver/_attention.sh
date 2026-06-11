#!/bin/bash
# Shared engine for the long attention alarms (cc_alarm.sh / cc_ask.sh).
# The caller sources this AFTER setting: SOUND, REPEATS, INTERVAL, TITLE, MSG,
# BUTTON, TIMEOUT. Plays SOUND, REPEATS times, INTERVAL seconds apart, while
# showing a persistent alert with one button; any click (or /stop) silences it.
# Optional phone push via Telegram if CC_TELEGRAM_TOKEN + CC_TELEGRAM_CHAT_ID set.
find_bin(){ for p in "$@"; do [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

# --- optional phone push (relayed from THIS Mac; senders like Aurora may block Telegram) ---
if [ -n "${CC_TELEGRAM_TOKEN:-}" ] && [ -n "${CC_TELEGRAM_CHAT_ID:-}" ]; then
  curl -s --max-time 5 "https://api.telegram.org/bot${CC_TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CC_TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TITLE}: ${MSG}" >/dev/null 2>&1 &
fi

# --- beeps ---
( for ((i = 1; i <= REPEATS; i++)); do
    afplay "$SOUND"
    [ "$i" -lt "$REPEATS" ] && sleep "$INTERVAL"
  done ) &
_BEEP=$!
_stop(){ kill "$_BEEP" 2>/dev/null; pkill -P "$_BEEP" afplay 2>/dev/null; }

# Static hint so you know how long the alert sits + how it's configured to play.
BANNER="$MSG  (auto-off in ${TIMEOUT:-60}s · ${REPEATS}x$(basename "${SOUND%.*}"))"

ALERTER="$(find_bin "$(command -v alerter 2>/dev/null)" /opt/homebrew/bin/alerter /usr/local/bin/alerter)"
TN="$(find_bin "$(command -v terminal-notifier 2>/dev/null)" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier)"
if [ -n "$ALERTER" ]; then
  "$ALERTER" --title "$TITLE" --message "$BANNER" --actions "${BUTTON:-Stop}" --timeout "${TIMEOUT:-60}" >/dev/null 2>&1
  _stop
elif [ -n "$TN" ]; then
  "$TN" -title "$TITLE" -message "$BANNER" -group cc-notifier >/dev/null 2>&1; wait "$_BEEP" 2>/dev/null
else
  osascript -e "display notification \"$BANNER\" with title \"$TITLE\"" >/dev/null 2>&1; wait "$_BEEP" 2>/dev/null
fi
