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
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
F=("label=${label}")
[ -n "$agent" ] && F+=("agent=${agent}")
[ -n "$sid" ]   && F+=("session=${sid}")
[ -n "$title" ] && F+=("title=${title}")
[ -n "$brief" ] && F+=("brief=${brief}")
( # The whole message travels as the body of a POST. A listener older than protocol 5
  # (or a curl without --url-query) gets its opening in the query instead.
  proto=0
  if [ -n "$body" ] && [ -s "$body" ] && curl --help all 2>/dev/null | grep -q -- '--url-query'; then
    proto="$(curl -s --noproxy '*' --max-time 2 "http://localhost:${PORT}/ping" 2>/dev/null)"
    case "$proto" in *proto=*) proto="${proto##*proto=}"; proto="${proto%%[!0-9]*}";; *) proto=0;; esac
  fi
  A=()
  if [ "${proto:-0}" -ge 5 ]; then
    for f in "${F[@]}"; do A+=(--url-query "$f"); done
    A+=(-H "Content-Type: text/plain; charset=utf-8" --data-binary "@${body}")
  else
    A=(-G); for f in "${F[@]}"; do A+=(--data-urlencode "$f"); done
    [ -n "$short" ] && [ -s "$short" ] && A+=(--data-urlencode "body@${short}")
  fi
  code="$(curl -s --noproxy '*' --max-time 5 "${HDR[@]}" "${A[@]}" -o /dev/null -w '%{http_code}' \
    "http://localhost:${PORT}/ask" 2>/dev/null)"; ec=$?
  log "sent http=${code} curl_exit=${ec} $info" ) >/dev/null 2>&1 &
exit 0
