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
