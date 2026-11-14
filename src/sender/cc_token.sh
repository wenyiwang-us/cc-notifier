#!/bin/bash
# Manage the shared token. The SAME value must be in <dir>/token on the Mac
# (receiver) and on each remote (sender). It is a key: every request is signed
# with it and it never travels (cc_client.py). Without it nothing is sent, and a
# listener without it refuses everything.
#
# Nothing here puts the token on a command line, where any user of a shared host
# could read it (or your shell history keep it): it moves over ssh, on standard input.
#
#   cc_token.sh new               a new random token here (then `push` it to the other ends)
#   cc_token.sh push <host>...    copy this machine's token to each ssh host
#   cc_token.sh rotate <host>...  on the Mac: a new token, copied to each host, then used here
#   cc_token.sh set               read a token from standard input (cc_token.sh set < file)
#   cc_token.sh show              print the token
#   cc_token.sh off               remove the token: nothing is sent, and a listener here refuses everything
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
F="$DIR/token"
HERE="$(cd "$(dirname "$0")" && pwd)"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
umask 077
mkdir -p "$DIR" && chmod 700 "$DIR" 2>/dev/null

# Run on the far end by ssh; its kit is in its own CC_NOTIFIER_DIR or ~/.cc-notifier.
REMOTE_PUT='umask 077; d="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"; mkdir -p "$d" && cat > "$d/token.tmp" && test -s "$d/token.tmp" && mv -f "$d/token.tmp" "$d/token"'
REMOTE_HAS_CLIENT='test -f "${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}/cc_client.py"'
REMOTE_PING='python3 "${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}/cc_client.py" ping'

usage(){ sed -n '9,15s/^# \{0,1\}//p' "$0" >&2; exit 2; }
new_token(){ head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }        # 64 hex characters
put(){  # put <file>: standard input becomes <file>, private, all at once
  cat > "$1.tmp.$$" && [ -s "$1.tmp.$$" ] && chmod 600 "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1" \
    || { rm -f "$1.tmp.$$"; return 1; }
}
push_one(){ ssh "$1" "$REMOTE_PUT" < "$2"; }    # push_one <host> <file>
local_ok(){  # does the listener here take signed requests made with this token?
  case "$(CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" ping 2>/dev/null)" in
    proto=*\ verified=yes*) return 0;; *) return 1;;
  esac
}

case "${1:-show}" in
  new)
    new_token | put "$F" || { echo "could not write $F" >&2; exit 1; }
    echo "new token in $F. The other ends need it too: $0 push <host>..." >&2 ;;
  push)
    shift; [ $# -ge 1 ] || usage
    [ -s "$F" ] || { echo "no token here ($F): make one with '$0 new'" >&2; exit 1; }
    for h in "$@"; do
      if push_one "$h" "$F"; then echo "token copied to $h" >&2
      else echo "could not copy the token to $h" >&2; exit 1; fi
    done ;;
  rotate)
    shift; [ $# -ge 1 ] || usage
    # A protocol-5 listener here could not check the new token's signatures,
    # and an old sender on a host would send the new token itself, in the clear.
    local_ok || { echo "refusing: the listener here does not take signed requests yet. Re-run install.sh on this Mac first." >&2; exit 1; }
    for h in "$@"; do
      ssh "$h" "$REMOTE_HAS_CLIENT" || {
        echo "refusing: $h has no protocol-6 sender (cc_client.py), which would send the new token in the clear. Update cc-notifier there first." >&2; exit 1; }
    done
    new_token | put "$F.new" || { echo "could not write $F.new" >&2; exit 1; }
    for h in "$@"; do
      push_one "$h" "$F.new" || {
        rm -f "$F.new"; echo "could not copy the new token to $h; this Mac keeps the old one, so run rotate again" >&2; exit 1; }
    done
    mv -f "$F.new" "$F"
    echo "new token in use here and on: $*" >&2
    for h in "$@"; do
      r="$(ssh "$h" "$REMOTE_PING" 2>/dev/null)"
      case "$r" in
        proto=*\ verified=yes*) echo "  $h: the listener proves itself to it ($r)" >&2;;
        *) echo "  $h: token copied, but $h could not verify the listener (${r:-no answer}): is its tunnel down?" >&2;;
      esac
    done ;;
  set)
    if [ $# -gt 1 ]; then
      echo "refusing: a token given on the command line can be read by other users of this host, and stays in your shell history." >&2
      echo "Pipe it in instead ($0 set < file), or run '$0 set' and paste it. Better: on the Mac, $0 push <this host>." >&2
      exit 2
    fi
    if [ -t 0 ]; then printf 'token (not shown): ' >&2; IFS= read -rs t; echo >&2; else IFS= read -r t; fi
    case "$t" in
      ""|*[!A-Za-z0-9._~+/=-]*) echo "that does not look like a token (letters, digits and ._~+/=- only); nothing changed" >&2; exit 1;;
    esac
    [ ${#t} -ge 16 ] || { echo "too short for a token; nothing changed" >&2; exit 1; }
    printf '%s' "$t" | put "$F" && echo "token set ($F)" >&2 ;;
  show)
    [ -s "$F" ] && { cat "$F"; echo; } || { echo "(no token: nothing is sent, and a listener here refuses everything)" >&2; exit 1; } ;;
  off)
    rm -f "$F"; echo "token removed: this machine sends nothing, and a listener here refuses everything" >&2 ;;
  *) usage ;;
esac
