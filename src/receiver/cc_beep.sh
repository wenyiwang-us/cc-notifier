#!/bin/bash
# Short chime — single play, gated by the active macOS Focus (cc_focus.sh):
# muted in Sleep / Do-Not-Disturb, played otherwise. Sound configurable; no repeats.
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_BEEP_SOUND:-/System/Library/Sounds/Glass.aiff}"
[ -f "$HERE/cc_focus.sh" ] && . "$HERE/cc_focus.sh"
if ! command -v cc_should_play >/dev/null 2>&1 || cc_should_play; then afplay "$SOUND"; fi
