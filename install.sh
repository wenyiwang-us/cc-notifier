#!/usr/bin/env bash
# cc-notifier — self-contained installer. GENERATED from src/ by build.sh.
# Do not edit by hand; edit src/ and run ./build.sh.
#
#   bash install.sh            # auto-detect role from the OS
#   bash install.sh receiver   # force the Mac receiver role
#   bash install.sh sender     # force the CC-side sender role
#   bash install.sh --port 28765
#   bash install.sh --uninstall
#
# receiver (macOS): listener (launchd) + alerter + sounds + stop kit + local hooks.
# sender   (Linux): hooks into ~/.claude/settings.json; remote senders reach the
#                   Mac via an ssh RemoteForward. Notifies on round-complete (Stop)
#                   and on questions (AskUserQuestion).
set -euo pipefail

PORT=28765
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
SETTINGS="${CC_NOTIFIER_SETTINGS:-$HOME/.claude/settings.json}"
ROLE=""
UNINSTALL=0
OS="$(uname -s)"

while [ $# -gt 0 ]; do
  case "$1" in
    receiver|sender) ROLE="$1"; shift;;
    --port) PORT="$2"; shift 2;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -n "$ROLE" ] || case "$OS" in
  Darwin) ROLE="receiver";;
  Linux)  ROLE="sender";;
  *) echo "unsupported OS: $OS" >&2; exit 1;;
esac

log(){ printf '  %s\n' "$*"; }
hdr(){ printf '\n== %s ==\n' "$*"; }

write_sender(){
  mkdir -p "$DIR"
  cat > "$DIR/cc_doctor.sh" <<'CCN_EOF_cc_doctor_sh'
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
hc(){ curl -s --max-time 4 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }

printf "cc-notifier doctor — %s (%s)\n" "$(uname -n)" "$OS"

# --- listener reachable (on a remote this also proves the tunnel) ---
code="$(hc "http://localhost:${PORT}/ping")"
if [ "$code" = 200 ]; then ok "listener reachable on localhost:${PORT}"
else bad "listener NOT reachable (HTTP ${code:-none})"
  if [ "$OS" = Darwin ]; then note "fix: launchctl load ~/Library/LaunchAgents/com.ccnotifier.listener.plist"
  else note "fix (tunnel down): from your Mac  ssh -O forward -R ${PORT}:localhost:${PORT} <host>"; fi
fi

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
CCN_EOF_cc_doctor_sh
  cat > "$DIR/cc_notify_arm.sh" <<'CCN_EOF_cc_notify_arm_sh'
#!/bin/bash
# Arm/disarm the round-end notifier. Flag persists across reboots ($DIR/armed).
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
case "${1:-status}" in
  on|arm)     mkdir -p "$DIR"; : > "$FLAG"; echo "ARMED — long alarm at round end";;
  off|disarm) rm -f "$FLAG"; echo "DISARMED — short chime at round end";;
  status)     [ -f "$FLAG" ] && echo "ARMED (long alarm)" || echo "DISARMED (short chime)";;
  *) echo "usage: $0 [on|off|status]"; exit 1;;
esac
CCN_EOF_cc_notify_arm_sh
  cat > "$DIR/cc_token.sh" <<'CCN_EOF_cc_token_sh'
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
CCN_EOF_cc_token_sh
  cat > "$DIR/cc_tunnel_test.sh" <<'CCN_EOF_cc_tunnel_test_sh'
#!/bin/bash
# Self-test the notifier path. Usage: cc_tunnel_test.sh [ping|beep|alarm|ask|stop]
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
ACT="${1:-ping}"
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
code=$(curl -s --max-time 4 -o /dev/null -w "%{http_code}" "${HDR[@]}" "http://localhost:${PORT}/${ACT}"); ec=$?
if [ "$code" = "200" ]; then echo "OK   /${ACT} -> HTTP 200"; exit 0; fi
echo "FAIL /${ACT} -> HTTP=${code} curl_exit=${ec}"
case "$code" in
  403) echo "  rejected: auth token missing/mismatch. Sync $DIR/token with the Mac (cc_token.sh).";;
esac
case "$ec" in
  7|56) echo "  reachable on this host but not delivering. If REMOTE, from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host>; ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
  28)   echo "  no forward/tunnel. If REMOTE, from your Mac: ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
esac
exit 1
CCN_EOF_cc_tunnel_test_sh
  cat > "$DIR/notify_ask.sh" <<'CCN_EOF_notify_ask_sh'
