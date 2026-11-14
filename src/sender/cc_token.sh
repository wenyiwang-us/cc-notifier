#!/bin/bash
# Manage the keys (protocol 7). The Mac's listener keeps one key per machine that
# may send to it (<dir>/keys/<name>) and, for each remote, the port its tunnel ends
# at (<dir>/ports/<name>); each machine keeps its own key in <dir>/token and its
# name in <dir>/key-name. Every request is signed with the key, which is never sent
# anywhere (cc_client.py). A key's name is the ssh alias it was issued to.
#
# Nothing here puts a key on a command line, where any user of a shared host could
# read it (or your shell history keep it): keys move over ssh, on standard input.
#
# On the Mac:
#   cc_token.sh push <host>...    give each ssh host its own key and port (made if it has none), send the key there
#   cc_token.sh rotate <host>...  a new key for each host; other machines are not touched
#   cc_token.sh revoke <host>...  forget a host's key: it can no longer send ("revoke shared": the shared key)
#   cc_token.sh keys              the machines that have a key, with their ports
#   cc_token.sh new               a new key for this Mac's own senders (the stop hotkey, local sessions)
# On a remote:
#   cc_token.sh set <name>        this machine's key, read from standard input, under <name>
#   cc_token.sh off               remove this machine's key: it sends nothing
# Anywhere:
#   cc_token.sh show              this machine's key name and key
# Names are lowercase ssh aliases (letters, digits, . _ -).
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
F="$DIR/token"; N="$DIR/key-name"; KEYS="$DIR/keys"; PORTS="$DIR/ports"
PORT="${CC_NOTIFY_PORT:-28765}"            # this Mac's own port; each remote gets one after it
RPORT="${CC_REMOTE_PORT:-28765}"           # the port the hooks use on a remote (the far end of its tunnel)
TUNNEL_PORTS="${CC_TUNNEL_PORTS:-$(seq $((PORT + 1)) $((PORT + 16)))}"   # the listener binds these, one per remote
HERE="$(cd "$(dirname "$0")" && pwd)"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
umask 077
export LC_ALL=C                            # character sets below mean ASCII, whatever the locale
mkdir -p "$DIR" && chmod 700 "$DIR" 2>/dev/null

# Run on the far end by ssh, through sh whatever the login shell there (no single
# quotes inside); its kit is in its own CC_NOTIFIER_DIR or ~/.cc-notifier.
KIT='d="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"'
remote(){ _rh="$1"; shift; ssh "$_rh" "sh -c '$KIT; $*'"; }
REMOTE_SWITCH='test -s "$d/token.new" && test -s "$d/key-name.new" && mv -f "$d/token.new" "$d/token" && mv -f "$d/key-name.new" "$d/key-name"'
REMOTE_UNSTAGE='rm -f "$d/token.new" "$d/key-name.new"'
REMOTE_VERSION='python3 "$d/cc_client.py" version 2>/dev/null'
REMOTE_PING='python3 "$d/cc_client.py" ping'
REMOTE_NAME='cat "$d/key-name" 2>/dev/null'

