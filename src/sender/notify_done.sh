#!/bin/bash
# Stop hook: notify the Mac when a round finishes. Fire-and-forget.
# Usage (as a hook command): notify_done.sh [agent]
# Any agent whose Stop hook hands over a Claude Code style payload can use it;
# `agent` names the caller for the alert (e.g. `codex`; default: read off the payload).
#
# The decision uses only THIS session's payload and state (cc_hook.py):
#   - silent while the session is merely PAUSED on its own background work (the
#     Stop payload's `background_tasks`, CC >= 2.1.145) or in a forced
#     continuation (`stop_hook_active`). Open-ended watches (task type `monitor`,
#     e.g. "live updates for artifact ...") never finish, so they do not count;
#     change the list with CC_NOTIFY_STANDBY_IGNORE.
#   - that hold has limits, so a session is never silent for hours: a pause that
#     outlasts CC_NOTIFY_PAUSE_SECONDS (300) is reported once ("still waiting on
#     ..."), and a task in flight for CC_NOTIFY_LONG_TASK_SECONDS (1800) - a
#     standing watcher, a wait for a queued job - no longer holds anything.
#   - silent for quick turns (< CC_NOTIFY_MIN_SECONDS), timed from this session's
#     own turn start. A stop that completes work an earlier stop left paused is
#     timed from the last prompt a person typed, so the short wrap-up after a
#     long background task still notifies.
# The request names the session (the listener keeps one alarm per session) and
# carries the agent, the session title, a one-sentence summary (the sentence the
# final message opens with) for the alert, and the message itself as plain text,
# whole, for the phone push. It is signed (cc_client.py); the token never travels.
# Falls back to notifying if the payload/helper is unavailable (never over-suppresses).
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ARM_FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"
log(){ ( umask 077; printf '%s done %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" ) 2>/dev/null; }

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
verdict=""; sid=""; title=""; brief=""; info=""; agent=""; label=""; body=""; short=""
if [ "${1:-}" = "--late" ]; then
  # notify_done.sh --late <seconds> <session_id> <seq>: started by cc_hook.py after a
  # stop that background work held back. If the session is still paused when the
  # time is up, say so; if it woke up meanwhile, its own stop decides.
  sleep "$2"
  if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi
  { IFS= read -r verdict; IFS= read -r sid; IFS= read -r title; IFS= read -r brief; IFS= read -r info
    IFS= read -r agent; IFS= read -r label; IFS= read -r body; IFS= read -r short; } \
    < <("$PYBIN" "$HERE/cc_hook.py" late "$act" "$3" "$4" 2>/dev/null)
  [ "$verdict" = "notify" ] || exit 0
else
  if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi
  AGENT="${1:-${CC_NOTIFY_AGENT:-}}"
  PAYLOAD="$(cat 2>/dev/null)"
  if [ -n "$PAYLOAD" ]; then
    { IFS= read -r verdict; IFS= read -r sid; IFS= read -r title; IFS= read -r brief; IFS= read -r info
      IFS= read -r agent; IFS= read -r label; IFS= read -r body; IFS= read -r short; } \
      < <(printf '%s' "$PAYLOAD" | "$PYBIN" "$HERE/cc_hook.py" done "$act" "$AGENT" 2>/dev/null)
  fi
  case "$verdict" in
    silent) log "silent $info"; exit 0;;
    notify) ;;
    *) sid=""; title=""; brief=""; agent="$AGENT"; label=""; body=""; short=""; info="helper-unavailable";;
  esac
fi

[ -n "$label" ] || label="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD" 2>/dev/null)"
# The request goes out through cc_client.py: signed with the token, which never
# travels, and only to a listener that proves it holds the token. The fields go in
# the environment, never on a command line (other users of the host can read those).
( res="$(CC_F_LABEL="$label" CC_F_AGENT="$agent" CC_F_SESSION="$sid" CC_F_TITLE="$title" CC_F_BRIEF="$brief" \
      CC_F_BODY_FILE="$body" CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" send "$act" 2>/dev/null)"
  log "sent act=${act} ${res:-http=000 err=client_failed auth=-} $info" ) >/dev/null 2>&1 &
exit 0
