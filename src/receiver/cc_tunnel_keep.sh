#!/bin/bash
# Keep the cc-notifier reverse tunnels alive (run periodically by launchd on the Mac).
# It only ever touches EXISTING ssh masters (your shared ControlPath), so:
#   - each forward stays co-located with your VSCode/CC session (right login node), and
#   - NO new ssh connection is opened (nothing for an HPC admin to flag).
# No-op unless CC_TUNNEL_HOST is set in config: your ssh host alias for each remote,
# separated by spaces or commas (CC_TUNNEL_HOST="aurora polaris").
#
# Each tunnel is checked with a proof only this Mac's listener can give, made with
# that host's own key on that host's own port (ports/<host>; the shared key's
# machines end at this Mac's own port). A forward is changed only when that is
# clearly right: nothing listens at the far end (put it back), or the tunnel leads
# to this Mac but to the wrong port (point it at the right one). A busy or silent
# port, or someone else holding it, is left alone and logged: cancelling there
# would hand the port to whoever grabs it first.
export LC_ALL=C                              # character sets below mean ASCII, whatever the locale
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
[ -f "$DIR/config" ] && . "$DIR/config"
PORT="${CC_NOTIFY_PORT:-28765}"             # this Mac's own port
RPORT="${CC_REMOTE_PORT:-28765}"            # the port the hooks use at the far end
HOSTS="$(printf '%s' "${CC_TUNNEL_HOST:-}" | tr ',' ' ')"
[ -n "$HOSTS" ] || exit 0                                # not configured -> off
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
say(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
client(){ CC_NOTIFIER_DIR="$DIR" CC_NOTIFY_PORT="$PORT" "$PYBIN" "$DIR/cc_client.py" "$@"; }

# Without a working key of its own this Mac cannot tell a healthy tunnel from a
# broken one: change nothing.
case "$(client ping 2>/dev/null)" in
  proto=*\ verified=yes\ as=local\ *) ;;
  *) say "this Mac's own key does not work with its listener: run ~/.cc-notifier/cc_token.sh new (no tunnel touched)"; exit 0;;
esac

# probe <host> <query>: the far end's answer to /ping?<query>, then " curl_exit=<n>"
probe(){ ssh "$1" "sh -c 'curl -s --noproxy \"*\" --max-time 2 \"http://localhost:$RPORT/ping?$2\"; echo \" curl_exit=\$?\"'" 2>/dev/null; }
proves(){ printf '%s' "${1% curl_exit=*}" | client verify "$2" >/dev/null 2>&1; }

for HOST in $HOSTS; do
  case "$HOST" in [abcdefghijklmnopqrstuvwxyz0123456789]*) ;; *) say "skipping '$HOST': not a lowercase ssh alias"; continue;; esac
  case "$HOST" in *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) say "skipping '$HOST': not a lowercase ssh alias"; continue;; esac
  ssh -O check "$HOST" >/dev/null 2>&1 || continue      # no live master -> nothing to inject into
  if [ -s "$DIR/keys/$HOST" ] && [ -s "$DIR/ports/$HOST" ]; then want="$(cat "$DIR/ports/$HOST")"; k="$HOST"
  else want="$PORT"; k="local"; fi                      # still on the shared key: ends at this Mac's own port
  q="$(client challenge "$k" 2>/dev/null)" || continue
  out="$(probe "$HOST" "$q")"
  proves "$out" "$q" && continue                         # healthy
  ec="${out##*curl_exit=}"
  case "$ec" in
    7)  # nothing listens at the far end: put the forward back
        ssh -O cancel -R "$RPORT:localhost:$PORT" "$HOST" >/dev/null 2>&1
        ssh -O cancel -R "$RPORT:localhost:$want" "$HOST" >/dev/null 2>&1
        if ! err="$(ssh -O forward -R "$RPORT:localhost:$want" "$HOST" 2>&1)"; then
          say "could not forward port $RPORT on $HOST to $want: $err"
        fi;;
    0)  # something answered, but not with this host's proof: our listener on the wrong port?
        if [ "$want" != "$PORT" ]; then
          q2="$(client challenge local 2>/dev/null)"
          if [ -n "$q2" ] && proves "$(probe "$HOST" "$q2")" "$q2"; then
            ssh -O cancel -R "$RPORT:localhost:$PORT" "$HOST" >/dev/null 2>&1
            ssh -O forward -R "$RPORT:localhost:$want" "$HOST" >/dev/null 2>&1 \
              && say "$HOST: its tunnel led to port $PORT; now to $want (set 'RemoteForward $RPORT localhost:$want' under Host $HOST in ~/.ssh/config)"
            continue
          fi
        fi
        say "$HOST: something answers on port $RPORT there but cannot prove it is this Mac (someone else holds the port, or a relay): nothing is sent to it; left alone";;
    *)  say "$HOST: no clear answer from port $RPORT there (curl exit ${ec:-?}: busy, or the check failed): left alone";;
  esac
done
exit 0
