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
