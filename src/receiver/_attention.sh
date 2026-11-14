#!/bin/bash
# Shared engine for the long attention alarms (cc_alarm.sh / cc_ask.sh).
# Caller sources this AFTER setting: SOUND, REPEATS, INTERVAL, TITLE, MSG,
# BUTTON, TIMEOUT. Plays SOUND, REPEATS times, INTERVAL apart, with a persistent
# alert (one button); any click (or /stop) silences it.
#
# The sender says what this is about (through the listener):
#   CC_AGENT  who is notifying (Claude Code, Codex, ...) -> TITLE, set by the caller
#   CC_LABEL  host/project             -> appended to the status line
#   CC_KEY    the machine whose key signed the request (set by the listener, not
#             the sender) -> leads the status line unless it is this Mac's own
#   CC_TITLE  session title            -> the alert's subtitle
#   CC_BRIEF  one-sentence summary of the round, or the question asked -> leads the body
#   CC_BODY_FILE  file with the final message as plain text (line breaks, any length)
#             -> the phone push only; the alert has no room for it
#
# The SOUND is gated by the active macOS Focus (cc_focus.sh): muted in
# Sleep / Do-Not-Disturb, played otherwise. The banner is gated independently by
# the per-app Focus allow-list. CC_SOUND_VIA_ALERTER=1 routes the sound through
# the notification instead of the afplay loop (Apple gates it for free; no loop).
# Optional Telegram push if CC_TELEGRAM_TOKEN + CC_TELEGRAM_CHAT_ID set: the session
# title, then the whole message (cc_telegram.py: as many Telegram messages as it
# takes, the long part folded) or, without one, the summary, then the status line.
# CC_TELEGRAM_BRIEF=0 sends the status line only.
find_bin(){ for p in "$@"; do [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

# Which machine (verified by its key) and session/host finished (?label=... is the sender's word).
case "${CC_KEY:-local}" in
  local) [ -n "${CC_LABEL:-}" ] && MSG="$MSG — $CC_LABEL";;
  *)     MSG="$MSG — ${CC_KEY}${CC_LABEL:+: $CC_LABEL}";;
esac

# --- optional phone push (relayed from THIS Mac; senders like Aurora may block Telegram) ---
if [ -n "${CC_TELEGRAM_TOKEN:-}" ] && [ -n "${CC_TELEGRAM_CHAT_ID:-}" ]; then
  STATUS="${TITLE}: ${MSG}"
  PUSH="$STATUS"
  # Lead with what a phone preview should show: which session, and what happened.
  # That is text from the session; CC_TELEGRAM_BRIEF=0 keeps it on this Mac.
  if [ "${CC_TELEGRAM_BRIEF:-1}" != 0 ]; then
    LEAD="${CC_TITLE:-}"
    [ -n "${CC_BRIEF:-}" ] && LEAD="${LEAD:+$LEAD: }${CC_BRIEF}"
    [ -n "$LEAD" ] && PUSH="${LEAD}
${STATUS}"
  fi
  # The bot token is part of the URL, so curl reads it on stdin, never from its
  # command line (any local user can list those); the text goes in a private file.
  _push(){
    case "$CC_TELEGRAM_TOKEN$CC_TELEGRAM_CHAT_ID" in *[!A-Za-z0-9:@_-]*) return 1;; esac
    _f="$(mktemp "${TMPDIR:-/tmp}/ccpush.XXXXXX")" || return 1
    printf '%s' "$1" > "$_f"
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text@%s"\n' \
        "$CC_TELEGRAM_TOKEN" "$CC_TELEGRAM_CHAT_ID" "$_f" | curl -s --max-time 8 -o /dev/null -w '%{http_code}' --config - 2>/dev/null
    rm -f "$_f"; }
  _PY="$(command -v python3 || echo /usr/bin/python3)"
  # The whole message when there is one; if that does not go out, the short form does.
  ( if [ "${CC_TELEGRAM_BRIEF:-1}" = 0 ] || [ ! -s "${CC_BODY_FILE:-}" ] || \
       ! CC_TELEGRAM_TOKEN="$CC_TELEGRAM_TOKEN" CC_TELEGRAM_CHAT_ID="$CC_TELEGRAM_CHAT_ID" CC_TG_STATUS="$STATUS" \
         CC_TELEGRAM_FOLD_CHARS="${CC_TELEGRAM_FOLD_CHARS:-}" "$_PY" "$HERE/cc_telegram.py"; then
      _push "$PUSH"
    fi ) >/dev/null 2>&1 &
