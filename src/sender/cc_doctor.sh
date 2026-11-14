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
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
hc(){ curl -s --noproxy '*' --max-time 4 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }

printf "cc-notifier doctor — %s (%s)\n" "$(uname -n)" "$OS"

# --- listener reachable (on a remote this also proves the tunnel) ---
code="$(hc "http://localhost:${PORT}/ping")"
if [ "$code" = 200 ]; then ok "listener reachable on localhost:${PORT}"
else bad "listener NOT reachable (HTTP ${code:-none})"
  if [ "$OS" = Darwin ]; then note "fix: launchctl load ~/Library/LaunchAgents/com.ccnotifier.listener.plist"
  else note "fix (tunnel down): from your Mac  ssh -O forward -R ${PORT}:localhost:${PORT} <host>"; fi
fi

# --- listener version + hook helper (per-session alarms, session title, brief) ---
if [ "$code" = 200 ]; then
  body="$(curl -s --noproxy '*' --max-time 4 "http://localhost:${PORT}/ping" 2>/dev/null)"
  proto=1; case "$body" in *proto=*) proto="${body##*proto=}"; proto="${proto%%[!0-9]*}";; esac
  if   [ "${proto:-1}" -ge 5 ]; then ok "listener is current (protocol ${proto}): one alarm per session, agent name, summary in the alert, the whole message in the phone push"
  elif [ "${proto:-1}" -ge 4 ]; then warn "listener is one version behind these hooks (protocol ${proto}, need 5): the phone push stops at 3,500 characters — re-run install.sh on the Mac"
  elif [ "${proto:-1}" -ge 3 ]; then warn "listener is behind these hooks (protocol ${proto}, need 5): the phone push carries only the one-sentence summary — re-run install.sh on the Mac"
  elif [ "${proto:-1}" -ge 2 ]; then warn "listener is behind these hooks (protocol ${proto}, need 5): no summary in the phone push, every alarm titled Claude Code — re-run install.sh on the Mac"
  else warn "listener is older than these hooks (protocol ${proto:-1}, need 5): one shared alarm, no title/summary — re-run install.sh on the Mac"; fi
fi
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
[ "$("$PYBIN" "$DIR/cc_hook.py" check 2>/dev/null)" = "ok" ] && ok "hook helper runs ($PYBIN cc_hook.py)" \
  || bad "hook helper cannot run ($PYBIN $DIR/cc_hook.py) — hooks fall back to always notifying, no brief"
n="$(find "$DIR/sessions" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
note "per-session state: ${n} session(s) in $DIR/sessions; decisions are logged in $DIR/hook.log"

# --- auth ---
if [ -f "$DIR/token" ]; then
  sc="$(hc "${HDR[@]}" "http://localhost:${PORT}/stop")"
  [ "$sc" = 200 ] && ok "auth token accepted by listener" \
                  || warn "token present but listener returned ${sc} — tokens differ between ends? (cc_token.sh)"
else
  warn "auth OFF (no $DIR/token). On a shared host others can reach the port. Enable: cc_token.sh new"
fi

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
      curl -s --max-time 6 "https://api.telegram.org/bot${CC_TELEGRAM_TOKEN}/getMe" | grep -q '"ok":true' \
        && ok "Telegram bot reachable + token valid" || warn "Telegram configured but getMe failed (token/network)"
    else note "Telegram push not configured (optional)"; fi )
  note "alerter notification permission + Focus allow-list can't be checked here — verify by running: $DIR/cc_tunnel_test.sh alarm"
else
  note "run doctor on your Mac too for receiver checks (alerter, Karabiner, launchd, Telegram)"
fi