usage(){ sed -n '11,22s/^# \{0,1\}//p' "$0" >&2; exit 2; }
say(){ echo "$*" >&2; }
new_key(){ head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }        # 64 hex characters
put(){  # put <file>: standard input becomes <file>, private, all at once
  cat > "$1.tmp.$$" && [ -s "$1.tmp.$$" ] && chmod 600 "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1" \
    || { rm -f "$1.tmp.$$"; return 1; }
}
name_ok(){  # a key name: lowercase letters, digits, . _ - (cc_client.valid_name holds the same rule)
  case "$1" in ""|shared|local|*..*|*.new|*.tmp|*.bak|*.port|*.tmp.*) return 1;; [abcdefghijklmnopqrstuvwxyz0123456789]*) ;; *) return 1;; esac
  case "$1" in *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) return 1;; esac
  [ ${#1} -le 64 ] || return 1
  case "$1" in *[!0123456789abcdef]*) return 0;; esac     # all hex digits: fine if short, refused if it looks like a key
  [ ${#1} -lt 24 ]
}
is_mac(){ [ -f "$DIR/cc_alarm_listener.py" ]; }
need_mac(){ is_mac || { say "keys are issued on the Mac (where the listener runs): run this there"; exit 2; }; }
local_ok(){  # does the listener here prove it holds this Mac's own key (protocol 7)?
  case "$(CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" ping 2>/dev/null)" in
    proto=*\ verified=yes\ as=local\ *) return 0;; *) return 1;;
  esac
}
remote_ready(){  # does <host> run a sender that can use a key of its own (protocol 7)?
  v="$(remote "$1" "$REMOTE_VERSION" 2>/dev/null)"
  case "$v" in [7-9]|[1-9][0-9]) return 0;; *) return 1;; esac
}
port_of(){  # port_of <host>: the Mac port its tunnel ends at, assigned now if it has none
  [ -s "$PORTS/$1" ] && { cat "$PORTS/$1"; return 0; }
  # One assignment at a time (mkdir is atomic): two runs must never hand out one port twice.
  n=0; until mkdir "$PORTS/.lock" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -ge 50 ] && { say "  ports are locked ($PORTS/.lock): another cc_token.sh is running, or remove it"; return 1; }
    sleep 0.1
  done
  rc=1
  for p in $TUNNEL_PORTS; do
    if ! grep -qx "$p" "$PORTS"/* 2>/dev/null; then echo "$p" | put "$PORTS/$1" && echo "$p" && rc=0; break; fi
  done
  rmdir "$PORTS/.lock"; return $rc
}
retarget(){  # point <host>'s live tunnel at <port> (through the ssh master; no new connection)
  ssh -O check "$1" >/dev/null 2>&1 || return 1
  ssh -O cancel -R "$RPORT:localhost:$PORT" "$1" >/dev/null 2>&1
  ssh -O cancel -R "$RPORT:localhost:$2" "$1" >/dev/null 2>&1
  ssh -O forward -R "$RPORT:localhost:$2" "$1" >/dev/null 2>&1
}

# give <host> <rotate:0|1>: stage the key there, then switch both ends, then its tunnel.
give(){
  h="$1"; k="$KEYS/$h"
  other="$(remote "$h" "$REMOTE_NAME" 2>/dev/null)"
  if name_ok "$other" && [ "$other" != "$h" ] && [ -e "$KEYS/$other" ]; then
    say "  $h: its kit already holds the key of $other (the same home, under two names?); not touching it. Use one name for both."
    return 1
  fi
  p="$(port_of "$h")" || { say "  $h: no free port left for it (the listener has $(echo $TUNNEL_PORTS | wc -w | tr -d ' '))"; return 1; }
  if [ "$2" = 1 ] || [ ! -s "$k" ]; then
    new_key | put "$k.new" || { say "  $h: could not write its new key here; nothing changed for $h"; return 1; }
    src="$k.new"
  else src="$k"; fi
  if ! ssh "$h" "sh -c '$KIT; umask 077; mkdir -p \"\$d\" && cat > \"\$d/token.new\" && test -s \"\$d/token.new\" && echo $h > \"\$d/key-name.new\"'" < "$src"; then
    remote "$h" "$REMOTE_UNSTAGE" >/dev/null 2>&1; rm -f "$k.new"
    say "  $h: could not send it the key; nothing changed for $h"; return 1
  fi
  [ "$src" = "$k.new" ] && mv -f "$k.new" "$k"               # from here the listener expects the new key from $h
  if ! remote "$h" "$REMOTE_SWITCH"; then
    say "  $h: the key was sent but $h did not switch to it, so $h cannot send now: run $0 push $h again"; return 1
  fi
  if retarget "$h" "$p"; then moved="its tunnel now ends at port $p"
  else moved="no ssh master for $h right now: its tunnel moves to port $p when you reconnect"; fi
  say "  $h: has its own key; $moved. Keep this under 'Host $h' in ~/.ssh/config (in place of any other RemoteForward $RPORT):"
  say "        RemoteForward $RPORT localhost:$p"
  r="$(remote "$h" "$REMOTE_PING" 2>/dev/null)"
  case "$r" in
    proto=*\ verified=yes\ as="$h"\ *) say "  $h: the listener proves itself to it";;
    *) say "  $h: could not check the listener from there yet (${r:-no answer}): is its tunnel up, and does it end at port $p?";;
  esac
  return 0
}

case "${1:-show}" in
  push|rotate)
    need_mac; what="$1"; shift; [ $# -ge 1 ] || usage
    for h in "$@"; do name_ok "$h" || { say "not a usable name: '$h' (a lowercase ssh alias: letters, digits, . _ -)"; exit 2; }; done
    mkdir -p "$KEYS" "$PORTS" && chmod 700 "$KEYS" "$PORTS"
    local_ok || { say "refusing: the listener here does not take keys of their own yet (protocol 7), or this Mac's own key is broken. Re-run install.sh on this Mac first."; exit 1; }
    for h in "$@"; do
      remote_ready "$h" || { say "refusing: $h has no sender that can use a key of its own (protocol 7), or ssh to it failed. Update cc-notifier there first."; exit 1; }
    done
    failed=0
    for h in "$@"; do give "$h" "$([ "$what" = rotate ] && echo 1 || echo 0)" || failed=1; done
    if [ -e "$KEYS/shared" ]; then
      say "The shared key is still taken on port $PORT, for machines without a key of their own."
      say "Once every remote has its own: $0 revoke shared"
    fi
    [ "$failed" = 0 ] || exit 1 ;;
  revoke)
    need_mac; shift; [ $# -ge 1 ] || usage
    for h in "$@"; do
      case "$h" in
        local) say "not revoking this Mac's own key (the stop hotkey uses it); to replace it: $0 new";;
        shared) if [ -e "$KEYS/shared" ]; then rm -f "$KEYS/shared" && say "retired the shared key: a machine without a key of its own can no longer send"
                else say "the shared key is already retired"; fi;;
        *) if name_ok "$h" && [ -e "$KEYS/$h" ]; then
             rm -f "$KEYS/$h" "$PORTS/$h" && say "revoked $h: its key is no longer taken"
             [ -e "$KEYS/shared" ] && say "  (the shared key is still taken: if $h still has it, it can send with it until: $0 revoke shared)"
           else say "no key for '$h'"; fi;;
      esac
    done ;;
  keys)
    need_mac
    for k in "$KEYS"/*; do
      [ -f "$k" ] || continue
      case "$k" in *.new|*.tmp.*) continue;; esac
      n="${k##*/}"
      case "$n" in
        shared) echo "shared   port $PORT (the key all machines shared before protocol 7: $0 revoke shared retires it)";;
        local)  echo "local    port $PORT (this Mac's own senders)";;
        *)      echo "$n   port $(cat "$PORTS/$n" 2>/dev/null || echo '?')";;
      esac
    done ;;
  new)
    need_mac; mkdir -p "$KEYS" && chmod 700 "$KEYS"
    new_key | put "$KEYS/local.new" || { say "could not write a new key; nothing changed"; exit 1; }
    mv -f "$KEYS/local.new" "$KEYS/local" || { rm -f "$KEYS/local.new"; say "could not write a new key; nothing changed"; exit 1; }
    if cp "$KEYS/local" "$F.tmp.$$" && chmod 600 "$F.tmp.$$" && mv -f "$F.tmp.$$" "$F" && echo local | put "$N"; then
      say "new key for this Mac's own senders ($KEYS/local)"
    else
      rm -f "$F.tmp.$$"; say "the listener has the new key, but this Mac's senders could not get it: run $0 new again"; exit 1
    fi ;;
  set)
    if [ $# -gt 2 ]; then
      say "refusing: a key given on the command line can be read by other users of this host, and stays in your shell history."
      say "Pipe it in instead ($0 set <name> < file), or run '$0 set <name>' and paste it. Better: on the Mac, $0 push <this host>."
      exit 2
    fi
    name="${2:-}"
    if ! name_ok "$name"; then
      case "$name" in *[!0123456789abcdef]*|"") ;; *) [ ${#name} -ge 24 ] && say "refusing: '$0 set' takes this machine's NAME; that looks like a key (and it is now in your shell history: on the Mac, $0 rotate <this host>)"; exit 2;; esac
      say "usage: $0 set <name> (the lowercase name the Mac knows this machine by), the key on standard input"; exit 2
    fi
    if [ -t 0 ]; then printf 'key (not shown): ' >&2; IFS= read -rs t; echo >&2; else IFS= read -r t; fi
    case "$t" in
      ""|*[!A-Za-z0-9._~+/=-]*) say "that does not look like a key (letters, digits and ._~+/=- only); nothing changed"; exit 1;;
    esac
    [ ${#t} -ge 16 ] || { say "too short for a key; nothing changed"; exit 1; }
    [ "$t" != "$name" ] || { say "the name and the key are the same; nothing changed"; exit 1; }
    printf '%s' "$t" | put "$F" && echo "$name" | put "$N" && say "key set for $name ($F)" ;;
  show)
    [ -s "$F" ] || { say "(no key: this machine sends nothing)"; exit 1; }
    echo "name: $(cat "$N" 2>/dev/null || echo 'shared (protocol 6)')"
    echo "key:  $(cat "$F")" ;;
  off)
    if is_mac; then say "not on the Mac: its senders and the stop hotkey need this key (to replace it: $0 new)"; exit 2; fi
    rm -f "$F" "$N"; say "key removed: this machine sends nothing" ;;
  *) usage ;;
esac
