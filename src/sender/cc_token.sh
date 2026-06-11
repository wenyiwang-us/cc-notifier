#!/bin/bash
# Manage the shared auth token. The SAME value must exist on the Mac (receiver)
# and on each remote (sender) at <dir>/token. Without it, anyone who can reach
# the listener port — including other users on a shared login node — can trigger
# or silence your alarms.
#
#   cc_token.sh new          generate a random token here, print it (copy to other machines)
#   cc_token.sh set <value>  set a specific token (use the value printed by `new` on the Mac)
#   cc_token.sh show         print the current token
#   cc_token.sh off          remove the token (auth OFF)
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
F="$DIR/token"
mkdir -p "$DIR"
case "${1:-show}" in
  new)
    t="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "$t" > "$F"; chmod 600 "$F"
    echo "$t"
    echo "(saved to $F — run 'cc_token.sh set $t' on every other machine)" >&2 ;;
  set)
    [ -n "${2:-}" ] || { echo "usage: $0 set <value>" >&2; exit 1; }
    printf '%s' "$2" > "$F"; chmod 600 "$F"; echo "token set ($F)" >&2 ;;
  show)
    [ -f "$F" ] && cat "$F" || { echo "(no token — auth OFF)" >&2; exit 1; } ;;
  off)
    rm -f "$F"; echo "token removed — auth OFF" >&2 ;;
  *) echo "usage: $0 [new|set <value>|show|off]" >&2; exit 1 ;;
esac