fi

# --- beeps: afplay loop, gated by the active Focus (loop preserved) ---
[ -f "$HERE/cc_focus.sh" ] && . "$HERE/cc_focus.sh"
_BEEP=""
if [ "${CC_SOUND_VIA_ALERTER:-0}" != 1 ]; then
  ( if ! command -v cc_should_play >/dev/null 2>&1 || cc_should_play; then
      for ((i = 1; i <= REPEATS; i++)); do
        afplay "$SOUND"
        [ "$i" -lt "$REPEATS" ] && sleep "$INTERVAL"
      done
    fi ) &
  _BEEP=$!
fi
_stop(){ [ -n "$_BEEP" ] && { kill "$_BEEP" 2>/dev/null; pkill -P "$_BEEP" afplay 2>/dev/null; }; }
_wait(){ [ -n "$_BEEP" ] && wait "$_BEEP" 2>/dev/null; }

# Static hint: the stop hotkey (read from Karabiner) + how it's configured to play.
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
HOTKEY="$("$PYBIN" "$HERE/cc_hotkey.py" 2>/dev/null)"
INFO="auto-off ${TIMEOUT:-60}s · ${REPEATS}x$(basename "${SOUND%.*}")"
[ -n "$HOTKEY" ] && INFO="${HOTKEY} to stop · ${INFO}"
BANNER="$MSG  (${INFO})"
# The brief leads the body; the status line and the hint follow on the next line.
[ -n "${CC_BRIEF:-}" ] && BANNER="${CC_BRIEF}
${BANNER}"

# When routing sound through the notification (escape hatch), attach it.
SND=(); [ "${CC_SOUND_VIA_ALERTER:-0}" = 1 ] && SND=(--sound "$(basename "${SOUND%.*}")")

ALERTER="$(find_bin "$(command -v alerter 2>/dev/null)" /opt/homebrew/bin/alerter /usr/local/bin/alerter)"
TN="$(find_bin "$(command -v terminal-notifier 2>/dev/null)" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier)"
if [ -n "$ALERTER" ]; then
  SUB=(); [ -n "${CC_TITLE:-}" ] && SUB=(--subtitle "$CC_TITLE")
  _t0=$SECONDS
  "$ALERTER" --title "$TITLE" "${SUB[@]}" --message "$BANNER" --actions "${BUTTON:-Stop}" --timeout "${TIMEOUT:-60}" "${SND[@]}" >/dev/null 2>&1
  # An alerter build that rejects --subtitle exits at once with an error: show
  # the alert without it rather than lose the banner and cut the sound.
  if [ $? -ne 0 ] && [ ${#SUB[@]} -gt 0 ] && [ $((SECONDS - _t0)) -lt 2 ]; then
    "$ALERTER" --title "$TITLE" --message "$CC_TITLE — $BANNER" --actions "${BUTTON:-Stop}" --timeout "${TIMEOUT:-60}" "${SND[@]}" >/dev/null 2>&1
  fi
  _stop
elif [ -n "$TN" ]; then
  # terminal-notifier misreads a value that starts with a bracket, quote or dash
  # unless that first character is escaped. One group per session, so alerts from
  # different sessions do not replace each other.
  _tn(){ case "$1" in [\[\(\{\<\"\'-]*) printf '\\%s' "$1";; *) printf '%s' "$1";; esac; }
  SUB=(); [ -n "${CC_TITLE:-}" ] && SUB=(-subtitle "$(_tn "$CC_TITLE")")
  "$TN" -title "$TITLE" "${SUB[@]}" -message "$(_tn "$BANNER")" -group "cc-notifier${CC_SESSION:+-$CC_SESSION}" >/dev/null 2>&1; _wait
else
  osascript -e 'on run a' -e 'display notification (item 1 of a) with title (item 2 of a) subtitle (item 3 of a)' \
    -e 'end run' "$BANNER" "$TITLE" "${CC_TITLE:-}" >/dev/null 2>&1; _wait
fi
