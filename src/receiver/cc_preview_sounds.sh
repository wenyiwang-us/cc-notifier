#!/bin/bash
# Preview macOS sounds. cc_preview_sounds.sh [once|loop] [Name...]
MODE="once"; case "$1" in once|loop) MODE="$1"; shift;; esac
if [ "$#" -gt 0 ]; then FILES=(); for n in "$@"; do FILES+=("/System/Library/Sounds/${n}.aiff"); done
else FILES=(/System/Library/Sounds/*.aiff ~/Library/Sounds/*.aiff); fi
for f in "${FILES[@]}"; do [ -f "$f" ] || continue; printf '> %s\n' "$(basename "$f" .aiff)"
  if [ "$MODE" = loop ]; then e=$((SECONDS+5)); while [ "$SECONDS" -lt "$e" ]; do afplay "$f"; done; else afplay "$f"; fi
  sleep 0.4; done
