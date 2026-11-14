#!/bin/bash
# SessionStart hook: warn (into the agent's context) only if something is wrong —
# the notifier is unreachable, the listener cannot prove it holds this machine's
# token (cc_client.py ping), the Mac-side listener is older than these hooks, or
# the hook helper cannot run. Also tidies the per-session state and the hook log.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
res="$(CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" ping 2>/dev/null)"
case "$res" in
  proto=*\ verified=yes*) ;;
  ""|unreachable*)
    echo "NOTE: CC round-end notifier is unreachable (nothing answers on localhost:${PORT}). If this is a REMOTE machine, restore the tunnel from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host> 2>/dev/null; ssh -O forward -R ${PORT}:localhost:${PORT} <host>. Verify: $DIR/cc_tunnel_test.sh";;
  *token=none*)
    echo "NOTE: cc-notifier has no token on this machine ($DIR/token), so it sends nothing. On the Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>.";;
  *legacy=yes*)
    echo "NOTE: the cc-notifier listener on the Mac is protocol 5. Notifications still work, but this machine sends it the token itself (in a header) until the Mac is updated: re-run the cc-notifier install.sh on the Mac, then on the Mac: ~/.cc-notifier/cc_token.sh rotate <ssh alias of this machine>.";;
  *listener_auth=none*)
    echo "NOTE: the cc-notifier listener on the Mac has no token, so it refuses every notification. On the Mac: ~/.cc-notifier/cc_token.sh new, then cc_token.sh push <ssh alias of this machine>.";;
  proto=[0-5]\ *)
    echo "NOTE: the cc-notifier listener on the Mac is older than the hooks on this machine (${res%% *}, need protocol 6, signed requests), so nothing is sent to it. Fix: re-run the cc-notifier install.sh on the Mac. (If the Mac is current, something else answers on localhost:${PORT} here.)";;
  *)
    echo "NOTE: something answers on localhost:${PORT} but cannot prove it holds this machine's cc-notifier token, so nothing is sent to it. Either the two ends have different tokens (on the Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>) or someone else holds that port on this host (then restore the tunnel from the Mac). Check: $DIR/cc_tunnel_test.sh";;
esac

if [ "$("$PYBIN" "$HERE/cc_hook.py" check 2>/dev/null)" != "ok" ]; then
  echo "NOTE: cc-notifier's hook helper cannot run ($PYBIN $HERE/cc_hook.py). Round-end notifications fall back to always notifying, with no brief and no per-session cancel."
fi

# Housekeeping: forget sessions idle for two weeks; keep the hook log bounded.
find "$DIR/sessions" -type f -mtime +14 -delete 2>/dev/null
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null | tr -d " ")" -gt 1048576 ] 2>/dev/null; then
  ( umask 077; tail -c 524288 "$LOG" | sed 1d > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG" ) 2>/dev/null
fi
exit 0
