#!/bin/bash
# Self-test the notifier path. Usage: cc_tunnel_test.sh [ping|beep|alarm|ask|stop]
# alarm/ask carry a sample session, title and summary, so the banner and the
# phone push show the full layout a real round would; stop (no session) silences
# every alarm.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
ACT="${1:-ping}"
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
Q=()
case "$ACT" in alarm|done|ask)
  Q=(-G --data-urlencode "label=$(hostname -s 2>/dev/null || echo host)/test" --data-urlencode "session=cc-tunnel-test"
     --data-urlencode "title=cc-notifier test" --data-urlencode "brief=This is where the one-sentence summary of the round shows."
     --data-urlencode "body=This is where the one-sentence summary of the round shows.

The phone push goes on with the rest of the final message:
• lists stay lists
• tables become lines

up to about 3,000 characters.");;
esac
code=$(curl -s --noproxy '*' --max-time 4 -o /dev/null -w "%{http_code}" "${HDR[@]}" "${Q[@]}" "http://localhost:${PORT}/${ACT}"); ec=$?
if [ "$code" = "200" ]; then echo "OK   /${ACT} -> HTTP 200"; exit 0; fi
echo "FAIL /${ACT} -> HTTP=${code} curl_exit=${ec}"
case "$code" in
  403) echo "  rejected: auth token missing/mismatch. Sync $DIR/token with the Mac (cc_token.sh).";;
esac
case "$ec" in
  7|56) echo "  reachable on this host but not delivering. If REMOTE, from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host>; ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
  28)   echo "  no forward/tunnel. If REMOTE, from your Mac: ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
esac
exit 1