#!/bin/bash
# PreToolUse(AskUserQuestion) hook: CC is asking you a question and is BLOCKED
# waiting. Always notify (no time guard, independent of arm state).
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
LABEL="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD" 2>/dev/null)"
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
curl -s --max-time 2 "${HDR[@]}" -G --data-urlencode "label=${LABEL}" \
  "http://localhost:${PORT}/ask" >/dev/null 2>&1 &
exit 0
CCN_EOF_notify_ask_sh
  cat > "$DIR/notify_done.sh" <<'CCN_EOF_notify_done_sh'
#!/bin/bash
# Stop hook: notify the Mac when a round finishes. Fire-and-forget.
#
# Stands down when Claude Code is merely PAUSED on a background task it will
# auto-resume (not truly done). The Stop payload (CC >= 2.1.145) carries a
# `background_tasks` array listing in-flight work — non-empty means standby — and
# `stop_hook_active` (a forced-continuation loop). Either => stay silent.
# Falls back to notifying if the payload/parser is unavailable (never over-suppresses).
PORT="${CC_NOTIFY_PORT:-28765}"
MIN="${CC_NOTIFY_MIN_SECONDS:-20}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
ARM_FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
START_FILE="$DIR/turn_start"

PAYLOAD="$(cat 2>/dev/null)"
if [ -n "$PAYLOAD" ]; then
  PYBIN="$(command -v python3 || echo /usr/bin/python3)"
  verdict="$(printf '%s' "$PAYLOAD" | "$PYBIN" -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("suppress" if (d.get("background_tasks") or d.get("stop_hook_active")) else "notify")' 2>/dev/null)"
  [ "$verdict" = "suppress" ] && exit 0
fi

# Skip trivial/quick turns.
if [ "$MIN" -gt 0 ] && [ -f "$START_FILE" ]; then
  start=$(cat "$START_FILE" 2>/dev/null); now=$(date +%s)
  if [ -n "$start" ] && [ $((now - start)) -lt "$MIN" ]; then exit 0; fi
fi

if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi
LABEL="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD" 2>/dev/null)"
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
curl -s --max-time 2 "${HDR[@]}" -G --data-urlencode "label=${LABEL}" \
  "http://localhost:${PORT}/${act}" >/dev/null 2>&1 &
exit 0
CCN_EOF_notify_done_sh
  cat > "$DIR/notify_healthcheck.sh" <<'CCN_EOF_notify_healthcheck_sh'
#!/bin/bash
# SessionStart hook: warn (into CC context) only if the notifier is unreachable.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
code=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/ping" 2>/dev/null)
if [ "$code" != "200" ]; then
  echo "NOTE: CC round-end notifier is unreachable (localhost:${PORT} -> '${code:-no-response}'). If this is a REMOTE machine, restore the tunnel from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host> 2>/dev/null; ssh -O forward -R ${PORT}:localhost:${PORT} <host>. Verify: $DIR/cc_tunnel_test.sh"
fi
exit 0
CCN_EOF_notify_healthcheck_sh
  cat > "$DIR/notify_stop.sh" <<'CCN_EOF_notify_stop_sh'
