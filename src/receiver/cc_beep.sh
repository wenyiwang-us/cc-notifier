#!/bin/bash
# Short chime — ALWAYS a single play (sound is configurable, repeats are not).
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_BEEP_SOUND:-/System/Library/Sounds/Glass.aiff}"
afplay "$SOUND"
