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
if [ -f "$DIR/cc_alarm_listener.py" ]; then FIX="this Mac: ~/.cc-notifier/cc_token.sh new"     # the Mac's own senders
else FIX="the Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>"; fi
OR="(or someone else holds port ${PORT} on this host, posing as the listener)"
me="${res##*as=}"; me="${me%% *}"
case "$res" in
  proto=[0-6]\ verified=yes\ as=shared*)
    pv="${res%% *}"
    echo "NOTE: the cc-notifier listener on the Mac is protocol ${pv#proto=}; it works, but every machine still shares one key. Re-run the cc-notifier install.sh on the Mac, then give this machine a key of its own: on the Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>.";;
  proto=*\ verified=yes\ as=shared*)
    echo "NOTE: this machine still uses the cc-notifier key all machines share; it works, but give it a key of its own: on the Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>.";;
  proto=*\ verified=yes*) ;;
  ""|unreachable*)
    echo "NOTE: CC round-end notifier is unreachable (nothing answers on localhost:${PORT}). If this is a REMOTE machine, restore the tunnel from your Mac: ssh -O cancel -R ${PORT}:localhost:<its port> <host> 2>/dev/null; ssh -O forward -R ${PORT}:localhost:<its port> <host> (cc_token.sh keys on the Mac lists the ports). Verify: $DIR/cc_tunnel_test.sh";;
  *why=no_token*)
    echo "NOTE: cc-notifier has no key on this machine ($DIR/token), so it sends nothing. Fix, on $FIX.";;
  *why=bad_key_name*)
    echo "NOTE: cc-notifier cannot use $DIR/key-name (missing, malformed, or it looks like a key), so it sends nothing. Fix, on $FIX.";;
  *legacy=yes*)
    echo "NOTE: the cc-notifier listener on the Mac is protocol 5. Notifications still work, but this machine sends it the token itself (in a header) until the Mac is updated: re-run the cc-notifier install.sh on the Mac, then on the Mac: ~/.cc-notifier/cc_token.sh rotate <ssh alias of this machine>.";;
  *why=key_unknown_at_listener*)
    echo "NOTE: the cc-notifier listener says it has no key named ${me} on this machine's port (never issued, revoked, or the tunnel ends at the wrong port) $OR, so nothing is sent. Fix, on $FIX.";;
  *why=no_key_for_this_machine*)
    echo "NOTE: this machine has no cc-notifier key of its own, and the listener says it no longer takes the shared one $OR, so nothing is sent. Fix, on $FIX.";;
  *why=listener_has_no_token*)
    echo "NOTE: the cc-notifier listener says it has no token $OR, so nothing is sent. Re-run the cc-notifier install.sh on the Mac.";;
  *why=old_listener*)
    echo "NOTE: the cc-notifier listener on the Mac is older than the hooks on this machine (${res%% *}) $OR, so nothing is sent to it. Fix: re-run the cc-notifier install.sh on the Mac.";;
  *)
    echo "NOTE: something answers on localhost:${PORT} but cannot prove it holds this machine's cc-notifier key, so nothing is sent to it. Either the two ends have different keys (fix, on $FIX) or someone else holds that port on this host (then restore the tunnel from the Mac). Check: $DIR/cc_tunnel_test.sh";;
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
