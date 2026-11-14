#!/bin/bash
# SessionStart hook: warn (into the agent's context) only if something is wrong —
# the notifier is unreachable, the Mac-side listener is older than these hooks, or
# the hook helper cannot run. Also tidies the per-session state and the hook log.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"

resp="$(curl -s --noproxy '*' --max-time 3 -w '\n%{http_code}' "http://localhost:${PORT}/ping" 2>/dev/null)"
code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
if [ "$code" != "200" ]; then
  echo "NOTE: CC round-end notifier is unreachable (localhost:${PORT} -> '${code:-no-response}'). If this is a REMOTE machine, restore the tunnel from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host> 2>/dev/null; ssh -O forward -R ${PORT}:localhost:${PORT} <host>. Verify: $DIR/cc_tunnel_test.sh"
else
  proto=1; case "$body" in *proto=*) proto="${body##*proto=}"; proto="${proto%%[!0-9]*}";; esac
  if [ "${proto:-1}" -lt 2 ]; then
    echo "NOTE: the cc-notifier listener on the Mac is older than the hooks on this machine (protocol ${proto:-1}, need 5). Until it is updated, alarms from different sessions still replace and cancel each other there, and neither the banner nor the phone push shows a session title or summary. Fix: re-run the cc-notifier install.sh on the Mac."
  elif [ "$proto" -lt 3 ]; then
    echo "NOTE: the cc-notifier listener on the Mac is behind the hooks on this machine (protocol ${proto}, need 5). Alarms work, but the phone push carries no session title, summary or message, and every alarm is titled Claude Code whichever agent sent it. Fix: re-run the cc-notifier install.sh on the Mac."
  elif [ "$proto" -lt 4 ]; then
    echo "NOTE: the cc-notifier listener on the Mac is behind the hooks on this machine (protocol ${proto}, need 5). Alarms work, but the phone push carries only the one-sentence summary, not the message itself. Fix: re-run the cc-notifier install.sh on the Mac."
  elif [ "$proto" -lt 5 ]; then
    echo "NOTE: the cc-notifier listener on the Mac is one version behind the hooks on this machine (protocol ${proto}, need 5). Alarms work, but the phone push stops at 3,500 characters of a long message. Fix: re-run the cc-notifier install.sh on the Mac."
  fi
fi

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
if [ "$("$PYBIN" "$HERE/cc_hook.py" check 2>/dev/null)" != "ok" ]; then
  echo "NOTE: cc-notifier's hook helper cannot run ($PYBIN $HERE/cc_hook.py). Round-end notifications fall back to always notifying, with no brief and no per-session cancel."
fi

# Housekeeping: forget sessions idle for two weeks; keep the hook log bounded.
find "$DIR/sessions" -type f -mtime +14 -delete 2>/dev/null
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null | tr -d " ")" -gt 1048576 ] 2>/dev/null; then
  ( umask 077; tail -c 524288 "$LOG" | sed 1d > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG" ) 2>/dev/null
fi
exit 0