#!/bin/bash
# UserPromptSubmit hook: record turn start + cancel any active alarm.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
mkdir -p "$DIR"; date +%s > "$DIR/turn_start" 2>/dev/null
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
curl -s --max-time 2 "${HDR[@]}" "http://localhost:${PORT}/stop" >/dev/null 2>&1 &
exit 0
CCN_EOF_notify_stop_sh
  chmod +x "$DIR"/*.sh "$DIR"/*.py 2>/dev/null || true
}
write_receiver(){
  mkdir -p "$DIR"
  cat > "$DIR/_attention.sh" <<'CCN_EOF__attention_sh'
#!/bin/bash
# Shared engine for the long attention alarms (cc_alarm.sh / cc_ask.sh).
# Caller sources this AFTER setting: SOUND, REPEATS, INTERVAL, TITLE, MSG,
# BUTTON, TIMEOUT. Plays SOUND, REPEATS times, INTERVAL apart, with a persistent
# alert (one button); any click (or /stop) silences it.
#
# The SOUND is gated by the active macOS Focus (cc_focus.sh): muted in
# Sleep / Do-Not-Disturb, played otherwise. The banner is gated independently by
# the per-app Focus allow-list. CC_SOUND_VIA_ALERTER=1 routes the sound through
# the notification instead of the afplay loop (Apple gates it for free; no loop).
# Optional Telegram push if CC_TELEGRAM_TOKEN + CC_TELEGRAM_CHAT_ID set.
find_bin(){ for p in "$@"; do [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

# Which session/host finished (passed by the hook via ?label=...).
[ -n "${CC_LABEL:-}" ] && MSG="$MSG — $CC_LABEL"

# --- optional phone push (relayed from THIS Mac; senders like Aurora may block Telegram) ---
if [ -n "${CC_TELEGRAM_TOKEN:-}" ] && [ -n "${CC_TELEGRAM_CHAT_ID:-}" ]; then
  curl -s --max-time 5 "https://api.telegram.org/bot${CC_TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CC_TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${TITLE}: ${MSG}" >/dev/null 2>&1 &
fi

# --- beeps: afplay loop, gated by the active Focus (loop preserved) ---
[ -f "$HERE/cc_focus.sh" ] && . "$HERE/cc_focus.sh"
_BEEP=""
if [ "${CC_SOUND_VIA_ALERTER:-0}" != 1 ]; then
  ( if ! command -v cc_should_play >/dev/null 2>&1 || cc_should_play; then
      for ((i = 1; i <= REPEATS; i++)); do
        afplay "$SOUND"
        [ "$i" -lt "$REPEATS" ] && sleep "$INTERVAL"
      done
    fi ) &
  _BEEP=$!
fi
_stop(){ [ -n "$_BEEP" ] && { kill "$_BEEP" 2>/dev/null; pkill -P "$_BEEP" afplay 2>/dev/null; }; }
_wait(){ [ -n "$_BEEP" ] && wait "$_BEEP" 2>/dev/null; }

# Static hint: the stop hotkey (read from Karabiner) + how it's configured to play.
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
HOTKEY="$("$PYBIN" "$HERE/cc_hotkey.py" 2>/dev/null)"
INFO="auto-off ${TIMEOUT:-60}s · ${REPEATS}x$(basename "${SOUND%.*}")"
[ -n "$HOTKEY" ] && INFO="${HOTKEY} to stop · ${INFO}"
BANNER="$MSG  (${INFO})"

# When routing sound through the notification (escape hatch), attach it.
SND=(); [ "${CC_SOUND_VIA_ALERTER:-0}" = 1 ] && SND=(--sound "$(basename "${SOUND%.*}")")

ALERTER="$(find_bin "$(command -v alerter 2>/dev/null)" /opt/homebrew/bin/alerter /usr/local/bin/alerter)"
TN="$(find_bin "$(command -v terminal-notifier 2>/dev/null)" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier)"
if [ -n "$ALERTER" ]; then
  "$ALERTER" --title "$TITLE" --message "$BANNER" --actions "${BUTTON:-Stop}" --timeout "${TIMEOUT:-60}" "${SND[@]}" >/dev/null 2>&1
  _stop
elif [ -n "$TN" ]; then
  "$TN" -title "$TITLE" -message "$BANNER" -group cc-notifier >/dev/null 2>&1; _wait
else
  osascript -e "display notification \"$BANNER\" with title \"$TITLE\"" >/dev/null 2>&1; _wait
fi
CCN_EOF__attention_sh
  cat > "$DIR/cc_alarm_listener.py" <<'CCN_EOF_cc_alarm_listener_py'
#!/usr/bin/env python3
"""Local alarm listener. Binds loopback on BOTH 127.0.0.1 and ::1 (ssh forwards
`localhost` may hit ::1 first). Endpoints: /beep /alarm /done /ask /stop /ping.

Guards:
  - rejects requests carrying a non-local Origin header (browser CSRF / DNS-rebind);
  - if a token file (<dir>/token) exists, action endpoints require a matching
    X-CC-Token header (/ping stays open for liveness). The token is re-read per
    request, so enabling/disabling auth needs no listener restart.
A ?label=... query is sanitized and passed to the alarm as $CC_LABEL.
"""
import http.server, os, re, signal, socket, socketserver, subprocess, threading
from urllib.parse import urlsplit, parse_qs

PORT = int(os.environ.get("CC_NOTIFY_PORT", "28765"))
HERE = os.path.dirname(os.path.abspath(__file__))
ALARM = os.path.join(HERE, "cc_alarm.sh")
BEEP = os.path.join(HERE, "cc_beep.sh")
ASK = os.path.join(HERE, "cc_ask.sh")
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")

_lock = threading.Lock(); _current = None


def _token():
    try:
        with open(os.path.join(HERE, "token")) as f:
            return f.read().strip()
    except Exception:
        return ""


def stop_alarm():
    global _current
    with _lock:
        if _current and _current.poll() is None:
            try: os.killpg(os.getpgid(_current.pid), signal.SIGTERM)
            except ProcessLookupError: pass
        _current = None


def start_proc(script, label=""):
    global _current
    stop_alarm()
    env = dict(os.environ)
    if label: env["CC_LABEL"] = label
    with _lock:
        _current = subprocess.Popen(["/bin/bash", script], start_new_session=True, env=env)


def play_beep():
    subprocess.Popen(["/bin/bash", BEEP], start_new_session=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def _route(self):
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).hostname not in LOCAL_HOSTS:
            self.send_response(403); self.end_headers(); return
        u = urlsplit(self.path)
        path = u.path.rstrip("/")
        tok = _token()
        if path != "/ping" and tok and self.headers.get("X-CC-Token", "") != tok:
            self.send_response(403); self.end_headers(); return
        label = re.sub(r"[^\w\-./ ]", "", parse_qs(u.query).get("label", [""])[0])[:64]
        if path in ("/alarm", "/done"): start_proc(ALARM, label); body = b"alarm\n"
        elif path == "/ask": start_proc(ASK, label); body = b"ask\n"
        elif path == "/beep": play_beep(); body = b"beep\n"
        elif path == "/stop": stop_alarm(); body = b"stopped\n"
        elif path in ("/ping", ""): body = b"ok\n"
        else: self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    do_GET = _route; do_POST = _route
    def log_message(self, *a): pass


class V4(socketserver.ThreadingTCPServer): allow_reuse_address = True; daemon_threads = True
class V6(socketserver.ThreadingTCPServer): address_family = socket.AF_INET6; allow_reuse_address = True; daemon_threads = True


def main():
    servers = []
    for cls, host in ((V4, "127.0.0.1"), (V6, "::1")):
        try: servers.append(cls((host, PORT), Handler))
        except OSError as e: print(f"warn: bind {host}:{PORT}: {e}", flush=True)
    if not servers: raise SystemExit(f"could not bind {PORT}")
    ts = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for t in ts: t.start()
    for t in ts: t.join()


if __name__ == "__main__": main()
CCN_EOF_cc_alarm_listener_py
  cat > "$DIR/cc_alarm.sh" <<'CCN_EOF_cc_alarm_sh'
#!/bin/bash
# Round-complete alarm (armed mode). Configurable via ~/.cc-notifier/config:
#   CC_ALARM_SOUND     default Blow ("Breeze")
#   CC_ALARM_REPEATS   how many times the sound plays (default 10)
#   CC_ALARM_INTERVAL  seconds between plays (default 1)
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_ALARM_SOUND:-/System/Library/Sounds/Blow.aiff}"
REPEATS="${CC_ALARM_REPEATS:-10}"
INTERVAL="${CC_ALARM_INTERVAL:-1}"
TITLE="${CC_ALARM_TITLE:-Claude Code}"
MSG="${CC_ALARM_MSG:-Round complete}"
BUTTON="Stop"
TIMEOUT="${CC_ALARM_TIMEOUT:-60}"
. "$HERE/_attention.sh"
CCN_EOF_cc_alarm_sh
  cat > "$DIR/cc_ask.sh" <<'CCN_EOF_cc_ask_sh'
#!/bin/bash
# "CC needs your input" alarm (AskUserQuestion). Configurable via ~/.cc-notifier/config:
#   CC_ASK_SOUND     default Funk
#   CC_ASK_REPEATS   how many times the sound plays (default 3)
#   CC_ASK_INTERVAL  seconds between plays (default 1)
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_ASK_SOUND:-/System/Library/Sounds/Funk.aiff}"
REPEATS="${CC_ASK_REPEATS:-3}"
INTERVAL="${CC_ASK_INTERVAL:-1}"
TITLE="${CC_ASK_TITLE:-Claude Code}"
MSG="${CC_ASK_MSG:-Needs your input — answer the question in VSCode}"
BUTTON="OK"
TIMEOUT="${CC_ASK_TIMEOUT:-120}"
. "$HERE/_attention.sh"
CCN_EOF_cc_ask_sh
  cat > "$DIR/cc_beep.sh" <<'CCN_EOF_cc_beep_sh'
#!/bin/bash
# Short chime — single play, gated by the active macOS Focus (cc_focus.sh):
# muted in Sleep / Do-Not-Disturb, played otherwise. Sound configurable; no repeats.
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_BEEP_SOUND:-/System/Library/Sounds/Glass.aiff}"
[ -f "$HERE/cc_focus.sh" ] && . "$HERE/cc_focus.sh"
if ! command -v cc_should_play >/dev/null 2>&1 || cc_should_play; then afplay "$SOUND"; fi
CCN_EOF_cc_beep_sh
  cat > "$DIR/cc_check_hotkeys.py" <<'CCN_EOF_cc_check_hotkeys_py'
#!/usr/bin/env python3
"""List enabled macOS *system* keyboard shortcuts (does NOT cover app/3rd-party).
Usage: cc_check_hotkeys.py [filter]"""
import os, plistlib, subprocess, sys
PLIST = os.path.expanduser("~/Library/Preferences/com.apple.symbolichotkeys.plist")
MODS = [(1<<17,"Shift"),(1<<18,"Control"),(1<<19,"Option"),(1<<20,"Command")]
def mods(m): return "+".join(s for b,s in MODS if int(m)&b) or "(none)"
def kc(p1,p2): p1=int(p1); return chr(p1).upper() if 32<=p1<127 else f"keycode-{int(p2)}"
def main():
    needle = sys.argv[1].lower() if len(sys.argv)>1 else None
    try:
        xml = subprocess.run(["plutil","-convert","xml1","-o","-",PLIST],capture_output=True,check=True).stdout
        keys = plistlib.loads(xml).get("AppleSymbolicHotKeys",{})
    except Exception as e: print(f"could not read {PLIST}: {e}"); return
    rows=[]
    for kid,info in keys.items():
        if not isinstance(info,dict) or not info.get("enabled"): continue
        v=info.get("value",{}); p=v.get("parameters") if isinstance(v,dict) else None
        if not p or len(p)<3: continue
        rows.append(f"{mods(p[2])+' + '+kc(p[0],p[1]):28s}  system hotkey id {kid}")
    for r in sorted(rows):
        if not needle or needle in r.lower(): print(r)
    print("\nApp-menu & third-party global hotkeys are NOT listed — also check System Settings > Keyboard > Keyboard Shortcuts.")
if __name__=="__main__": main()
CCN_EOF_cc_check_hotkeys_py
  cat > "$DIR/cc_focus.sh" <<'CCN_EOF_cc_focus_sh'
#!/bin/bash
# Decide whether the alarm/beep SOUND should play under the active macOS Focus.
# Source this, then call cc_should_play: returns 0 = PLAY, 1 = MUTE.
#
# afplay is direct audio, not a notification, so Focus/DND can't mute it — we
# detect the active Focus ourselves and skip afplay in the muted modes. The
# banner is gated separately by the per-app Focus allow-list (System Settings).
#
# Detection, in order:
#   1. `shortcuts run CurrentFocus` — a 1-action "Get Current Focus" Shortcut you
#      create once (no Full Disk Access; sees scheduled + manual focuses).
#   2. ~/Library/DoNotDisturb/DB/Assertions.json — fallback (may need Full Disk
#      Access; misses scheduled focuses). Parsed with python3 (no jq dependency).
#   Undetected/unknown => PLAY (never silently swallow an alarm).
#
# Config (~/.cc-notifier/config):
#   CC_MUTE_FOCUS   space-separated substrings to mute on (case-insensitive),
#                   matched against the Shortcut name AND the raw mode id.
#   CC_FOCUS_DEBUG  1 => print the detected token to stderr.
: "${CC_MUTE_FOCUS:=sleep donotdisturb.mode.default}"

_cc_focus_token() {
  if command -v shortcuts >/dev/null 2>&1; then
    # --output-path writes the result to a FILE (documented behavior); the
    # shortcut must end with "Stop and Output" (or an output-producing action).
    local tmp n=""
    tmp="${TMPDIR:-/tmp}/cc_focus.$$"; rm -f "$tmp"
    if shortcuts run CurrentFocus --output-path "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      n="$(tr -d '\r' < "$tmp" | head -n1)"
    fi
    rm -f "$tmp"
    # Fallback: some builds emit to stdout when it is a pipe.
    [ -n "$n" ] || n="$(shortcuts run CurrentFocus 2>/dev/null | tr -d '\r' | head -n1)"
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  fi
  local A="$HOME/Library/DoNotDisturb/DB/Assertions.json"
  if [ -r "$A" ]; then
    local PYB; PYB="$(command -v python3 || echo /usr/bin/python3)"
    "$PYB" -c 'import sys, json
try:
    d = json.load(open(sys.argv[1]))
    recs = (d.get("data") or [{}])[0].get("storeAssertionRecords") or []
    r = max(recs, key=lambda x: x.get("assertionDetails", {}).get("assertionStartDateTimestamp", 0)) if recs else {}
    sys.stdout.write(r.get("assertionDetails", {}).get("assertionDetailsModeIdentifier", ""))
except Exception:
    pass' "$A" 2>/dev/null
  fi
}

cc_should_play() {
  local tok; tok="$(_cc_focus_token)"
  [ "${CC_FOCUS_DEBUG:-0}" = 1 ] && printf 'cc-focus: token=[%s] mute=[%s]\n' "$tok" "$CC_MUTE_FOCUS" >&2
  [ -z "$tok" ] && return 0                          # unknown -> PLAY
  local lc m mm; lc="$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')"
  for m in $CC_MUTE_FOCUS; do
    mm="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in *"$mm"*) return 1;; esac
  done
  case "$lc" in *"do not disturb"*) return 1;; esac   # Shortcut display name for DND
  return 0
}
CCN_EOF_cc_focus_sh
  cat > "$DIR/cc_hotkey.py" <<'CCN_EOF_cc_hotkey_py'
#!/usr/bin/env python3
"""Print the cc-notifier stop hotkey as a chord (e.g. "⌃⌥Z"), read from the
Karabiner-Elements config, so the alarm banner can remind you how to silence it.
Looks at the active config first, then the staged asset. Prints nothing if no
cc-notifier rule is found (e.g. Karabiner not used)."""
import json
import os

SYM = {"control": "⌃", "option": "⌥", "command": "⌘", "shift": "⇧", "fn": "fn"}
ORDER = ["control", "option", "shift", "command", "fn"]


def _base(mod):
    return mod.replace("left_", "").replace("right_", "")


def chord_from_rule(rule):
    for m in rule.get("manipulators", []):
        frm = m.get("from", {})
        key = frm.get("key_code")
        if not key:
            continue
        mods = frm.get("modifiers", {}).get("mandatory", [])
        mods = sorted(mods, key=lambda x: ORDER.index(_base(x)) if _base(x) in ORDER else 99)
        syms = "".join(SYM.get(_base(x), "") for x in mods)
        return f"{syms}{key.upper()}"
    return None


def find_chord():
    home = os.path.expanduser("~")
    active = os.path.join(home, ".config/karabiner/karabiner.json")
    try:
        with open(active) as f:
            cfg = json.load(f)
        for prof in cfg.get("profiles", []):
            for rule in prof.get("complex_modifications", {}).get("rules", []):
                if "cc-notifier" in rule.get("description", "").lower():
                    c = chord_from_rule(rule)
                    if c:
                        return c
    except Exception:
        pass
    asset = os.path.join(home, ".config/karabiner/assets/complex_modifications/cc-notifier.json")
    try:
        with open(asset) as f:
            data = json.load(f)
        for rule in data.get("rules", []):
            c = chord_from_rule(rule)
            if c:
                return c
    except Exception:
        pass
    return None


if __name__ == "__main__":
    c = find_chord()
    if c:
        print(c)
CCN_EOF_cc_hotkey_py
  cat > "$DIR/cc_preview_sounds.sh" <<'CCN_EOF_cc_preview_sounds_sh'
#!/bin/bash
# Preview macOS sounds. cc_preview_sounds.sh [once|loop] [Name...]
MODE="once"; case "$1" in once|loop) MODE="$1"; shift;; esac
if [ "$#" -gt 0 ]; then FILES=(); for n in "$@"; do FILES+=("/System/Library/Sounds/${n}.aiff"); done
else FILES=(/System/Library/Sounds/*.aiff ~/Library/Sounds/*.aiff); fi
for f in "${FILES[@]}"; do [ -f "$f" ] || continue; printf '> %s\n' "$(basename "$f" .aiff)"
  if [ "$MODE" = loop ]; then e=$((SECONDS+5)); while [ "$SECONDS" -lt "$e" ]; do afplay "$f"; done; else afplay "$f"; fi
  sleep 0.4; done
CCN_EOF_cc_preview_sounds_sh
  cat > "$DIR/cc_stop.sh" <<'CCN_EOF_cc_stop_sh'
#!/bin/bash
# Instant local stop — bind to a hotkey (Karabiner / Shortcuts: Run Shell Script).
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="$(cd "$(dirname "$0")" && pwd)"
HDR=(); [ -f "$DIR/token" ] && HDR=(-H "X-CC-Token: $(cat "$DIR/token")")
curl -s --max-time 2 "${HDR[@]}" "http://localhost:${PORT}/stop" >/dev/null 2>&1
CCN_EOF_cc_stop_sh
  cat > "$DIR/karabiner-stop.json" <<'CCN_EOF_karabiner_stop_json'
{
  "title": "cc-notifier",
  "rules": [
    {
      "description": "cc-notifier: Ctrl+Opt+Z -> stop the alarm (works even in the Claude Code chat box)",
      "manipulators": [
        {
          "type": "basic",
          "from": {
            "key_code": "z",
            "modifiers": { "mandatory": ["control", "option"], "optional": ["caps_lock"] }
          },
          "to": [
            { "shell_command": "$HOME/.cc-notifier/cc_stop.sh" }
          ]
        }
      ]
    }
  ]
}
CCN_EOF_karabiner_stop_json
  chmod +x "$DIR"/*.sh "$DIR"/*.py 2>/dev/null || true
}

write_config(){
  local cfg="$DIR/config"
  [ -f "$cfg" ] && return 0
  cat > "$cfg" <<'CFG_EOF'
# cc-notifier config — uncomment & edit. Read on each alarm (no reload needed).
# Long round-end alarm (armed mode):
#CC_ALARM_SOUND=/System/Library/Sounds/Blow.aiff
#CC_ALARM_REPEATS=10
#CC_ALARM_INTERVAL=1
# "Needs your input" alarm (AskUserQuestion):
#CC_ASK_SOUND=/System/Library/Sounds/Funk.aiff
#CC_ASK_REPEATS=3
#CC_ASK_INTERVAL=1
# Short chime (single play; sound only, no repeats):
#CC_BEEP_SOUND=/System/Library/Sounds/Glass.aiff
# Optional phone push via Telegram (relayed from THIS Mac). See README for setup.
#CC_TELEGRAM_TOKEN=123456789:ABCdef_your_bot_token
#CC_TELEGRAM_CHAT_ID=123456789
# Focus-aware sound: skip the alarm/beep AUDIO while these Focus modes are active
# (space-separated substrings, case-insensitive vs the Shortcut name + raw mode
# id). Empty = always play. Banner is gated separately via System Settings > Focus.
# Needs a "CurrentFocus" Shortcut on the Mac — see README.
#CC_MUTE_FOCUS="sleep donotdisturb.mode.default"
# Escape hatch: route the sound through the notification so Apple gates it for
# free (no detection) — but loses the looping alarm. 1 = on.
#CC_SOUND_VIA_ALERTER=0
CFG_EOF
  log "wrote config template: $cfg"
}

merge_hooks(){
  python3 - "$SETTINGS" "$DIR" <<'PYMERGE'
import json, os, sys
settings_path, d = sys.argv[1], sys.argv[2]
events = {
    "SessionStart":     ("notify_healthcheck.sh", 10, None),
    "UserPromptSubmit": ("notify_stop.sh", 5, None),
    "Stop":             ("notify_done.sh", 5, None),
    "PreToolUse":       ("notify_ask.sh", 5, "AskUserQuestion"),
}
try:
    with open(settings_path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
hooks = cfg.setdefault("hooks", {})
for ev, (script, to, matcher) in events.items():
    cmd = os.path.join(d, script)
    arr = hooks.setdefault(ev, [])
    present = any(
        isinstance(h, dict) and h.get("command") == cmd
        for grp in arr if isinstance(grp, dict)
        for h in grp.get("hooks", []) )
    if present: continue
    entry = {"hooks": [{"type": "command", "command": cmd, "timeout": to}]}
    if matcher: entry["matcher"] = matcher
    arr.append(entry)
os.makedirs(os.path.dirname(settings_path) or ".", exist_ok=True)
with open(settings_path, "w") as f: json.dump(cfg, f, indent=2)
print("  hooks merged into", settings_path)
PYMERGE
}

install_launchd(){
  local plist="$HOME/Library/LaunchAgents/com.ccnotifier.listener.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ccnotifier.listener</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>$DIR/cc_alarm_listener.py</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>CC_NOTIFY_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/ccnotifier.out.log</string>
  <key>StandardErrorPath</key><string>/tmp/ccnotifier.err.log</string>
</dict></plist>
PLIST_EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist" && log "launchd listener loaded (port $PORT)"
}

apply_port(){
  [ "$PORT" = "28765" ] && return 0
  find "$DIR" -type f \( -name '*.sh' -o -name '*.py' \) -exec sed -i.bak "s/28765/$PORT/g" {} \;
  find "$DIR" -name '*.bak' -delete
}

do_uninstall(){
  hdr "uninstall"
  if [ "$OS" = Darwin ]; then
    local plist="$HOME/Library/LaunchAgents/com.ccnotifier.listener.plist"
    launchctl unload "$plist" 2>/dev/null || true; rm -f "$plist"; log "launchd removed"
  fi
  python3 - "$SETTINGS" "$DIR" <<'PYUNMERGE'
import json, os, sys
settings_path, d = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f: cfg = json.load(f)
except Exception: sys.exit(0)
mine = {os.path.join(d, n) for n in
        ("notify_healthcheck.sh","notify_stop.sh","notify_done.sh","notify_ask.sh")}
for ev, arr in list(cfg.get("hooks", {}).items()):
    arr[:] = [g for g in arr if not any(
        isinstance(h, dict) and h.get("command") in mine for h in (g.get("hooks", []) if isinstance(g, dict) else []))]
    if not arr: del cfg["hooks"][ev]
with open(settings_path, "w") as f: json.dump(cfg, f, indent=2)
print("  hooks removed from", settings_path)
PYUNMERGE
  log "(left $DIR in place — 'rm -rf $DIR' to fully remove)"
  exit 0
}

[ "$UNINSTALL" = 1 ] && do_uninstall

hdr "cc-notifier install — role: $ROLE (port $PORT, dir $DIR)"
if [ "$ROLE" = receiver ]; then
  write_receiver
  write_sender
  write_config
  apply_port
  merge_hooks
  if [ "$OS" = Darwin ]; then
    if ! command -v alerter >/dev/null 2>&1; then
      if command -v brew >/dev/null 2>&1; then
        log "installing alerter…"; brew install vjeantet/tap/alerter || log "WARN: alerter install failed"
      else
        log "WARN: install Homebrew then: brew install vjeantet/tap/alerter (needed for the Stop button)"
      fi
    fi
    install_launchd
    if [ -d "$HOME/.config/karabiner" ]; then
      mkdir -p "$HOME/.config/karabiner/assets/complex_modifications"
      cp "$DIR/karabiner-stop.json" "$HOME/.config/karabiner/assets/complex_modifications/cc-notifier.json"
      log "Karabiner rule staged — enable it in Karabiner › Complex Modifications › Add rule"
    else
      log "tip: install Karabiner-Elements + import $DIR/karabiner-stop.json for a hotkey that works in the CC chat box"
    fi
    command -v alerter >/dev/null 2>&1 && alerter --title "cc-notifier" --message "installed — Allow notifications (Alerts style); for Focus, allow Terminal in Work" --timeout 4 >/dev/null 2>&1 || true
  else
    log "NOTE: receiver role outside macOS — wrote files but skipped launchd/alerter."
  fi
  hdr "manual steps (one-time, GUI)"
  cat <<EOF_NEXT
  1. macOS notifications: System Settings > Notifications > alerter -> Allow, style "Alerts".
  2. Break Focus (banner): System Settings > Focus > Work > Allowed Notifications
       > Apps > add "Terminal" (NOT alerter — it isn't listed there; its
       notifications count as Terminal). Keep Terminal OUT of Sleep / DND.
  3. Focus-aware sound: in Shortcuts.app create a shortcut named exactly
       "CurrentFocus" with TWO actions: [Get Current Focus] then
       [Stop and Output <Current Focus>]. The Stop-and-Output step is REQUIRED.
       Verify: shortcuts run CurrentFocus --output-path /tmp/f.txt && cat /tmp/f.txt
  4. Stop hotkey (works in the CC chat box): Karabiner-Elements > Complex
       Modifications > Add rule > Enable "cc-notifier: Ctrl+Opt+Z -> stop".
       (No Karabiner? A macOS Shortcut running $DIR/cc_stop.sh works everywhere
       EXCEPT the CC input box.)
  5. Pick sounds / repeats: $DIR/cc_preview_sounds.sh loop   (set knobs in $DIR/config)
  6. For REMOTE machines: add to ~/.ssh/config under that host:
       RemoteForward $PORT localhost:$PORT
  Test now:  $DIR/cc_tunnel_test.sh beep   (and: $DIR/cc_tunnel_test.sh ask)
  Arm/disarm any session:  $DIR/cc_notify_arm.sh on | off | status
  Diagnose anytime:  $DIR/cc_doctor.sh
  Secure it (recommended for shared remotes):  $DIR/cc_token.sh new   (copy the value to each remote)
EOF_NEXT
else
  write_sender
  apply_port
  merge_hooks
  hdr "remote sender installed"
  cat <<EOF_NEXT
  Hooks wired into $SETTINGS (restart this CC session to load them).
  Notifies on round-complete (Stop) and questions (AskUserQuestion).
  This machine notifies your Mac THROUGH an ssh reverse tunnel. On your Mac:
    1. Add to ~/.ssh/config under the host you use for this machine:
         RemoteForward $PORT localhost:$PORT
    2. Reconnect (or: ssh -O forward -R $PORT:localhost:$PORT <host>)
    3. Make sure the Mac receiver is installed (run this script on the Mac).
  Verify from here:  $DIR/cc_tunnel_test.sh   (or full check: $DIR/cc_doctor.sh)
  Arm/disarm any session:  $DIR/cc_notify_arm.sh on | off | status
  If your Mac set an auth token:  $DIR/cc_token.sh set <value-from-the-Mac>
EOF_NEXT
fi
hdr "done"
