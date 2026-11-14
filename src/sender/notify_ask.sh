#!/bin/bash
# PreToolUse(AskUserQuestion) hook: the agent is asking you a question and is
# BLOCKED waiting. Always notify (no time guard, independent of arm state). The
# request names the session and carries the agent, its title, the question, and
# for the phone push the questions with their choices.
# Usage (as a hook command): notify_ask.sh [agent]     (see notify_done.sh)
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"
log(){ ( umask 077; printf '%s ask %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" ) 2>/dev/null; }

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
AGENT="${1:-${CC_NOTIFY_AGENT:-}}"
verdict=""; sid=""; title=""; brief=""; info=""; agent=""; label=""; body=""; short=""
PAYLOAD="$(cat 2>/dev/null)"
if [ -n "$PAYLOAD" ]; then
  { IFS= read -r verdict; IFS= read -r sid; IFS= read -r title; IFS= read -r brief; IFS= read -r info
    IFS= read -r agent; IFS= read -r label; IFS= read -r body; IFS= read -r short; } \
    < <(printf '%s' "$PAYLOAD" | "$PYBIN" "$HERE/cc_hook.py" ask "$AGENT" 2>/dev/null)
fi
[ "$verdict" = "notify" ] || { sid=""; title=""; brief=""; agent="$AGENT"; label=""; body=""; short=""; info="helper-unavailable"; }

[ -n "$label" ] || label="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD" 2>/dev/null)"
# The request goes out through cc_client.py: signed with the token, which never
# travels, and only to a listener that proves it holds the token. The fields go in
# the environment, never on a command line (other users of the host can read those).
( res="$(CC_F_LABEL="$label" CC_F_AGENT="$agent" CC_F_SESSION="$sid" CC_F_TITLE="$title" CC_F_BRIEF="$brief" \
      CC_F_BODY_FILE="$body" CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" send ask 2>/dev/null)"
  log "sent ${res:-http=000 err=client_failed auth=-} $info" ) >/dev/null 2>&1 &
exit 0
