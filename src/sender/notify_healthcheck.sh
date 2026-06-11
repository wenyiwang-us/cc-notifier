#!/bin/bash
# SessionStart hook: warn (into CC context) only if the notifier is unreachable.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
code=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/ping" 2>/dev/null)
if [ "$code" != "200" ]; then
  echo "NOTE: CC round-end notifier is unreachable (localhost:${PORT} -> '${code:-no-response}'). If this is a REMOTE machine, restore the tunnel from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host> 2>/dev/null; ssh -O forward -R ${PORT}:localhost:${PORT} <host>. Verify: $DIR/cc_tunnel_test.sh"
fi
exit 0
