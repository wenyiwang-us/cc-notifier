#!/bin/bash
# Shared engine for the long attention alarms (cc_alarm.sh / cc_ask.sh).
# The caller sources this AFTER setting: SOUND, REPEATS, INTERVAL, TITLE, MSG,
# BUTTON, TIMEOUT. Plays SOUND, REPEATS times, INTERVAL seconds apart, while
# showing a persistent alert with one button; any click (or /stop) silences it.
# Optional phone push via Telegram if CC_TELEGRAM_TOKEN + CC_TELEGRAM_CHAT_ID set.
find_bin(){ for p in "$@"; do [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

# Which session/host finished (passed by the hook via ?label=...).
[ -n "${CC_LABEL:-}" ] && MSG="$MSG — $CC_LABEL"

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

# Static hint: the stop hotkey (read from Karabiner) + how it's configured to play.
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
HOTKEY="$("$PYBIN" "$HERE/cc_hotkey.py" 2>/dev/null)"
INFO="auto-off ${TIMEOUT:-60}s · ${REPEATS}x$(basename "${SOUND%.*}")"
[ -n "$HOTKEY" ] && INFO="${HOTKEY} to stop · ${INFO}"
BANNER="$MSG  (${INFO})"

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
