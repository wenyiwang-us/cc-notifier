#!/bin/bash
# Instant local stop — bind to a hotkey (Karabiner / Shortcuts: Run Shell Script).
# Silences every alarm. Signed with the token like every request (cc_client.py,
# installed next to this script); the token is never on a command line.
DIR="$(cd "$(dirname "$0")" && pwd)"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
CC_NOTIFIER_DIR="$DIR" CC_NOTIFY_TIMEOUT=2 "$PYBIN" "$DIR/cc_client.py" send stop >/dev/null 2>&1
