#!/usr/bin/env bash
# Explicit completion notification for any agent, a script, or manual use.
# Unlike the Stop hook (notify_done.sh), this waits for the listener and reports failure.
set -euo pipefail

usage(){
  cat <<'USAGE'
Usage: cc_notify.sh [--title TEXT] [--session ID] [--action auto|alarm|beep|ask]
                    [--agent NAME] [--label TEXT] [--body TEXT] [--message TEXT] [MESSAGE]

Sends one notification and waits for the listener's HTTP response.
The default action honors cc_notify_arm.sh: alarm when armed, beep otherwise.
Alarm/ask display the title and message; beep plays the short chime only.
MESSAGE is the one-sentence summary shown in the alert and the phone push.
--body adds a longer text (line breaks kept) that only the phone push carries.
--agent names who is notifying (default: Codex or Claude Code when run by one).
Exit status: 0 = listener accepted it, 1 = delivery failed, 2 = invalid arguments.
USAGE
}
fail_usage(){ printf '%s\n' "$*" >&2; usage >&2; exit 2; }

DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
PORT="${CC_NOTIFY_PORT:-28765}"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"
ARM_FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
act="auto"
title="Work complete"
sid="${CODEX_THREAD_ID:-manual}"
body=""
agent="${CC_NOTIFY_AGENT:-}"
if [ -z "$agent" ]; then
  if [ -n "${CODEX_THREAD_ID:-}" ]; then agent="Codex"; elif [ -n "${CLAUDECODE:-}" ]; then agent="Claude Code"; fi
fi
label="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD")"
message=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --title|--session|--action|--agent|--label|--body|--message)
      [ $# -ge 2 ] || fail_usage "Missing value for $1."
      case "$1" in
        --title) title="$2";;
        --session) sid="$2";;
        --action) act="$2";;
        --agent) agent="$2";;
        --body) body="$2";;
        --label) label="$2";;
        --message) message="$2";;
      esac
      shift 2;;
    --) shift; [ $# -eq 1 ] || fail_usage "Supply one message."; message="$1"; shift;;
    -*) fail_usage "Unknown option: $1";;
    *) [ -z "$message" ] || fail_usage "Supply one message."; message="$1"; shift;;
  esac
done
[ -n "$message" ] || fail_usage "A completion message is required."
case "$act" in
  auto) if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi;;
  alarm|beep|ask) ;;
  *) fail_usage "Unsupported action: $act";;
esac

log(){
  ( umask 077; printf '%s manual act=%s http=%s curl_exit=%s session=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$act" "$code" "$ec" "$sid" >> "$LOG" ) 2>/dev/null || :
}
# Read the auth header through stdin so the token is absent from process args.
header=""
if [ -f "$DIR/token" ]; then header="X-CC-Token: $(cat "$DIR/token")"; fi
# Localhost must reach the SSH tunnel directly even when proxy variables are set.
if code="$(printf '%s\n' "$header" | curl --silent --show-error \
    --noproxy '*' --max-time "${CC_NOTIFY_TIMEOUT:-5}" --header @- \
    --get --data-urlencode "label=$label" --data-urlencode "session=$sid" \
    ${agent:+--data-urlencode "agent=$agent"} ${body:+--data-urlencode "body=$body"} \
    --data-urlencode "title=$title" --data-urlencode "brief=$message" \
    --output /dev/null --write-out '%{http_code}' "http://localhost:${PORT}/${act}")"; then
  ec=0
else
  ec=$?
fi
log
if [ "$ec" -eq 0 ] && [ "$code" = 200 ]; then
  printf 'OK /%s -> HTTP 200 (listener accepted notification)\n' "$act"
  exit 0
fi
printf 'FAIL /%s -> HTTP=%s curl_exit=%s\n' "$act" "${code:-none}" "$ec" >&2
if [ "$code" = 403 ]; then
  printf 'Auth token mismatch; synchronize %s/token with the Mac.\n' "$DIR" >&2
else
  printf 'Check the listener/tunnel with %s/cc_tunnel_test.sh ping.\n' "$DIR" >&2
fi
exit 1
