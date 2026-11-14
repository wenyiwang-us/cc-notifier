#!/bin/bash
# Diagnose the whole cc-notifier chain. Run on either end (it adapts to the OS).
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
PORT="${CC_NOTIFY_PORT:-28765}"
OS="$(uname -s)"
g='\033[32m'; r='\033[31m'; y='\033[33m'; z='\033[0m'
ok(){   printf "  ${g}OK${z}  %s\n" "$*"; }
bad(){  printf "  ${r}XX${z}  %s\n" "$*"; }
warn(){ printf "  ${y}??${z}  %s\n" "$*"; }
note(){ printf "  ..  %s\n" "$*"; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
hc(){ curl -s --noproxy '*' --max-time 4 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }
# Asks the listener to prove it holds this machine's token; sends nothing else and
# rings nothing. The token never travels and never appears on a command line.
ping_out="$(CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" ping 2>/dev/null)"
if [ -f "$DIR/cc_alarm_listener.py" ]; then FIX="on this Mac: cc_token.sh new"; else FIX="on the Mac: cc_token.sh push <this host>"; fi

printf "cc-notifier doctor — %s (%s)\n" "$(uname -n)" "$OS"

# --- listener reachable (on a remote this also proves the tunnel) ---
code="$(hc "http://localhost:${PORT}/ping")"
if [ "$code" = 200 ]; then ok "listener reachable on localhost:${PORT}"
else bad "listener NOT reachable (HTTP ${code:-none})"
  if [ "$OS" = Darwin ]; then note "fix: launchctl load ~/Library/LaunchAgents/com.ccnotifier.listener.plist"
  else note "fix (tunnel down): from your Mac  ssh -O forward -R ${PORT}:localhost:${PORT} <host>"; fi
fi

# --- listener version + auth (signed requests; the listener proves it holds the token) ---
if [ "$code" = 200 ]; then
  case "$ping_out" in
    proto=*\ verified=yes\ as=shared*) warn "listener holds the key all machines share (${ping_out%% *}); requests are signed, but give this machine its own key — on the Mac: cc_token.sh push <this host>";;
    proto=*\ verified=yes*) ok "listener is current and holds this machine's own key (${ping_out%% why=*}): requests are signed, the key never travels";;
    *legacy=yes*) warn "listener is protocol 5: it still gets the old token in a header — re-run install.sh on the Mac, then there: cc_token.sh rotate <this host>";;
    *why=no_token*|*why=bad_key_name*) bad "no usable key on this machine ($DIR/token, $DIR/key-name): nothing is sent — $FIX";;
    *why=key_unknown_at_listener*|*why=no_key_for_this_machine*) bad "the listener takes no key from this machine on this port (${ping_out##*why=}; or someone else holds port ${PORT} here): nothing is sent — $FIX";;
    *why=listener_has_no_token*) bad "the listener has no token, so it refuses everything — re-run install.sh on the Mac";;
    *why=old_listener*) bad "listener is older than these hooks (${ping_out%% *}), so nothing is sent to it — re-run install.sh on the Mac";;
    *) bad "the listener cannot prove it holds this machine's key (${ping_out:-no answer}): the keys differ (on the Mac: cc_token.sh push <this host>) or someone else holds port ${PORT} here — nothing is sent to it";;
  esac
fi
[ "$("$PYBIN" "$DIR/cc_hook.py" check 2>/dev/null)" = "ok" ] && ok "hook helper runs ($PYBIN cc_hook.py)" \
  || bad "hook helper cannot run ($PYBIN $DIR/cc_hook.py) — hooks fall back to always notifying, no brief"
n="$(find "$DIR/sessions" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
note "per-session state: ${n} session(s) in $DIR/sessions; decisions are logged in $DIR/hook.log"

# --- keys the listener takes (Mac) ---
if [ -d "$DIR/keys" ]; then
  note "keys the listener takes (cc_token.sh keys): $("$DIR/cc_token.sh" keys 2>/dev/null | awk '{printf "%s=%s ", $1, $3}')"
  [ -e "$DIR/keys/shared" ] && warn "the key all machines shared before is still taken on port ${PORT} — give each remote its own (cc_token.sh push <host>...), then: cc_token.sh revoke shared"
