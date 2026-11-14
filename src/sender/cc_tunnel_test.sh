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
if [ "$ec" = 0 ]; then echo "OK   /${ACT} -> ${out}"; exit 0; fi
echo "FAIL /${ACT} -> ${out}"
case "$out" in
  unreachable*|*err=unreachable*|*err=timeout*)
    echo "  nothing answers on localhost:${PORT}. If this is a REMOTE machine, from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host>; ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
  *token=none*|*err=no_token*)
    echo "  no token on this machine ($DIR/token). On your Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>";;
  *listener_auth=none*|*err=listener_has_no_token*)
    echo "  the listener has no token, so it refuses everything. On your Mac: ~/.cc-notifier/cc_token.sh new, then cc_token.sh push <this machine>";;
  *legacy=yes*)
    echo "  the Mac listener is protocol 5: notifications still work, with the old token in a header. Update the Mac (re-run install.sh there), then on the Mac: ~/.cc-notifier/cc_token.sh rotate <this machine>";;
  *verified=no*|*err=unverified*|*http=401*|*http=403*)
    echo "  something answers on localhost:${PORT} but cannot prove it holds this machine's token: the two ends have different tokens (on your Mac: cc_token.sh push <this machine>), or someone else holds the port on this host. Nothing is sent to it.";;
  *err=old_listener*)
    echo "  the listener is older than these hooks (it cannot check signed requests): re-run install.sh on the Mac.";;
esac
exit 1
