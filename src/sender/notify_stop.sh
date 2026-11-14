#!/bin/bash
# UserPromptSubmit hook: start THIS session's turn clock and, when a person typed
# the prompt, cancel the alarm this session raised. Other sessions are untouched.
# Usage (as a hook command): notify_stop.sh [agent]     (see notify_done.sh)
#
# Agents also fire this hook for their own messages (a subagent's turn; in Claude
# Code a finished background task, a hand-back, a scheduled wake-up). Those never
# cancel an alarm and never restart the clock of a turn that is already running
# (cc_hook.py).
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"
log(){ ( umask 077; printf '%s prompt %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" ) 2>/dev/null; }

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
verdict=""; sid=""; info=""
PAYLOAD="$(cat 2>/dev/null)"
if [ -n "$PAYLOAD" ]; then
  { IFS= read -r verdict; IFS= read -r sid; IFS= read -r info; } \
    < <(printf '%s' "$PAYLOAD" | "$PYBIN" "$HERE/cc_hook.py" prompt "${1:-${CC_NOTIFY_AGENT:-}}" 2>/dev/null)
fi
case "$verdict" in
  cancel)
    # Signed, like every request (cc_client.py); the session id goes in the environment.
    ( res="$(CC_F_SESSION="$sid" CC_NOTIFY_TIMEOUT=2 CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" \
          "$PYBIN" "$HERE/cc_client.py" send stop 2>/dev/null)"
      log "cancel ${res:-http=000 err=client_failed auth=-} $info" ) >/dev/null 2>&1 &
    ;;
  keep) log "keep $info";;
  # No session to act for: leave every alarm alone rather than cancel someone else's.
  *)    log "keep helper-unavailable";;
esac
exit 0
