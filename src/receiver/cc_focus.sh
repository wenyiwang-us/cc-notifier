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
