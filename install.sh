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
  cat > "$DIR/cc_tunnel_test.sh" <<'CCN_EOF_cc_tunnel_test_sh'
#!/bin/bash
# Self-test the notifier path. Usage: cc_tunnel_test.sh [ping|beep|alarm|ask|stop]
PORT="${CC_NOTIFY_PORT:-28765}"
ACT="${1:-ping}"
code=$(curl -s --max-time 4 -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/${ACT}"); ec=$?
if [ "$code" = "200" ]; then echo "OK   /${ACT} -> HTTP 200"; exit 0; fi
echo "FAIL /${ACT} -> HTTP=${code} curl_exit=${ec}"
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
curl -s --max-time 2 "http://localhost:${PORT}/ask" >/dev/null 2>&1 &
exit 0
CCN_EOF_notify_ask_sh
  cat > "$DIR/notify_done.sh" <<'CCN_EOF_notify_done_sh'
#!/bin/bash
# Stop hook: notify the Mac when a round finishes. Fire-and-forget.
PORT="${CC_NOTIFY_PORT:-28765}"
MIN="${CC_NOTIFY_MIN_SECONDS:-20}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
ARM_FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
START_FILE="$DIR/turn_start"
if [ "$MIN" -gt 0 ] && [ -f "$START_FILE" ]; then
  start=$(cat "$START_FILE" 2>/dev/null); now=$(date +%s)
  if [ -n "$start" ] && [ $((now - start)) -lt "$MIN" ]; then exit 0; fi
fi
if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi
curl -s --max-time 2 "http://localhost:${PORT}/${act}" >/dev/null 2>&1 &
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
curl -s --max-time 2 "http://localhost:${PORT}/stop" >/dev/null 2>&1 &
exit 0
CCN_EOF_notify_stop_sh
  chmod +x "$DIR"/*.sh "$DIR"/*.py 2>/dev/null || true
}
write_receiver(){
  mkdir -p "$DIR"
  cat > "$DIR/_attention.sh" <<'CCN_EOF__attention_sh'
#!/bin/bash
# Shared engine for the long attention alarms (cc_alarm.sh / cc_ask.sh).
# The caller sources this AFTER setting: SOUND, REPEATS, INTERVAL, TITLE, MSG,
# BUTTON, TIMEOUT. Plays SOUND, REPEATS times, INTERVAL seconds apart, while
# showing a persistent alert with one button; any click (or /stop) silences it.
find_bin(){ for p in "$@"; do [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

( for ((i = 1; i <= REPEATS; i++)); do
    afplay "$SOUND"
    [ "$i" -lt "$REPEATS" ] && sleep "$INTERVAL"
  done ) &
_BEEP=$!
_stop(){ kill "$_BEEP" 2>/dev/null; pkill -P "$_BEEP" afplay 2>/dev/null; }

ALERTER="$(find_bin "$(command -v alerter 2>/dev/null)" /opt/homebrew/bin/alerter /usr/local/bin/alerter)"
TN="$(find_bin "$(command -v terminal-notifier 2>/dev/null)" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier)"
if [ -n "$ALERTER" ]; then
  "$ALERTER" --title "$TITLE" --message "$MSG" --actions "${BUTTON:-Stop}" --timeout "${TIMEOUT:-60}" >/dev/null 2>&1
  _stop
elif [ -n "$TN" ]; then
  "$TN" -title "$TITLE" -message "$MSG" -group cc-notifier >/dev/null 2>&1; wait "$_BEEP" 2>/dev/null
else
  osascript -e "display notification \"$MSG\" with title \"$TITLE\"" >/dev/null 2>&1; wait "$_BEEP" 2>/dev/null
fi
CCN_EOF__attention_sh
  cat > "$DIR/cc_alarm_listener.py" <<'CCN_EOF_cc_alarm_listener_py'
#!/usr/bin/env python3
"""Local alarm listener. Binds loopback on BOTH 127.0.0.1 and ::1 (ssh forwards
`localhost` may hit ::1 first). Endpoints: /beep /alarm /done /ask /stop /ping."""
import http.server, os, signal, socket, socketserver, subprocess, threading
PORT = int(os.environ.get("CC_NOTIFY_PORT", "28765"))
HERE = os.path.dirname(os.path.abspath(__file__))
ALARM = os.path.join(HERE, "cc_alarm.sh")
BEEP = os.path.join(HERE, "cc_beep.sh")
ASK = os.path.join(HERE, "cc_ask.sh")
_lock = threading.Lock(); _current = None
def stop_alarm():
    global _current
    with _lock:
        if _current and _current.poll() is None:
            try: os.killpg(os.getpgid(_current.pid), signal.SIGTERM)
            except ProcessLookupError: pass
        _current = None
def start_proc(script):
    global _current
    stop_alarm()
    with _lock:
        _current = subprocess.Popen(["/bin/bash", script], start_new_session=True)
def play_beep():
    subprocess.Popen(["/bin/bash", BEEP], start_new_session=True)
class Handler(http.server.BaseHTTPRequestHandler):
    def _route(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("/alarm", "/done"): start_proc(ALARM); body = b"alarm\n"
        elif path == "/ask": start_proc(ASK); body = b"ask\n"
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
MSG="${CC_ALARM_MSG:-Round complete — press Stop to silence}"
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
# Short chime — ALWAYS a single play (sound is configurable, repeats are not).
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_BEEP_SOUND:-/System/Library/Sounds/Glass.aiff}"
afplay "$SOUND"
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
# Instant local stop — bind to a hotkey (Shortcuts: Run Shell Script).
PORT="${CC_NOTIFY_PORT:-28765}"
curl -s --max-time 2 "http://localhost:${PORT}/stop" >/dev/null 2>&1
CCN_EOF_cc_stop_sh
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
    command -v alerter >/dev/null 2>&1 && alerter --title "cc-notifier" --message "installed — Allow notifications, then add 'alerter' to your Focus modes" --timeout 4 >/dev/null 2>&1 || true
  else
    log "NOTE: receiver role outside macOS — wrote files but skipped launchd/alerter."
  fi
  hdr "manual steps (one-time, GUI)"
  cat <<EOF_NEXT
  1. macOS notifications: System Settings > Notifications > alerter -> Allow, style "Alerts".
  2. Break Focus: System Settings > Focus > (each mode) > allow the "alerter" app.
  3. Stop hotkey: Shortcuts app > new shortcut > Run Shell Script:  $DIR/cc_stop.sh
       then assign a key (e.g. Ctrl+Opt+Z). Avoid Cmd-combos & Ctrl+Opt+Space.
  4. Pick sounds / repeats: $DIR/cc_preview_sounds.sh loop   (set knobs in $DIR/config)
  5. For REMOTE machines: add to ~/.ssh/config under that host:
       RemoteForward $PORT localhost:$PORT
  Test now:  $DIR/cc_tunnel_test.sh beep   (and: $DIR/cc_tunnel_test.sh ask)
  Arm/disarm any session:  $DIR/cc_notify_arm.sh on | off | status
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
  Verify from here:  $DIR/cc_tunnel_test.sh
  Arm/disarm any session:  $DIR/cc_notify_arm.sh on | off | status
EOF_NEXT
fi
hdr "done"