fi

# --- private files: the keys, the config (Telegram bot token), the message texts ---
for f in "$DIR" "$DIR/token" "$DIR/key-name" "$DIR/keys" "$DIR"/keys/* "$DIR/ports" "$DIR/config" "$DIR/sessions" "$DIR/tmp" "$DIR/listener.log" "$DIR/tunnel.log"; do
  [ -e "$f" ] || continue
  m="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)"
  case "$m" in 700|600|500|400) ;; *) bad "$f is readable by others (mode $m) — chmod go= $f";; esac
done

# --- arm + hooks ---
[ -f "$DIR/armed" ] && note "armed (long alarm)" || note "disarmed (short chime)"
S="$HOME/.claude/settings.json"
if command -v python3 >/dev/null 2>&1 && [ -f "$S" ]; then
  n="$(python3 -c "import json;d=json.load(open('$S'));print(sum('/.cc-notifier/' in h.get('command','') for e in d.get('hooks',{}).values() for grp in e for h in grp.get('hooks',[])))" 2>/dev/null)"
  [ "${n:-0}" -ge 4 ] && ok "CC hooks wired (${n}/4 in user settings)" \
                      || warn "CC hooks: ${n:-0}/4 in $S — run install.sh, then restart CC"
fi
if [ -d "${CODEX_HOME:-$HOME/.codex}" ] && [ -x "$DIR/cc_codex_hooks.sh" ]; then
  if st="$("$DIR/cc_codex_hooks.sh" status 2>/dev/null)"; then ok "$st (Codex runs them once you have reviewed them there)"
  else note "${st:-Codex hooks: not readable} — for round-end notifications from Codex: $DIR/cc_codex_hooks.sh on"; fi
fi

# --- receiver-only checks ---
if [ "$OS" = Darwin ]; then
  c4="$(hc -4 "http://localhost:${PORT}/ping")"; c6="$(hc -6 "http://localhost:${PORT}/ping")"
  { [ "$c4" = 200 ] && [ "$c6" = 200 ]; } && ok "listening on both IPv4 + IPv6 loopback" \
                                          || warn "loopback v4=$c4 v6=$c6 — ssh may forward to the missing family"
  if command -v alerter >/dev/null 2>&1 || [ -x /opt/homebrew/bin/alerter ] || [ -x /usr/local/bin/alerter ]
    then ok "alerter installed"; else bad "alerter missing -> brew install vjeantet/tap/alerter"; fi
  hk="$(python3 "$DIR/cc_hotkey.py" 2>/dev/null)"
  [ -n "$hk" ] && ok "Karabiner stop hotkey: $hk" \
               || warn "no Karabiner stop rule found — enable it in Karabiner › Complex Modifications"
  launchctl list 2>/dev/null | grep -q ccnotifier && ok "launchd listener agent loaded" \
                                                   || warn "launchd agent not loaded (launchctl load …com.ccnotifier.listener.plist)"
  ( [ -f "$DIR/config" ] && . "$DIR/config"
    if [ -n "${CC_TELEGRAM_TOKEN:-}" ] && [ -n "${CC_TELEGRAM_CHAT_ID:-}" ]; then
      # The bot token is part of the URL: curl reads it on stdin, not from its command line.
      printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$CC_TELEGRAM_TOKEN" | curl -s --max-time 6 --config - \
        | grep -q '"ok":true' && ok "Telegram bot reachable + token valid" || warn "Telegram configured but getMe failed (token/network)"
    else note "Telegram push not configured (optional)"; fi )
  note "alerter notification permission + Focus allow-list can't be checked here — verify by running: $DIR/cc_tunnel_test.sh alarm"
else
  note "run doctor on your Mac too for receiver checks (alerter, Karabiner, launchd, Telegram)"
fi
