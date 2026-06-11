#!/bin/bash
# Instant local stop — bind to a hotkey (Shortcuts: Run Shell Script).
PORT="${CC_NOTIFY_PORT:-28765}"
curl -s --max-time 2 "http://localhost:${PORT}/stop" >/dev/null 2>&1
