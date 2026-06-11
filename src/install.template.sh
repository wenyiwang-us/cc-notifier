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

# __GENERATED_WRITERS__

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
