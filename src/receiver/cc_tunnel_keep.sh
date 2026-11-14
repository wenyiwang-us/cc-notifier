#!/bin/bash
# Keep the cc-notifier reverse tunnel alive (run periodically by launchd on the Mac).
# It only ever touches the EXISTING ssh master (your shared ControlPath), so:
#   - the forward stays co-located with your VSCode/CC session (right UAN), and
#   - NO new ssh connection is opened (nothing for an HPC admin to flag).
# No-op unless CC_TUNNEL_HOST (your ssh host alias for the remote) is set in config.
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
[ -f "$DIR/config" ] && . "$DIR/config"
PORT="${CC_NOTIFY_PORT:-28765}"
HOST="${CC_TUNNEL_HOST:-}"

[ -n "$HOST" ] || exit 0                            # not configured -> off
ssh -O check "$HOST" >/dev/null 2>&1 || exit 0      # no live master -> nothing to inject into

# Already healthy? Ask the far end of the tunnel, over the master (no new
# connection), for a proof that only this Mac's listener can give: it holds the
# token. Any other answer - nothing, or someone else listening on that port on a
# shared login node - means the forward has to be put back.
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
c="$(CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$DIR/cc_client.py" challenge 2>/dev/null)"
if [ -n "$c" ] && ssh "$HOST" "curl -s --noproxy '*' --max-time 2 'http://localhost:${PORT}/ping?c=${c}'" 2>/dev/null \
     | CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$DIR/cc_client.py" verify "$c" >/dev/null 2>&1; then
  exit 0
fi

# Broken (forward missing or stale, or the port taken) -> refresh it on the live master.
ssh -O cancel  -R "${PORT}:localhost:${PORT}" "$HOST" >/dev/null 2>&1
if ! err="$(ssh -O forward -R "${PORT}:localhost:${PORT}" "$HOST" 2>&1)"; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) could not forward port ${PORT} on ${HOST}: ${err} (if the port is taken there, someone else holds it: nothing is sent to it)"
fi
