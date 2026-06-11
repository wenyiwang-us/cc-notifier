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
