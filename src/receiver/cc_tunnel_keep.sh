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

# Already healthy? Test the real remote->Mac path over the master (no new connection).
ssh "$HOST" "curl -s -o /dev/null --max-time 2 http://localhost:${PORT}/ping" >/dev/null 2>&1 && exit 0

# Broken (forward missing or stale) -> refresh it on the live master.
ssh -O cancel  -R "${PORT}:localhost:${PORT}" "$HOST" >/dev/null 2>&1
ssh -O forward -R "${PORT}:localhost:${PORT}" "$HOST" >/dev/null 2>&1
