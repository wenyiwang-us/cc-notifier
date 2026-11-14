#!/bin/bash
# Self-test the notifier path. Usage: cc_tunnel_test.sh [ping|beep|alarm|ask|stop]
# ping only asks the listener to prove it holds this machine's token (nothing
# rings). alarm/ask carry a sample session, title and summary, so the banner and
# the phone push show the full layout a real round would; stop (no session)
# silences every alarm. Every request is signed (cc_client.py): the token never
# travels and never appears on a command line.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ACT="${1:-ping}"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
export CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR"
case "$ACT" in
  ping)
    out="$("$PYBIN" "$HERE/cc_client.py" ping 2>&1)"; ec=$?;;
  alarm|done|ask)
    out="$(CC_F_LABEL="$(hostname -s 2>/dev/null || echo host)/test" CC_F_SESSION="cc-tunnel-test" \
      CC_F_TITLE="cc-notifier test" CC_F_BRIEF="This is where the one-sentence summary of the round shows." \
      CC_F_BODY="This is where the one-sentence summary of the round shows.

The phone push goes on with the rest of the final message:
• lists stay lists
• tables become lines

and nothing is cut: a long message continues in further Telegram messages." \
      "$PYBIN" "$HERE/cc_client.py" send "$ACT" 2>&1)"; ec=$?;;
  beep|stop)
    out="$("$PYBIN" "$HERE/cc_client.py" send "$ACT" 2>&1)"; ec=$?;;
  *) echo "usage: $0 [ping|beep|alarm|ask|stop]" >&2; exit 2;;
esac
if [ "$ec" = 0 ]; then echo "OK   /${ACT} -> ${out}"; case "$out" in *as=shared*|*auth=shared*) ;; *) exit 0;; esac; else echo "FAIL /${ACT} -> ${out}"; fi
if [ -f "$DIR/cc_alarm_listener.py" ]; then FIX="on this Mac: ~/.cc-notifier/cc_token.sh new"
else FIX="on your Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>"; fi
OR="(or someone else holds port ${PORT} here, posing as the listener)"
if [ "$ec" = 0 ]; then
  echo "  (the listener proves itself, but this machine still uses the key all machines share: $FIX)"; exit 0
fi
case "$out" in
  unreachable*|*err=unreachable*|*err=timeout*)
    echo "  nothing answers on localhost:${PORT}. If this is a REMOTE machine, from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host>; ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
  *no_token*|*bad_key_name*)
    echo "  no usable key on this machine ($DIR/token, $DIR/key-name). Fix, $FIX";;
  *key_unknown_at_listener*)
    echo "  the listener says it has no key under this machine's name on this machine's port (never issued, revoked, or the tunnel ends at the wrong port) $OR. Fix, $FIX";;
  *no_key_for_this_machine*)
    echo "  this machine has no key of its own, and the listener says it no longer takes the shared one $OR. Fix, $FIX";;
  *listener_has_no_token*)
    echo "  the listener says it has no token $OR: re-run install.sh on the Mac.";;
  *legacy=yes*)
    echo "  the Mac listener is protocol 5: notifications still work, with the old token in a header. Update the Mac (re-run install.sh there), then on the Mac: ~/.cc-notifier/cc_token.sh rotate <this machine>";;
  *old_listener*)
    echo "  the listener is older than these hooks: re-run install.sh on the Mac.";;
  *http=429*)
    echo "  the listener took the request but this machine has sent too many in a short time (a burst of 20, then one every 3 s)";;
  *unverified*|*http=401*|*http=403*)
    echo "  something answers on localhost:${PORT} but cannot prove it holds this machine's key: the two ends have different keys ($FIX), or someone else holds the port on this host. Nothing is sent to it.";;
esac
exit "$ec"
