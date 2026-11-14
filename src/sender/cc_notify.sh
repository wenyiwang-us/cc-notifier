#!/usr/bin/env bash
# Explicit completion notification for any agent, a script, or manual use.
# Unlike the Stop hook (notify_done.sh), this waits for the listener and reports failure.
set -euo pipefail

usage(){
  cat <<'USAGE'
Usage: cc_notify.sh [--title TEXT] [--session ID] [--action auto|alarm|beep|ask]
                    [--agent NAME] [--label TEXT] [--body TEXT | --body-file FILE]
                    [--message TEXT] [MESSAGE]

Sends one notification and waits for the listener's HTTP response.
The default action honors cc_notify_arm.sh: alarm when armed, beep otherwise.
Alarm/ask display the title and message; beep plays the short chime only.
MESSAGE is the one-sentence summary shown in the alert and the phone push.
--body adds a longer text (line breaks kept) that only the phone push carries;
--body-file reads it from FILE (- = standard input). Text given as an argument
can be read by other users of a shared host while this runs; a file cannot.
--agent names who is notifying (default: Codex or Claude Code when run by one).
Exit status: 0 = listener accepted it, 1 = delivery failed, 2 = invalid arguments.
USAGE
}
fail_usage(){ printf '%s\n' "$*" >&2; usage >&2; exit 2; }

DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
PORT="${CC_NOTIFY_PORT:-28765}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"
ARM_FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
act="auto"
title="Work complete"
sid="${CODEX_THREAD_ID:-manual}"
body=""
body_file=""
agent="${CC_NOTIFY_AGENT:-}"
if [ -z "$agent" ]; then
  if [ -n "${CODEX_THREAD_ID:-}" ]; then agent="Codex"; elif [ -n "${CLAUDECODE:-}" ]; then agent="Claude Code"; fi
fi
label="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD")"
message=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --title|--session|--action|--agent|--label|--body|--body-file|--message)
      [ $# -ge 2 ] || fail_usage "Missing value for $1."
      case "$1" in
        --title) title="$2";;
        --session) sid="$2";;
        --action) act="$2";;
        --agent) agent="$2";;
        --body) body="$2";;
        --body-file) body_file="$2";;
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
if [ "$body_file" = "-" ]; then
  # Standard input goes to a private file first (the client reads the body from a file).
  tmp_body="$(umask 077; mktemp "${TMPDIR:-/tmp}/cc_notify.XXXXXX")" || { echo "cannot make a temporary file" >&2; exit 1; }
  trap 'rm -f "$tmp_body"' EXIT
  cat > "$tmp_body"; body_file="$tmp_body"
elif [ -n "$body_file" ] && [ ! -r "$body_file" ]; then
  fail_usage "Cannot read $body_file."
fi
case "$act" in
  auto) if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi;;
  alarm|beep|ask) ;;
  *) fail_usage "Unsupported action: $act";;
esac

log(){
  ( umask 077; printf '%s manual act=%s %s session=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$act" "$res" "$sid" >> "$LOG" ) 2>/dev/null || :
}
# Signed with the token, which never travels, and sent only to a listener that
# proves it holds the token (cc_client.py). The fields go in the environment,
# never on a command line. Localhost is reached directly, whatever the proxy settings.
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
res="$(CC_F_LABEL="$label" CC_F_SESSION="$sid" CC_F_AGENT="$agent" CC_F_TITLE="$title" CC_F_BRIEF="$message" \
       CC_F_BODY="$body" CC_F_BODY_FILE="$body_file" CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" \
       "$PYBIN" "$HERE/cc_client.py" send "$act" 2>/dev/null)" || :
[ -n "$res" ] || res="http=000 err=client_failed auth=-"
log
case "$res" in
  http=200\ *) printf 'OK /%s -> HTTP 200 (listener accepted notification)\n' "$act"; exit 0;;
esac
printf 'FAIL /%s -> %s\n' "$act" "$res" >&2
case "$res" in
  *err=no_token*|*err=key_unknown_at_listener*|*err=no_key_for_this_machine*|*err=bad_key_name*)
    printf 'This machine has no key the listener takes (%s; or someone else holds port %s here): on the Mac, run  ~/.cc-notifier/cc_token.sh push <this host>  (on the Mac itself: cc_token.sh new)\n' "${res#* err=}" "$PORT" >&2;;
  *err=unverified*|*http=401*|*http=403*)
    printf 'The listener did not take our signature: the two ends have different keys (on the Mac: cc_token.sh push <this host>), or someone else holds port %s here.\n' "$PORT" >&2;;
  *err=old_listener*) printf 'The listener on the Mac is older than these hooks: re-run install.sh on the Mac.\n' >&2;;
  *) printf 'Check the listener/tunnel with %s/cc_tunnel_test.sh ping.\n' "$DIR" >&2;;
esac
exit 1
