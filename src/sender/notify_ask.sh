#!/bin/bash
# PreToolUse(AskUserQuestion) hook: CC is asking you a question and is BLOCKED
# waiting. Always notify (no time guard, independent of arm state).
PORT="${CC_NOTIFY_PORT:-28765}"
curl -s --max-time 2 "http://localhost:${PORT}/ask" >/dev/null 2>&1 &
exit 0
