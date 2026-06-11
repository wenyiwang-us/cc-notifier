#!/bin/bash
# Self-test the notifier path. Usage: cc_tunnel_test.sh [ping|beep|alarm|ask|stop]
PORT="${CC_NOTIFY_PORT:-28765}"
ACT="${1:-ping}"
code=$(curl -s --max-time 4 -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/${ACT}"); ec=$?
if [ "$code" = "200" ]; then echo "OK   /${ACT} -> HTTP 200"; exit 0; fi
echo "FAIL /${ACT} -> HTTP=${code} curl_exit=${ec}"
case "$ec" in
  7|56) echo "  reachable on this host but not delivering. If REMOTE, from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host>; ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
  28)   echo "  no forward/tunnel. If REMOTE, from your Mac: ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
esac
exit 1
