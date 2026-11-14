#!/usr/bin/env bash
# cc-notifier — self-contained installer. GENERATED from src/ by build.sh.
# Do not edit by hand; edit src/ and run ./build.sh.
#
#   bash install.sh            # auto-detect role from the OS
#   bash install.sh receiver   # force the Mac receiver role
#   bash install.sh sender     # force the agent-side sender role
#   bash install.sh --port 28765
#   bash install.sh --codex    # also add the round-end hooks to Codex (~/.codex/hooks.json)
#   bash install.sh --uninstall
#
# receiver (macOS): listener (launchd) + alerter + sounds + stop kit + local hooks.
# sender   (Linux): hooks into ~/.claude/settings.json; remote senders reach the
#                   Mac via an ssh RemoteForward. Notifies on round-complete (Stop)
#                   and on questions (AskUserQuestion). Codex uses the same hook
#                   scripts once switched on (--codex, or cc_codex_hooks.sh on).
set -euo pipefail
umask 077          # the kit holds the token, the config (Telegram bot token) and message texts

PORT=28765
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
SETTINGS="${CC_NOTIFIER_SETTINGS:-$HOME/.claude/settings.json}"
ROLE=""
UNINSTALL=0
CODEX=0
OS="$(uname -s)"

while [ $# -gt 0 ]; do
  case "$1" in
    receiver|sender) ROLE="$1"; shift;;
    --port) PORT="$2"; shift 2;;
    --uninstall) UNINSTALL=1; shift;;
    --codex) CODEX=1; shift;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -n "$ROLE" ] || case "$OS" in
  Darwin) ROLE="receiver";;
  Linux)  ROLE="sender";;
  *) echo "unsupported OS: $OS" >&2; exit 1;;
esac

log(){ printf '  %s\n' "$*"; }
hdr(){ printf '\n== %s ==\n' "$*"; }

# An earlier kit (protocol 5 or older) sent the token itself. Seen before the new
# files are written: a token, but no cc_client.py yet.
FROM_OLD=0
[ -s "$DIR/token" ] && [ ! -f "$DIR/cc_client.py" ] && FROM_OLD=1
# Before protocol 7 every machine shared one token (a token, no key-name).
FROM_SHARED=0
[ -s "$DIR/token" ] && [ ! -s "$DIR/key-name" ] && FROM_SHARED=1

secure_files(){
  chmod 700 "$DIR"
  local f
  for f in token key-name config legacy-token.sha256 listener.log tunnel.log; do [ -f "$DIR/$f" ] && chmod 600 "$DIR/$f"; done
  for f in sessions tmp keys ports; do [ -d "$DIR/$f" ] && chmod 700 "$DIR/$f"; done
  return 0
}

# The listener keeps one key per machine (keys/<name>) and, for each remote, the
# port its tunnel ends at (ports/<name>). The token all machines shared before
# stays as keys/shared until `cc_token.sh revoke shared`; this Mac's own senders
# get keys/local. Keys the listener reads come first, before it is (re)started ...
receiver_keys(){
  mkdir -p "$DIR/keys" "$DIR/ports"; chmod 700 "$DIR/keys" "$DIR/ports"
  if [ "$FROM_SHARED" = 1 ] && [ ! -e "$DIR/keys/shared" ]; then cp "$DIR/token" "$DIR/keys/shared"; fi
  if [ ! -s "$DIR/keys/local" ]; then
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$DIR/keys/local.new" && [ -s "$DIR/keys/local.new" ] \
      && mv -f "$DIR/keys/local.new" "$DIR/keys/local" \
      && log "made this Mac's own key ($DIR/keys/local); every request is signed with a key the listener has, nothing else is carried out" \
      || { echo "ERROR: could not make this Mac's own key in $DIR/keys" >&2; exit 1; }
  fi
  return 0
}
# ... and this Mac's own senders switch to its key after (repaired when it does not match).
own_key(){
  if ! cmp -s "$DIR/keys/local" "$DIR/token" || [ "$(cat "$DIR/key-name" 2>/dev/null)" != local ]; then
    cp "$DIR/keys/local" "$DIR/token.tmp" && chmod 600 "$DIR/token.tmp" && mv -f "$DIR/token.tmp" "$DIR/token" \
      && echo local > "$DIR/key-name" \
      || { echo "ERROR: could not give this Mac's senders its key ($DIR/token, $DIR/key-name)" >&2; exit 1; }
  fi
  return 0
}

write_sender(){
  mkdir -p "$DIR"
  cat > "$DIR/cc_client.py" <<'CCN_EOF_cc_client_py'
#!/usr/bin/env python3
"""The one HTTP client of cc-notifier: every script, on either end, sends through it.

Keys (protocol 7). The Mac's listener keeps one key per machine that may send to
it (keys/<name> there; `cc_token.sh push <host>` on the Mac issues one). Each
machine keeps its own key in <dir>/token and its name in <dir>/key-name. A key is
never sent anywhere:

  * Every request carries X-CC-Key (the key's name), X-CC-Time, X-CC-Nonce and
    X-CC-Sig: an HMAC-SHA256, under the key, of the name, the method, path and
    query, a hash of the body, the time and the nonce. The listener takes a
    request once, and only within WINDOW seconds of its time, so a copy of one can
    be neither changed nor sent again, nor passed off as another machine's.
  * Before anything goes out, /ping?c=<challenge>&k=<name> has to answer with
    proof=HMAC(key, name, challenge), which only a listener holding this
    machine's key can give. On a shared login node a dropped tunnel leaves the
    port free, and any user there can listen on it; such a listener gets nothing.
  * Nothing secret, and no message text, goes on a command line: any user of a
    shared host can list those. The fields come in the environment, which only
    the same user can read.

Older forms, while machines move to keys of their own:
  * Without <dir>/key-name the token is the key all machines shared (protocol 6):
    the request names no key and its signature covers no name. A protocol-7
    listener takes that form only while it keeps the shared key (keys/shared);
    `cc_token.sh push` and `rotate` retire it once each machine has its own.
  * Protocol 5 sent the token itself, in a header. A machine upgraded from that
    version keeps <dir>/legacy-token.sha256, the hash of the token it had then;
    while that file names the current token, and for LEGACY_HOURS after it was
    written, this client still serves a protocol-5 listener that way (in a
    header, never on a command line). The first time a newer listener proves
    itself the file is deleted. A new token never matches it.

usage:
  cc_client.py send <alarm|done|ask|beep|stop>
      fields from the environment: CC_F_LABEL, CC_F_AGENT, CC_F_SESSION,
      CC_F_TITLE, CC_F_BRIEF, and the text for the phone push in the file
      CC_F_BODY_FILE (or in CC_F_BODY). `stop` without CC_F_SESSION silences
      every alarm. Prints "http=<code> err=<reason> auth=<signed|shared|legacy|->";
      exit 0 when the listener answered 200.
  cc_client.py ping       "proto=<n> verified=<yes|no> as=<key name|shared> why=<reason>";
                          exit 0 when the listener proved it holds this machine's key
  cc_client.py challenge [name]
                          a fresh query for /ping (c=...&k=<name, default this machine's>),
                          for cc_tunnel_keep.sh
  cc_client.py verify <query>
                          reads a /ping answer on stdin; exit 0 when its proof is right
                          (on the Mac, for a host's name, with that host's key in keys/)
  cc_client.py version    the protocol this client speaks
Environment: CC_NOTIFIER_DIR (default ~/.cc-notifier), CC_NOTIFY_PORT (28765),
CC_NOTIFY_TIMEOUT (seconds per request, default 5; a ping waits at most 2). Each
call has an overall limit too, so a listener that answers slowly cannot hold it.
"""
import hashlib
import hmac
import http.client
import os
import re
import secrets
import signal
import socket
import sys
import time
from urllib.parse import parse_qs, quote, urlencode

PROTO = 7
PORT = int(os.environ.get("CC_NOTIFY_PORT") or "28765")
DIR = os.environ.get("CC_NOTIFIER_DIR") or os.path.join(os.path.expanduser("~"), ".cc-notifier")
LEGACY = "legacy-token.sha256"
LEGACY_HOURS = 72           # the move from protocol 5 must be finished by then
MAX_POST = 1 << 20          # the listener refuses a longer body
ACTS = ("alarm", "done", "ask", "beep", "stop")
FIELDS = (("label", "CC_F_LABEL"), ("agent", "CC_F_AGENT"), ("session", "CC_F_SESSION"),
          ("title", "CC_F_TITLE"), ("brief", "CC_F_BRIEF"))
CHALLENGE = re.compile(r"[0-9a-f]{32}\Z")
NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}\Z")
KEYLIKE = re.compile(r"[0-9a-f]{24,}\Z")


def valid_name(name):
    """A machine's key name (cc_alarm_listener.py holds the same rule): lowercase,
    not one the kit uses for its own files, not the shared key's ("shared")."""
    return bool(NAME.match(name)) and name != "shared" and ".." not in name and not KEYLIKE.match(name) \
        and not re.search(r"\.(new|tmp|bak|port)\Z|\.tmp\.", name)


# --- the protocol (cc_alarm_listener.py holds the same functions) ------------

def request_sig(key, method, path, query, body, t, nonce, name=""):
    """Protocol 7 when the request names its key, protocol 6 (the shared key) when not."""
    digest = hashlib.sha256(body).hexdigest()
    if name:
        msg = "cc-notifier/7 req\n%s\n%s\n%s\n%s\n%s\n%d\n%s" % (name, method, path, query, digest, t, nonce)
    else:
        msg = "cc-notifier/6 req\n%s\n%s\n%s\n%s\n%d\n%s" % (method, path, query, digest, t, nonce)
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).hexdigest()


def ping_proof(key, challenge, name=""):
    msg = ("cc-notifier/7 pong\n%s\n%s" % (name, challenge)) if name else ("cc-notifier/6 pong\n" + challenge)
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).hexdigest()


def same(a, b):
    """Constant-time comparison of two strings of any content."""
    return hmac.compare_digest(str(a).encode("utf-8", "replace"), str(b).encode("utf-8", "replace"))


# --- this machine's side -----------------------------------------------------

def token_key():
    """This machine's key as bytes, b"" when there is none."""
    try:
        with open(os.path.join(DIR, "token"), "rb") as f:
            return f.read().strip()
    except OSError:
        return b""


def key_name():
    """This machine's key name at the listener: "" when it has none (it holds the
    shared key of protocol 6), None when <dir>/key-name cannot be used."""
    try:
        with open(os.path.join(DIR, "key-name")) as f:
            name = f.read().strip()
    except FileNotFoundError:
        return ""
    except OSError:
        return None
    # A name goes out with every ping: one that looks like a key (cc_token.sh set
    # <key> by mistake) is never used.
    if not valid_name(name) or KEYLIKE.match(name) or same(name, token_key().decode("utf-8", "replace")):
        return None
    return name


def legacy_until():
    """When the move from protocol 5 ends (epoch seconds), 0 when there is none."""
    try:
        return os.stat(os.path.join(DIR, LEGACY)).st_mtime + LEGACY_HOURS * 3600
    except OSError:
        return 0


def legacy_allowed(key):
    """May a protocol-5 listener still be sent this token (see the module notes)?"""
    if time.time() > legacy_until():
        return False
    try:
        with open(os.path.join(DIR, LEGACY)) as f:
            recorded = f.read().strip()
    except OSError:
        return False
    return bool(key) and same(recorded, hashlib.sha256(key).hexdigest())


def drop_legacy():
    try:
        os.unlink(os.path.join(DIR, LEGACY))
    except OSError:
        pass


def parse_ping(text):
    """'ok proto=7 proof=...' -> {'proto': 7, 'proof': '...', ...}"""
    out = {}
    for word in (text or "").split():
        name, sep, value = word.partition("=")
        if sep:
            out[name] = value
    m = re.match(r"[0-9]{1,4}", out.get("proto", ""))
    out["proto"] = int(m.group(0)) if m else 0
    return out


def ping_query(challenge, name):
    return "c=" + challenge + ("&k=" + name if name else "")


def proves(info, key, challenge, name):
    """Does a /ping answer prove the listener holds this key (under this name)?"""
    return bool(key) and name is not None and info["proto"] >= (7 if name else 6) \
        and same(info.get("proof", ""), ping_proof(key, challenge, name))


def addresses():
    """The loopback addresses `localhost` stands for here, in the system's order."""
    found = []
    try:
        for info in socket.getaddrinfo("localhost", PORT, 0, socket.SOCK_STREAM):
            if info[4][0] not in found:
                found.append(info[4][0])
    except OSError:
        pass
    return found or ["127.0.0.1"]


def exchange(addr, method, target, body=None, headers=None, timeout=5.0):
    """One request to addr:PORT. -> (status, the first 4 kB of the answer)"""
    conn = http.client.HTTPConnection(addr, PORT, timeout=timeout)
    try:
        conn.request(method, target, body=body, headers=headers or {})
        r = conn.getresponse()
        return r.status, r.read(4096).decode("utf-8", "replace")
    finally:
        conn.close()


def ping(timeout=2.0):
    """Ask each loopback address for a proof. -> dict (proto, verified, addr, ...)
    for the first listener that proves itself, else for the first one that
    answered at all; None when nothing answers."""
    key, name = token_key(), key_name()
    first = None
    for addr in addresses():
        challenge = secrets.token_hex(16)
        try:
            status, text = exchange(addr, "GET", "/ping?" + ping_query(challenge, name or ""), timeout=timeout)
        except (OSError, http.client.HTTPException):
            continue
        if status != 200:
            continue
        info = parse_ping(text)
        info["addr"] = addr
        info["verified"] = proves(info, key, challenge, name)
        if info["verified"]:
            return info
        if first is None:
            first = info
    return first


def decide(info, key, name):
    """-> (how to send: "signed", "shared", "legacy", or None when not at all; the reason)"""
    if not key:
        return None, "no_token"
    if name is None:
        return None, "bad_key_name"
    if info is None:
        return None, "unreachable"
    if info["verified"]:
        return ("signed" if name else "shared"), "ok"
    if not name and info["proto"] == 5 and legacy_allowed(key):
        return "legacy", "ok"
    if info.get("key") == "unknown":
        return None, "key_unknown_at_listener"      # never issued there, or revoked
    if info.get("shared") == "none":
        return None, "no_key_for_this_machine"      # the shared key is retired; this machine has none of its own
    if info.get("auth") == "none":
        return None, "listener_has_no_token"        # a protocol-6 listener without a token
    if name and info["proto"] == 6:
        return None, "old_listener_proto6"          # a key of its own needs protocol 7 at the Mac
    if info["proto"] >= 6:
        # It answers like a listener but cannot prove it holds our key: the two
        # ends have different keys, or someone else holds the port here.
        return None, "unverified"
    return None, "old_listener_proto%d" % info["proto"]


def send(act, fields, body=b"", timeout=5.0):
    """-> (HTTP status or 0, reason, how it was authenticated)"""
    key, name = token_key(), key_name()
    info = ping(min(timeout, 2.0)) if key and name is not None else None
    how, why = decide(info, key, name)
    if how is None:
        return 0, why, "-"
    path = "/" + act
    query = urlencode([(n, v) for n, v in fields if v], quote_via=quote)
    headers = {"Content-Type": "text/plain; charset=utf-8"}
    if how == "legacy":
        headers["X-CC-Token"] = key.decode("utf-8", "replace")
    else:
        drop_legacy()
        t, nonce = int(time.time()), secrets.token_hex(16)
        headers.update({"X-CC-Time": str(t), "X-CC-Nonce": nonce,
                        "X-CC-Sig": request_sig(key, "POST", path, query, body, t, nonce, name)})
        if name:
            headers["X-CC-Key"] = name
    try:
        status, _ = exchange(info["addr"], "POST", path + ("?" + query if query else ""),
                             body=body, headers=headers, timeout=timeout)
    except socket.timeout:
        return 0, "timeout", how
    except (OSError, http.client.HTTPException):
        return 0, "unreachable", how
    return status, "ok" if status == 200 else "http_%d" % status, how


class OutOfTime(Exception):
    pass


def _out_of_time(*_):
    raise OutOfTime()


def main(argv):
    os.umask(0o077)
    cmd = argv[1] if len(argv) > 1 else ""
    try:
        timeout = min(max(float(os.environ.get("CC_NOTIFY_TIMEOUT") or 5), 0.5), 30.0)
    except ValueError:
        timeout = 5.0
    # The socket timeouts bound each step; this bounds the whole call (a listener
    # that trickles its answer byte by byte could otherwise hold it much longer).
    ping_budget = 2 * min(timeout, 2.0)                  # up to two loopback addresses
    budget = {"send": ping_budget + timeout + 1, "ping": ping_budget + 1}.get(cmd, 3)
    signal.signal(signal.SIGALRM, _out_of_time)
    signal.setitimer(signal.ITIMER_REAL, budget)
    try:
        return run(cmd, argv, timeout)
    except OutOfTime:
        print("http=000 err=timeout auth=-" if cmd == "send" else "unreachable (timed out)")
        return 1


def run(cmd, argv, timeout):
    if cmd == "send" and len(argv) == 3 and argv[2] in ACTS:
        body = b""
        if os.environ.get("CC_F_BODY_FILE"):
            try:
                with open(os.environ["CC_F_BODY_FILE"], "rb") as f:
                    body = f.read(MAX_POST)
            except OSError:
                body = b""
        elif os.environ.get("CC_F_BODY"):
            body = os.environ["CC_F_BODY"].encode("utf-8", "replace")[:MAX_POST]
        fields = [(name, os.environ.get(var, "")) for name, var in FIELDS]
        status, why, how = send(argv[2], fields, body, timeout)
        print("http=%03d err=%s auth=%s" % (status, why, how))
        return 0 if status == 200 else 1
    if cmd == "ping" and len(argv) == 2:
        key, name = token_key(), key_name()
        info = ping(min(timeout, 2.0)) if key and name is not None else None
        how, why = decide(info, key, name)
        if info is None and why == "unreachable":
            print("unreachable")
            return 1
        line = "proto=%d verified=%s as=%s why=%s" % (
            info["proto"] if info else 0, "yes" if info and info["verified"] else "no",
            name if name else ("shared" if name == "" else "?"), why)
        if how == "legacy":
            line += " legacy=yes until=" + time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(legacy_until()))
        print(line)
        return 0 if info and info["verified"] else 1
    if cmd == "challenge" and len(argv) in (2, 3):
        name = argv[2] if len(argv) == 3 else (key_name() or "")
        if name and not valid_name(name):
            return 2
        print(ping_query(secrets.token_hex(16), name))
        return 0
    if cmd == "verify" and len(argv) == 3:
        q = parse_qs(argv[2])
        challenge, name = q.get("c", [""])[0], q.get("k", [""])[0]
        info = parse_ping(sys.stdin.read(4096))
        if name and name != key_name() and valid_name(name):
            try:                                   # on the Mac: a host's key, to check that host's tunnel
                with open(os.path.join(DIR, "keys", name), "rb") as f:
                    key = f.read().strip()
            except OSError:
                key = b""
        else:
            key = token_key() if name == (key_name() or "") else b""
        ok = bool(CHALLENGE.match(challenge)) and proves(info, key, challenge, name)
        return 0 if ok else 1
    if cmd == "version" and len(argv) == 2:
        print(PROTO)
        return 0
    sys.stderr.write(__doc__[__doc__.index("usage:"):])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
CCN_EOF_cc_client_py
  cat > "$DIR/cc_codex_hooks.sh" <<'CCN_EOF_cc_codex_hooks_sh'
#!/bin/bash
# Turn round-end notifications for Codex on or off. Usage: cc_codex_hooks.sh [on|off|status]
#
# Codex reads hooks of the same shape as Claude Code's from ~/.codex/hooks.json and
# hands them the same kind of payload, so it gets the same two scripts:
#   UserPromptSubmit -> notify_stop.sh codex        Stop -> notify_done.sh codex
# `on` appends them after whatever is in the file; nothing already there is moved or
# changed, and the previous file is kept as hooks.json.bak-cc-notifier. `off` takes
# them out again. Codex decides when a hook runs: it asks you to review hooks first,
# and it needs `codex_hooks = true` under [features] in ~/.codex/config.toml. This
# script changes neither.
HERE="$(cd "$(dirname "$0")" && pwd)"
CODEX="${CODEX_HOME:-$HOME/.codex}"
ACT="${1:-status}"
case "$ACT" in on|off|status) ;; *) echo "usage: $0 [on|off|status]"; exit 2;; esac
[ -d "$CODEX" ] || { echo "Codex is not set up here ($CODEX not found)."; exit 1; }
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
"$PYBIN" - "$CODEX/hooks.json" "$HERE" "$ACT" <<'PY' || exit $?
import json, os, shutil, sys
path, d, act = sys.argv[1:4]
cmds = {"UserPromptSubmit": os.path.join(d, "notify_stop.sh") + " codex",
        "Stop": os.path.join(d, "notify_done.sh") + " codex"}

def stop(msg, code=1):
    print(msg)
    sys.exit(code)

existed = True
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg, existed = {}, False
except Exception as e:
    stop("%s could not be read as JSON (%s); left untouched." % (path, e))
hooks = cfg.setdefault("hooks", {}) if isinstance(cfg, dict) else None
if not isinstance(hooks, dict) or not all(isinstance(hooks.get(ev, []), list) for ev in cmds):
    stop("%s has an unexpected layout; left untouched." % path)

def has(group, cmd):
    return isinstance(group, dict) and any(isinstance(h, dict) and h.get("command") == cmd for h in group.get("hooks") or [])

present = [ev for ev, cmd in cmds.items() if any(has(g, cmd) for g in hooks.get(ev, []))]
if act == "status":
    stop("Codex hooks: %d/%d in %s" % (len(present), len(cmds), path), 0 if len(present) == len(cmds) else 3)
changed = []
for ev, cmd in cmds.items():
    if act == "on" and ev not in present:
        hooks.setdefault(ev, []).append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
        changed.append(ev)
    elif act == "off" and ev in present:
        for g in hooks[ev]:
            if has(g, cmd):
                g["hooks"] = [h for h in g["hooks"] if not (isinstance(h, dict) and h.get("command") == cmd)]
        hooks[ev] = [g for g in hooks[ev] if not (isinstance(g, dict) and g.get("hooks") == [])]
        if not hooks[ev]:
            del hooks[ev]
        changed.append(ev)
if not changed:
    stop("Codex hooks already %s in %s" % ("present" if act == "on" else "absent", path), 0)
if existed:
    shutil.copy2(path, path + ".bak-cc-notifier")
with open(path + ".tmp", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(path + ".tmp", path)
print("Codex: %s hooks %s %s" % (" + ".join(changed), "added to" if act == "on" else "removed from", path))
PY
if [ "$ACT" = on ]; then
  echo "Codex runs hooks only after you have reviewed them there. If it says hooks need review (the new ones, or earlier ones again), approve them in Codex."
  grep -Eqs '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$CODEX/config.toml" \
    || echo "Hooks also need 'codex_hooks = true' under [features] in $CODEX/config.toml."
fi
exit 0
CCN_EOF_cc_codex_hooks_sh
  cat > "$DIR/cc_doctor.sh" <<'CCN_EOF_cc_doctor_sh'
#!/bin/bash
# Diagnose the whole cc-notifier chain. Run on either end (it adapts to the OS).
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
PORT="${CC_NOTIFY_PORT:-28765}"
OS="$(uname -s)"
g='\033[32m'; r='\033[31m'; y='\033[33m'; z='\033[0m'
ok(){   printf "  ${g}OK${z}  %s\n" "$*"; }
bad(){  printf "  ${r}XX${z}  %s\n" "$*"; }
warn(){ printf "  ${y}??${z}  %s\n" "$*"; }
note(){ printf "  ..  %s\n" "$*"; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
hc(){ curl -s --noproxy '*' --max-time 4 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }
# Asks the listener to prove it holds this machine's token; sends nothing else and
# rings nothing. The token never travels and never appears on a command line.
ping_out="$(CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" ping 2>/dev/null)"
if [ -f "$DIR/cc_alarm_listener.py" ]; then FIX="on this Mac: cc_token.sh new"; else FIX="on the Mac: cc_token.sh push <this host>"; fi

printf "cc-notifier doctor — %s (%s)\n" "$(uname -n)" "$OS"

# --- listener reachable (on a remote this also proves the tunnel) ---
code="$(hc "http://localhost:${PORT}/ping")"
if [ "$code" = 200 ]; then ok "listener reachable on localhost:${PORT}"
else bad "listener NOT reachable (HTTP ${code:-none})"
  if [ "$OS" = Darwin ]; then note "fix: launchctl load ~/Library/LaunchAgents/com.ccnotifier.listener.plist"
  else note "fix (tunnel down): from your Mac  ssh -O forward -R ${PORT}:localhost:${PORT} <host>"; fi
fi

# --- listener version + auth (signed requests; the listener proves it holds the token) ---
if [ "$code" = 200 ]; then
  case "$ping_out" in
    proto=*\ verified=yes\ as=shared*) warn "listener holds the key all machines share (${ping_out%% *}); requests are signed, but give this machine its own key — on the Mac: cc_token.sh push <this host>";;
    proto=*\ verified=yes*) ok "listener is current and holds this machine's own key (${ping_out%% why=*}): requests are signed, the key never travels";;
    *legacy=yes*) warn "listener is protocol 5: it still gets the old token in a header — re-run install.sh on the Mac, then there: cc_token.sh rotate <this host>";;
    *why=no_token*|*why=bad_key_name*) bad "no usable key on this machine ($DIR/token, $DIR/key-name): nothing is sent — $FIX";;
    *why=key_unknown_at_listener*|*why=no_key_for_this_machine*) bad "the listener takes no key from this machine on this port (${ping_out##*why=}; or someone else holds port ${PORT} here): nothing is sent — $FIX";;
    *why=listener_has_no_token*) bad "the listener has no token, so it refuses everything — re-run install.sh on the Mac";;
    *why=old_listener*) bad "listener is older than these hooks (${ping_out%% *}), so nothing is sent to it — re-run install.sh on the Mac";;
    *) bad "the listener cannot prove it holds this machine's key (${ping_out:-no answer}): the keys differ (on the Mac: cc_token.sh push <this host>) or someone else holds port ${PORT} here — nothing is sent to it";;
  esac
fi
[ "$("$PYBIN" "$DIR/cc_hook.py" check 2>/dev/null)" = "ok" ] && ok "hook helper runs ($PYBIN cc_hook.py)" \
  || bad "hook helper cannot run ($PYBIN $DIR/cc_hook.py) — hooks fall back to always notifying, no brief"
n="$(find "$DIR/sessions" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
note "per-session state: ${n} session(s) in $DIR/sessions; decisions are logged in $DIR/hook.log"

# --- keys the listener takes (Mac) ---
if [ -d "$DIR/keys" ]; then
  note "keys the listener takes (cc_token.sh keys): $("$DIR/cc_token.sh" keys 2>/dev/null | awk '{printf "%s=%s ", $1, $3}')"
  [ -e "$DIR/keys/shared" ] && warn "the key all machines shared before is still taken on port ${PORT} — give each remote its own (cc_token.sh push <host>...), then: cc_token.sh revoke shared"
fi

# --- private files: the keys, the config (Telegram bot token), the message texts ---
for f in "$DIR" "$DIR/token" "$DIR/key-name" "$DIR/keys" "$DIR"/keys/* "$DIR/ports" "$DIR/config" "$DIR/sessions" "$DIR/tmp" "$DIR/listener.log" "$DIR/tunnel.log"; do
  [ -e "$f" ] || continue
  m="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)"
  case "$m" in 700|600|500|400) ;; *) bad "$f is readable by others (mode $m) — chmod go= $f";; esac
done

# --- arm + hooks ---
[ -f "$DIR/armed" ] && note "armed (long alarm)" || note "disarmed (short chime)"
S="$HOME/.claude/settings.json"
if command -v python3 >/dev/null 2>&1 && [ -f "$S" ]; then
  n="$(python3 -c "import json;d=json.load(open('$S'));print(sum('/.cc-notifier/' in h.get('command','') for e in d.get('hooks',{}).values() for grp in e for h in grp.get('hooks',[])))" 2>/dev/null)"
  [ "${n:-0}" -ge 4 ] && ok "CC hooks wired (${n}/4 in user settings)" \
                      || warn "CC hooks: ${n:-0}/4 in $S — run install.sh, then restart CC"
fi
if [ -d "${CODEX_HOME:-$HOME/.codex}" ] && [ -x "$DIR/cc_codex_hooks.sh" ]; then
  if st="$("$DIR/cc_codex_hooks.sh" status 2>/dev/null)"; then ok "$st (Codex runs them once you have reviewed them there)"
  else note "${st:-Codex hooks: not readable} — for round-end notifications from Codex: $DIR/cc_codex_hooks.sh on"; fi
fi

# --- receiver-only checks ---
if [ "$OS" = Darwin ]; then
  c4="$(hc -4 "http://localhost:${PORT}/ping")"; c6="$(hc -6 "http://localhost:${PORT}/ping")"
  { [ "$c4" = 200 ] && [ "$c6" = 200 ]; } && ok "listening on both IPv4 + IPv6 loopback" \
                                          || warn "loopback v4=$c4 v6=$c6 — ssh may forward to the missing family"
  if command -v alerter >/dev/null 2>&1 || [ -x /opt/homebrew/bin/alerter ] || [ -x /usr/local/bin/alerter ]
    then ok "alerter installed"; else bad "alerter missing -> brew install vjeantet/tap/alerter"; fi
  hk="$(python3 "$DIR/cc_hotkey.py" 2>/dev/null)"
  [ -n "$hk" ] && ok "Karabiner stop hotkey: $hk" \
               || warn "no Karabiner stop rule found — enable it in Karabiner › Complex Modifications"
  launchctl list 2>/dev/null | grep -q ccnotifier && ok "launchd listener agent loaded" \
                                                   || warn "launchd agent not loaded (launchctl load …com.ccnotifier.listener.plist)"
  ( [ -f "$DIR/config" ] && . "$DIR/config"
    if [ -n "${CC_TELEGRAM_TOKEN:-}" ] && [ -n "${CC_TELEGRAM_CHAT_ID:-}" ]; then
      # The bot token is part of the URL: curl reads it on stdin, not from its command line.
      printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$CC_TELEGRAM_TOKEN" | curl -s --max-time 6 --config - \
        | grep -q '"ok":true' && ok "Telegram bot reachable + token valid" || warn "Telegram configured but getMe failed (token/network)"
    else note "Telegram push not configured (optional)"; fi )
  note "alerter notification permission + Focus allow-list can't be checked here — verify by running: $DIR/cc_tunnel_test.sh alarm"
else
  note "run doctor on your Mac too for receiver checks (alerter, Karabiner, launchd, Telegram)"
fi
CCN_EOF_cc_doctor_sh
  cat > "$DIR/cc_hook.py" <<'CCN_EOF_cc_hook_py'
#!/usr/bin/env python3
"""Per-session decisions for the cc-notifier hooks (sender side).

Works for any agent whose hooks hand over a Claude Code style JSON payload
(`session_id`, `prompt`, `last_assistant_message`, ...): Claude Code and Codex do.

Every session keeps its own state file, <dir>/sessions/<session_id>.json, so one
session's prompts, stops and background tasks never change what another
session's hooks decide:

  turn_start   when the current turn began
  human_start  when a person last typed a prompt in this session
  busy         a turn is in progress (a prompt started it, no Stop since)
  owed         an earlier Stop stayed silent because background work was in flight
  alarm        this session raised an alarm that has not been cancelled yet
  title        the session title the agent reports
  seq          counts this session's prompts and stops (tells a pause from a resume)
  seen         when each background task was first seen in flight at a stop
  told_at      when this session last notified
  pending      the notice to send if the pause after a held stop lasts too long
  paused_told  a "still waiting" notice went out since the last full notification

usage: cc_hook.py prompt [agent] | done <alarm|beep> [agent] | ask [agent] | check
       (hook payload on stdin; `agent` names who is calling, e.g. codex)
       cc_hook.py late <alarm|beep> <session_id> <seq>     (no payload; see notify_done.sh)

Prints one field per line for the calling hook script. On any failure it prints
nothing, and the callers then notify without a summary (never over-suppress).
The message itself, for the phone push, has line breaks, so it goes into files:
<dir>/sessions/<session_id>.body (whole) and .short (its first 3,400 characters,
for a listener that cannot take the whole). Their paths are the last two fields.
"""
import json
import os
import re
import socket
import subprocess
import sys
import time


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


DIR = os.environ.get("CC_NOTIFIER_DIR") or os.path.join(os.path.expanduser("~"), ".cc-notifier")
STATE_DIR = os.path.join(DIR, "sessions")
MIN_SECONDS = _env_int("CC_NOTIFY_MIN_SECONDS", 20)
BRIEF_CHARS = _env_int("CC_NOTIFY_BRIEF_CHARS", 240)   # longest summary; one sentence is rarely longer
# The phone push carries more than the alert can show: the final message itself as
# plain text. The receiver splits it over as many Telegram messages as it takes,
# so this bound is only a guard against a runaway output.
BODY_CHARS = min(_env_int("CC_NOTIFY_BODY_CHARS", 40000), 60000)
SHORT_CHARS = 3400       # what a listener older than protocol 5 can show
TITLE_CHARS = 60
# Background-task types that do not hold a notification back. A `monitor` is an
# open-ended watch (e.g. "live updates for artifact ..."): it never finishes, so a
# session holding one would otherwise never notify.
STANDBY_IGNORE = set(os.environ.get("CC_NOTIFY_STANDBY_IGNORE", "monitor").lower().replace(",", " ").split())
# A session's own background work holds its notification back, but not for ever.
# PAUSE_SECONDS: a pause that lasts this long is reported ("still waiting on ...").
# QUIET_SECONDS: the longest that background work can keep a session quiet. A task
# in flight for that long (a standing watcher, a wait for a queued job) no longer
# holds anything, and a session that has not notified for that long reports its
# next round end even while younger work is in flight. 0 switches a rule off.
PAUSE_SECONDS = _env_int("CC_NOTIFY_PAUSE_SECONDS", 300)
QUIET_SECONDS = _env_int("CC_NOTIFY_QUIET_SECONDS", 1800)
# `source` values Claude Code uses for prompts it injects itself.
MACHINE_SOURCES = ("system", "loop_wakeup", "schedule_wakeup", "poll_event")
# What a hook command may call its agent (`notify_done.sh codex`) -> name shown.
AGENTS = {"claude": "Claude Code", "claude-code": "Claude Code", "cc": "Claude Code", "codex": "Codex"}
# A period after one of these does not end a sentence.
ABBREVIATIONS = ("e.g", "i.e", "etc", "vs", "cf", "al", "approx", "fig", "figs", "sec", "eq", "no", "nos",
                 "dr", "mr", "mrs", "ms", "st", "inc", "ltd", "resp", "ca")
SENTENCE_END = re.compile(r"[.!?]+[\"')\]”’]*(?=\s+[\"'(\[“‘]?[A-Z0-9])|[。！？]")
AUDIENCE = re.compile(r"(?i)^written for:.*?(?:[.!?](?=\s|$)|$)\s*")


# --- small helpers -----------------------------------------------------------

def one_line(s):
    """One printable line: line breaks and control characters become spaces."""
    return " ".join("".join(c if c.isprintable() else " " for c in str(s)).split())


def as_list(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def session_key(d):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(d.get("session_id") or ""))[:64]


def state_path(sid):
    return os.path.join(STATE_DIR, sid + ".json")


def load(sid):
    if not sid:
        return {}
    try:
        with open(state_path(sid)) as f:
            st = json.load(f)
    except Exception:
        return {}
    return st if isinstance(st, dict) else {}


def save(sid, st):
    if not sid:
        return
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = "%s.tmp.%d" % (state_path(sid), os.getpid())
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, state_path(sid))
    except Exception:
        pass


# --- text for the notification ---------------------------------------------

def clean(line):
    """Markdown line -> plain text."""
    s = re.sub(r"^\s*>+\s?", "", line)                         # quote
    s = re.sub(r"^\s*#+\s*", "", s)                            # heading
    s = re.sub(r"^\s*(?:[-*+•]|\d+[.)])\s+(?:\[[ xX]\]\s+)?", "", s)  # list marker, checkbox
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", s)           # [text](url) -> text
    s = re.sub(r"</?[A-Za-z][\w-]*(?:\s[^<>]*)?/?>", "", s)    # html-like tags
    s = s.replace("**", "").replace("`", "")
    return one_line(s)


def blocks(msg):
    """Cleaned blocks of a message in order: ("p", prose paragraph or list item)
    and ("h", heading or table row). Code blocks are dropped."""
    para, fenced = [], False
    for raw in str(msg or "")[:20000].splitlines() + [""]:   # the brief comes from the start
        line = raw.strip()
        if line.startswith(("```", "~~~")):
            fenced, line = not fenced, ""
        elif fenced:
            line = ""
        kind = ("h" if re.match(r"#{1,6}\s|\||[-=*_ ]{3,}$", line) else
                "i" if re.match(r"(?:[-*+•]|\d+[.)])\s", line) else
                "p" if line else "")
        if kind == "p":
            para.append(clean(line))
            continue
        if para:
            yield "p", one_line(" ".join(para))
            para = []
        if kind:
            yield ("p" if kind == "i" else "h"), clean(line.strip("| "))


def first_sentence(text, least=12):
    """The first sentence of a paragraph; more than one while they are too short
    to say anything ("Done. All four runs passed.")."""
    text = one_line(text)
    for m in SENTENCE_END.finditer(text):
        word = re.search(r"([^\s(\[\"']*?)[.!?]+[\"')\]”’]*$", text[:m.end()])
        token = word.group(1).lower() if word else ""
        if token in ABBREVIATIONS or re.match(r"[a-z]$", token):
            continue                              # "e.g. Foo", an initial: the sentence goes on
        if m.end() >= least:
            return text[:m.end()]
    return text


def summary(msg, limit):
    """One sentence for the notification: how the final message opens. Agents lead
    with the outcome, so this is the round's own summary. Code blocks, tables,
    headings and a "Written for: ..." audience sentence are skipped; a lead-in that
    only announces what follows ("Status:") takes the next block with it."""
    lead = fallback = ""
    for kind, text in blocks(msg):
        if kind == "h":
            if not fallback and re.search(r"\w", text):
                fallback = text
            continue
        if not lead:
            text = AUDIENCE.sub("", text)
            if not text:
                continue
        sentence = first_sentence(text)
        if not lead and sentence.endswith(":") and len(sentence) < 30:
            lead = sentence
            continue
        return shorten((lead + " " + sentence).strip(), limit)
    return shorten(lead or fallback, limit)


def table_lines(rows):
    """A markdown table as lines that read on a narrow screen. With a header row,
    each row becomes its first cell followed by "header: cell" lines."""
    cells = [[clean(c) for c in r.strip().strip("|").split("|")] for r in rows]
    is_rule = lambda r: bool(r) and all(re.match(r":?-{2,}:?$", c) for c in r)
    if len(cells) < 3 or not is_rule(cells[1]):
        return [" | ".join(c for c in r if c) for r in cells if not is_rule(r)]
    head, out = cells[0], []
    for r in cells[2:]:
        if len(head) == 2:
            out.append("\u2022 " + ": ".join(c for c in r if c))
            continue
        out.append("\u2022 " + (r[0] if r else ""))
        out.extend("   %s: %s" % (h_, c) if h_ else "   " + c for h_, c in zip(head[1:], r[1:]) if c)
    return out


def plain(msg, limit):
    """The message as plain text for the phone push: markdown marks dropped, lists,
    paragraphs and code kept line by line, tables turned into lines. Over the
    limit it is cut at a line, and the last line says how much is left."""
    if limit <= 0:
        return ""
    out, fenced, table = [], False, []
    for raw in str(msg or "").splitlines() + [""]:
        line = raw.strip()
        if table and not (line.startswith("|") and not fenced):
            out.extend(table_lines(table))
            table = []
        if line.startswith(("```", "~~~")):
            fenced = not fenced
        elif fenced:
            out.append(one_line(raw.rstrip()) if raw.strip() else "")
        elif line.startswith("|"):
            table.append(line)
        elif not line or re.match(r"[-=*_ ]{3,}$", line):         # blank line, rule
            out.append("")
        else:
            item = re.match(r"([-*+\u2022]|\d+[.)])\s+(.*)", line)
            indent = " " * min(len(raw) - len(raw.lstrip()), 6)
            if item:
                mark = item.group(1) + " " if item.group(1)[0].isdigit() else "\u2022 "
                out.append(indent + mark + clean(item.group(2)))
            else:
                out.append(clean(line))
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()
    text = AUDIENCE.sub("", text, count=1).lstrip()             # an opening "Written for: ..." sentence
    if len(text) <= limit:
        return text
    cut = text[:limit]
    at = cut.rfind("\n")
    if at < limit * 0.6:
        at = cut.rfind(" ")
    cut = cut[:at if at > 0 else limit].rstrip()
    return "%s\n\u2026 (%d more characters in the session)" % (cut, len(text) - len(cut))


def shorten(s, n):
    """At most n characters: ends at a sentence when one fits, else at a word plus an ellipsis."""
    s = one_line(s)
    if n <= 0:
        return ""
    if len(s) <= n:
        return s
    ends = [m.end() for m in re.finditer(r"[.!?](?=\s)|[。！？]", s[:n + 1]) if m.end() <= n]
    if ends and ends[-1] >= 12:
        return s[:ends[-1]]
    cut = s[:n - 1]
    sp = cut.rfind(" ")
    if sp >= n * 0.6:
        cut = cut[:sp]
    return cut.rstrip(" ,;:—-") + "…"


def transcript_title(path):
    """Latest session title recorded near the end of the transcript."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 262144))
            tail = f.read().decode("utf-8", "replace")
    except Exception:
        return ""
    for line in reversed(tail.splitlines()):
        if "-title" not in line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if isinstance(e, dict) and e.get("type") in ("ai-title", "custom-title"):
            t = e.get("customTitle") or e.get("aiTitle") or e.get("title")
            if t:
                return one_line(t)
    return ""


def codex_thread_name(sid):
    """Codex keeps thread names in $CODEX_HOME/session_index.jsonl; the latest entry wins."""
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    try:
        with open(os.path.join(home, "session_index.jsonl"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 262144))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except Exception:
        return ""
    for line in reversed(lines):
        if sid not in line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if isinstance(e, dict) and e.get("id") == sid and e.get("thread_name"):
            return one_line(e["thread_name"])
    return ""


def session_title(d, st, sid):
    """Session title as the agent records it now (Claude Code: transcript; Codex:
    thread index), else the one last seen in a prompt payload."""
    title = transcript_title(d.get("transcript_path") or "") or (codex_thread_name(sid) if sid else "")
    if title:
        st["title"] = title
    return shorten(title or st.get("title") or "", TITLE_CHARS)


def agent_name(arg, d):
    """Who is notifying. The hook command names its agent (`notify_done.sh codex`);
    without that it is read off the payload."""
    arg = one_line(arg or "")
    if arg:
        return AGENTS.get(arg.lower(), arg)[:32]
    return "Codex" if "/.codex/" in str(d.get("transcript_path") or "") else "Claude Code"


def label(d):
    """host/project, from the session's working directory."""
    cwd = str(d.get("cwd") or "") or os.getcwd()
    return "%s/%s" % (socket.gethostname().split(".")[0] or "host", os.path.basename(cwd.rstrip("/")))


# --- decisions (pure: payload + state in, verdict out; state is updated in place) ---

def prompt_kind(d):
    """Who sent this prompt. An agent fires the prompt hook for a person's message
    and for its own: a subagent's turn, and in Claude Code a finished background
    task, another session handing back, a scheduled wake-up."""
    if d.get("agent_id"):
        return "subagent"
    if d.get("source") in MACHINE_SOURCES:
        return str(d.get("source"))
    head = str(d.get("prompt") or "").lstrip()[:300]
    if head.startswith("<task-notification"):
        return "task-notification"
    if "<agent-message from=" in head:
        return "agent-message"
    if "<cross-session-message from=" in head:
        return "session-message"
    return "typed"


def decide_prompt(d, st, now):
    """-> (cancel this session's alarm?, log text)"""
    kind = prompt_kind(d)
    cancel = False
    st["seq"] = st.get("seq", 0) + 1              # the session is no longer paused
    st.pop("pending", None)
    if kind == "typed":
        # A person is at this session: restart its clocks, and its alarm has been seen.
        cancel = bool(st.get("alarm"))
        st.update(turn_start=now, human_start=now, busy=True, owed=False, alarm=False, paused_told=False)
        turn = "started"
    elif not st.get("busy"):
        st.update(turn_start=now, busy=True)      # the agent woke the session itself
        turn = "started"
    else:
        turn = "running"                          # delivered mid-turn: the clock keeps running
    title = one_line(d.get("session_title") or "")
    if title:
        st["title"] = title
    return cancel, "kind=%s turn=%s" % (kind, turn)


def task_type(t):
    return str(t.get("type") or "").lower() if isinstance(t, dict) else "?"


def describe(t):
    if not isinstance(t, dict):
        return "?"
    desc = one_line(t.get("description") or t.get("command") or t.get("tool") or t.get("name") or "")[:60]
    text = "%s/%s%s" % (t.get("type"), t.get("status"), (":" + desc) if desc else "")
    return text + (" (not held)" if task_type(t) in STANDBY_IGNORE else "")


def task_key(t):
    return str(t.get("id") or t.get("description") or t.get("command") or "?")[:80] if isinstance(t, dict) else "?"


def decide_done(d, st, now, act):
    """-> (verdict, why, what was in flight); the last two are log text. Verdict:
    "notify"; "silent"; "held" (silent now, background work is in flight); or
    "progress" (work is in flight, but the session has been quiet for too long)."""
    tasks = as_list(d.get("background_tasks"))
    info = "cwd=%s bg=%d crons=%d" % (
        str(d.get("cwd") or "").rstrip("/").split("/")[-1], len(tasks), len(as_list(d.get("session_crons"))))
    if tasks:
        info += " bg_tasks=[%s]" % "; ".join(describe(t) for t in tasks[:6])
    if d.get("stop_hook_active"):                 # forced continuation: the turn goes on
        return "silent", "reason=stop_hook_active", info
    st["busy"] = False
    st["seq"] = st.get("seq", 0) + 1
    st.pop("pending", None)
    # Which of its own tasks still hold the notification: not the ignored types,
    # and not one that has been in flight for QUIET_SECONDS.
    seen, st["seen"], holding, old = st.get("seen") if isinstance(st.get("seen"), dict) else {}, {}, [], 0
    for t in tasks:
        if task_type(t) in STANDBY_IGNORE:
            continue
        first = seen.get(task_key(t), now)
        st["seen"][task_key(t)] = first
        if QUIET_SECONDS > 0 and now - first >= QUIET_SECONDS:
            old += 1
        else:
            holding.append(t)
    if old:
        info += " long_running=%d" % old
    if holding:
        st["owed"] = True                         # paused on its own work; it will be back
        quiet = None if last_contact(st) is None else now - last_contact(st)
        if PAUSE_SECONDS > 0 and QUIET_SECONDS > 0 and quiet is not None and quiet >= QUIET_SECONDS:
            if act != "beep":
                st["alarm"] = True
            st.update(told_at=now, paused_told=True)
            return "progress", "quiet=%ds" % quiet, info
        return "held", "reason=background_tasks", info
    # A stop that completes work an earlier stop left paused is timed from the
    # last prompt a person typed; any other stop from the start of its own turn.
    since = "last_typed_prompt" if st.get("owed") else "turn_start"
    ref = st.get("human_start") if st.get("owed") else st.get("turn_start")
    st["owed"] = False
    age = (now - ref) if isinstance(ref, (int, float)) else None
    if MIN_SECONDS > 0 and age is not None and 0 <= age < MIN_SECONDS:
        return "silent", "reason=quick_turn age=%ds min=%ds since=%s" % (age, MIN_SECONDS, since), info
    if act != "beep":
        st["alarm"] = True
    st.update(told_at=now, paused_told=False)
    return "notify", "age=%s since=%s" % ("?" if age is None else "%ds" % age, since), info


def last_contact(st):
    """When this session last notified, or a person last typed in it (None: unknown)."""
    known = [x for x in (st.get("told_at"), st.get("human_start")) if isinstance(x, (int, float))]
    return max(known) if known else None


def waiting_note(d, brief, body=None):
    """The summary of a round end that leaves background work in flight; with
    `body`, the same for the longer text (the note becomes its last paragraph)."""
    waiting = [t for t in as_list(d.get("background_tasks")) if task_type(t) not in STANDBY_IGNORE]
    first = one_line(waiting[0].get("description") or waiting[0].get("command") or "")[:60] if waiting and isinstance(waiting[0], dict) else ""
    note = "still waiting on %d background task%s%s" % (len(waiting), "" if len(waiting) == 1 else "s", (": " + first) if first else "")
    if body is not None:
        return (body + "\n\n" if body else "") + note[0].upper() + note[1:]
    return (brief + " \u2014 " + note) if brief else note[0].upper() + note[1:]


def plan_pause_notice(d, st, now, title, brief, agent, where, body=""):
    """After a held stop: remember what to say if the pause lasts too long, and how
    long that is. The first time in a round: PAUSE_SECONDS. After that: until the
    session has been quiet for QUIET_SECONDS (subagents handing back every few
    minutes should not each ring). -> (seconds to wait, seq to check then) or None."""
    if PAUSE_SECONDS <= 0 or (st.get("paused_told") and QUIET_SECONDS <= 0):
        return None
    wait = PAUSE_SECONDS
    if st.get("paused_told") and last_contact(st) is not None:
        wait = max(PAUSE_SECONDS, last_contact(st) + QUIET_SECONDS - now)
    st["pending"] = dict(seq=st.get("seq"), wait=wait, title=title, agent=agent, label=where,
                         brief=waiting_note(d, brief), body=waiting_note(d, brief, body) if body else "")
    return wait, st["pending"]["seq"]


def decide_late(st, seq, now, act):
    """The check after a held stop: still paused since then? -> notice or None."""
    notice = st.get("pending")
    if not isinstance(notice, dict) or notice.get("seq") != seq or st.get("seq") != seq or st.get("busy"):
        return None                               # it woke up meanwhile; its own stop decides
    del st["pending"]
    st.update(told_at=now, paused_told=True)
    if act != "beep":
        st["alarm"] = True
    return notice


def ask_brief(d):
    ti = d.get("tool_input")
    qs = [q for q in as_list(ti.get("questions") if isinstance(ti, dict) else None) if isinstance(q, dict)]
    if not qs:
        return ""
    more = " (+%d more)" % (len(qs) - 1) if len(qs) > 1 else ""
    return shorten(clean(str(qs[0].get("question") or qs[0].get("header") or "")), BRIEF_CHARS) + more


def ask_body(d):
    """The questions with their choices, for the phone push."""
    ti = d.get("tool_input")
    out = []
    for q in as_list(ti.get("questions") if isinstance(ti, dict) else None):
        if not isinstance(q, dict):
            continue
        out.append(clean(str(q.get("question") or q.get("header") or "")))
        for o in as_list(q.get("options")):
            if isinstance(o, dict) and o.get("label"):
                desc = clean(str(o.get("description") or ""))
                out.append("\u2022 " + clean(str(o["label"])) + ((": " + desc) if desc else ""))
        out.append("")
    return "\n".join(out).strip()[:BODY_CHARS] if BODY_CHARS > 0 else ""


def write_body(sid, text):
    """-> [path of the file with the whole body, path of the one with its opening]
    for this notification ("" where there is none)."""
    if not sid or not text:
        return ["", ""]
    short = text
    if len(text) > SHORT_CHARS:
        cut = text[:SHORT_CHARS]
        cut = cut[:cut.rfind("\n")].rstrip() if cut.rfind("\n") > SHORT_CHARS * 0.6 else cut
        short = "%s\n\u2026 (%d more characters in the session)" % (cut, len(text) - len(cut))
    paths = []
    for suffix, content in ((".body", text), (".short", short)):
        path = os.path.join(STATE_DIR, sid + suffix)
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            with open(path, "wb") as f:
                f.write(content.encode("utf-8", "replace"))
            paths.append(path)
        except Exception:
            paths.append("")
    return paths


# --- entry point -------------------------------------------------------------

def emit(*fields):
    out = "".join(one_line(f) + "\n" for f in fields)
    sys.stdout.buffer.write(out.encode("utf-8", "replace"))


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "check":
        emit("ok")
        return
    os.umask(0o077)
    now = int(time.time())
    if mode == "late":                            # cc_hook.py late <act> <session_id> <seq>
        act, sid, seq = argv[2], re.sub(r"[^A-Za-z0-9_-]", "", argv[3])[:64], int(argv[4])
        st = load(sid)
        notice = decide_late(st, seq, now, act)
        if notice is None:
            return
        save(sid, st)
        title, brief, body = str(notice.get("title") or ""), str(notice.get("brief") or ""), str(notice.get("body") or "")
        emit("notify", sid, title, brief, "session=%s agent=%s paused=%ss title=%dc brief=%dc body=%dc" % (
            sid[:8], str(notice.get("agent") or "?").split()[0].lower(), notice.get("wait", "?"), len(title), len(brief), len(body)),
            notice.get("agent") or "", notice.get("label") or "", *write_body(sid, body))
        return
    try:
        d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    except Exception:
        d = {}
    if not isinstance(d, dict):
        d = {}
    args = argv[2:]
    act = args.pop(0) if mode == "done" and args else "alarm"
    agent = agent_name(args[0] if args else "", d)
    sid = session_key(d)
    st = load(sid)
    tag = "session=%s agent=%s" % (sid[:8] or "?", agent.split()[0].lower())
    if mode == "prompt":
        cancel, info = decide_prompt(d, st, now)
        save(sid, st)
        emit("cancel" if cancel else "keep", sid, "%s %s" % (tag, info))
    elif mode == "done":
        verdict, why, info = decide_done(d, st, now, act)
        title = brief = body = ""
        check = None
        if verdict != "silent":
            title = session_title(d, st, sid)
            brief = summary(d.get("last_assistant_message"), BRIEF_CHARS)
            body = plain(d.get("last_assistant_message"), BODY_CHARS)
        if verdict == "progress":
            verdict, brief, body = "notify", waiting_note(d, brief), waiting_note(d, brief, body) if body else ""
        if verdict == "notify":
            info += " title=%dc brief=%dc body=%dc" % (len(title), len(brief), len(body))
        elif verdict == "held" and sid:
            check = plan_pause_notice(d, st, now, title, brief, agent, label(d), body)
            if check is not None:
                info += " notice_in=%ds" % check[0]
        save(sid, st)
        if check is not None:
            # Look again when the pause has lasted that long: a process of its own, so
            # it outlives this hook. It sends the notice only if nothing happened since.
            script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "notify_done.sh")
            try:
                subprocess.Popen(["/bin/bash", script, "--late", str(check[0]), sid, str(check[1])],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            except Exception:
                pass
        # log text: "reason=... session=..." when silent, "session=... age=..." when sent
        emit("notify" if verdict == "notify" else "silent", sid, title if verdict == "notify" else "",
             brief if verdict == "notify" else "",
             "%s %s %s" % ((tag, why, info) if verdict == "notify" else (why, tag, info)), agent, label(d),
             *(write_body(sid, body) if verdict == "notify" else ["", ""]))
    elif mode == "ask":
        st["alarm"] = True
        title, brief, body = session_title(d, st, sid), ask_brief(d), ask_body(d)
        save(sid, st)
        emit("notify", sid, title, brief, "%s title=%dc brief=%dc body=%dc" % (tag, len(title), len(brief), len(body)),
             agent, label(d), *write_body(sid, body))


if __name__ == "__main__":
    main(sys.argv)
CCN_EOF_cc_hook_py
  cat > "$DIR/cc_notify_arm.sh" <<'CCN_EOF_cc_notify_arm_sh'
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
CCN_EOF_cc_notify_arm_sh
  cat > "$DIR/cc_notify.sh" <<'CCN_EOF_cc_notify_sh'
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
CCN_EOF_cc_notify_sh
  cat > "$DIR/cc_token.sh" <<'CCN_EOF_cc_token_sh'
#!/bin/bash
# Manage the keys (protocol 7). The Mac's listener keeps one key per machine that
# may send to it (<dir>/keys/<name>) and, for each remote, the port its tunnel ends
# at (<dir>/ports/<name>); each machine keeps its own key in <dir>/token and its
# name in <dir>/key-name. Every request is signed with the key, which is never sent
# anywhere (cc_client.py). A key's name is the ssh alias it was issued to.
#
# Nothing here puts a key on a command line, where any user of a shared host could
# read it (or your shell history keep it): keys move over ssh, on standard input.
#
# On the Mac:
#   cc_token.sh push <host>...    give each ssh host its own key and port (made if it has none), send the key there
#   cc_token.sh rotate <host>...  a new key for each host; other machines are not touched
#   cc_token.sh revoke <host>...  forget a host's key: it can no longer send ("revoke shared": the shared key)
#   cc_token.sh keys              the machines that have a key, with their ports
#   cc_token.sh new               a new key for this Mac's own senders (the stop hotkey, local sessions)
# On a remote:
#   cc_token.sh set <name>        this machine's key, read from standard input, under <name>
#   cc_token.sh off               remove this machine's key: it sends nothing
# Anywhere:
#   cc_token.sh show              this machine's key name and key
# Names are lowercase ssh aliases (letters, digits, . _ -).
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
F="$DIR/token"; N="$DIR/key-name"; KEYS="$DIR/keys"; PORTS="$DIR/ports"
PORT="${CC_NOTIFY_PORT:-28765}"            # this Mac's own port; each remote gets one after it
RPORT="${CC_REMOTE_PORT:-28765}"           # the port the hooks use on a remote (the far end of its tunnel)
TUNNEL_PORTS="${CC_TUNNEL_PORTS:-$(seq $((PORT + 1)) $((PORT + 16)))}"   # the listener binds these, one per remote
HERE="$(cd "$(dirname "$0")" && pwd)"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
umask 077
export LC_ALL=C                            # character sets below mean ASCII, whatever the locale
mkdir -p "$DIR" && chmod 700 "$DIR" 2>/dev/null

# Run on the far end by ssh, through sh whatever the login shell there (no single
# quotes inside); its kit is in its own CC_NOTIFIER_DIR or ~/.cc-notifier.
KIT='d="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"'
remote(){ _rh="$1"; shift; ssh "$_rh" "sh -c '$KIT; $*'"; }
REMOTE_SWITCH='test -s "$d/token.new" && test -s "$d/key-name.new" && mv -f "$d/token.new" "$d/token" && mv -f "$d/key-name.new" "$d/key-name"'
REMOTE_UNSTAGE='rm -f "$d/token.new" "$d/key-name.new"'
REMOTE_VERSION='python3 "$d/cc_client.py" version 2>/dev/null'
REMOTE_PING='python3 "$d/cc_client.py" ping'
REMOTE_NAME='cat "$d/key-name" 2>/dev/null'

usage(){ sed -n '11,22s/^# \{0,1\}//p' "$0" >&2; exit 2; }
say(){ echo "$*" >&2; }
new_key(){ head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }        # 64 hex characters
put(){  # put <file>: standard input becomes <file>, private, all at once
  cat > "$1.tmp.$$" && [ -s "$1.tmp.$$" ] && chmod 600 "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1" \
    || { rm -f "$1.tmp.$$"; return 1; }
}
name_ok(){  # a key name: lowercase letters, digits, . _ - (cc_client.valid_name holds the same rule)
  case "$1" in ""|shared|local|*..*|*.new|*.tmp|*.bak|*.port|*.tmp.*) return 1;; [abcdefghijklmnopqrstuvwxyz0123456789]*) ;; *) return 1;; esac
  case "$1" in *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) return 1;; esac
  [ ${#1} -le 64 ] || return 1
  case "$1" in *[!0123456789abcdef]*) return 0;; esac     # all hex digits: fine if short, refused if it looks like a key
  [ ${#1} -lt 24 ]
}
is_mac(){ [ -f "$DIR/cc_alarm_listener.py" ]; }
need_mac(){ is_mac || { say "keys are issued on the Mac (where the listener runs): run this there"; exit 2; }; }
local_ok(){  # does the listener here prove it holds this Mac's own key (protocol 7)?
  case "$(CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" ping 2>/dev/null)" in
    proto=*\ verified=yes\ as=local\ *) return 0;; *) return 1;;
  esac
}
remote_ready(){  # does <host> run a sender that can use a key of its own (protocol 7)?
  v="$(remote "$1" "$REMOTE_VERSION" 2>/dev/null)"
  case "$v" in [7-9]|[1-9][0-9]) return 0;; *) return 1;; esac
}
port_of(){  # port_of <host>: the Mac port its tunnel ends at, assigned now if it has none
  [ -s "$PORTS/$1" ] && { cat "$PORTS/$1"; return 0; }
  # One assignment at a time (mkdir is atomic): two runs must never hand out one port twice.
  n=0; until mkdir "$PORTS/.lock" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -ge 50 ] && { say "  ports are locked ($PORTS/.lock): another cc_token.sh is running, or remove it"; return 1; }
    sleep 0.1
  done
  rc=1
  for p in $TUNNEL_PORTS; do
    if ! grep -qx "$p" "$PORTS"/* 2>/dev/null; then echo "$p" | put "$PORTS/$1" && echo "$p" && rc=0; break; fi
  done
  rmdir "$PORTS/.lock"; return $rc
}
retarget(){  # point <host>'s live tunnel at <port> (through the ssh master; no new connection)
  ssh -O check "$1" >/dev/null 2>&1 || return 1
  ssh -O cancel -R "$RPORT:localhost:$PORT" "$1" >/dev/null 2>&1
  ssh -O cancel -R "$RPORT:localhost:$2" "$1" >/dev/null 2>&1
  ssh -O forward -R "$RPORT:localhost:$2" "$1" >/dev/null 2>&1
}

# give <host> <rotate:0|1>: stage the key there, then switch both ends, then its tunnel.
give(){
  h="$1"; k="$KEYS/$h"
  other="$(remote "$h" "$REMOTE_NAME" 2>/dev/null)"
  if name_ok "$other" && [ "$other" != "$h" ] && [ -e "$KEYS/$other" ]; then
    say "  $h: its kit already holds the key of $other (the same home, under two names?); not touching it. Use one name for both."
    return 1
  fi
  p="$(port_of "$h")" || { say "  $h: no free port left for it (the listener has $(echo $TUNNEL_PORTS | wc -w | tr -d ' '))"; return 1; }
  if [ "$2" = 1 ] || [ ! -s "$k" ]; then
    new_key | put "$k.new" || { say "  $h: could not write its new key here; nothing changed for $h"; return 1; }
    src="$k.new"
  else src="$k"; fi
  if ! ssh "$h" "sh -c '$KIT; umask 077; mkdir -p \"\$d\" && cat > \"\$d/token.new\" && test -s \"\$d/token.new\" && echo $h > \"\$d/key-name.new\"'" < "$src"; then
    remote "$h" "$REMOTE_UNSTAGE" >/dev/null 2>&1; rm -f "$k.new"
    say "  $h: could not send it the key; nothing changed for $h"; return 1
  fi
  [ "$src" = "$k.new" ] && mv -f "$k.new" "$k"               # from here the listener expects the new key from $h
  if ! remote "$h" "$REMOTE_SWITCH"; then
    say "  $h: the key was sent but $h did not switch to it, so $h cannot send now: run $0 push $h again"; return 1
  fi
  if retarget "$h" "$p"; then moved="its tunnel now ends at port $p"
  else moved="no ssh master for $h right now: its tunnel moves to port $p when you reconnect"; fi
  say "  $h: has its own key; $moved. Keep this under 'Host $h' in ~/.ssh/config (in place of any other RemoteForward $RPORT):"
  say "        RemoteForward $RPORT localhost:$p"
  r="$(remote "$h" "$REMOTE_PING" 2>/dev/null)"
  case "$r" in
    proto=*\ verified=yes\ as="$h"\ *) say "  $h: the listener proves itself to it";;
    *) say "  $h: could not check the listener from there yet (${r:-no answer}): is its tunnel up, and does it end at port $p?";;
  esac
  return 0
}

case "${1:-show}" in
  push|rotate)
    need_mac; what="$1"; shift; [ $# -ge 1 ] || usage
    for h in "$@"; do name_ok "$h" || { say "not a usable name: '$h' (a lowercase ssh alias: letters, digits, . _ -)"; exit 2; }; done
    mkdir -p "$KEYS" "$PORTS" && chmod 700 "$KEYS" "$PORTS"
    local_ok || { say "refusing: the listener here does not take keys of their own yet (protocol 7), or this Mac's own key is broken. Re-run install.sh on this Mac first."; exit 1; }
    for h in "$@"; do
      remote_ready "$h" || { say "refusing: $h has no sender that can use a key of its own (protocol 7), or ssh to it failed. Update cc-notifier there first."; exit 1; }
    done
    failed=0
    for h in "$@"; do give "$h" "$([ "$what" = rotate ] && echo 1 || echo 0)" || failed=1; done
    if [ -e "$KEYS/shared" ]; then
      say "The shared key is still taken on port $PORT, for machines without a key of their own."
      say "Once every remote has its own: $0 revoke shared"
    fi
    [ "$failed" = 0 ] || exit 1 ;;
  revoke)
    need_mac; shift; [ $# -ge 1 ] || usage
    for h in "$@"; do
      case "$h" in
        local) say "not revoking this Mac's own key (the stop hotkey uses it); to replace it: $0 new";;
        shared) if [ -e "$KEYS/shared" ]; then rm -f "$KEYS/shared" && say "retired the shared key: a machine without a key of its own can no longer send"
                else say "the shared key is already retired"; fi;;
        *) if name_ok "$h" && [ -e "$KEYS/$h" ]; then
             rm -f "$KEYS/$h" "$PORTS/$h" && say "revoked $h: its key is no longer taken"
             [ -e "$KEYS/shared" ] && say "  (the shared key is still taken: if $h still has it, it can send with it until: $0 revoke shared)"
           else say "no key for '$h'"; fi;;
      esac
    done ;;
  keys)
    need_mac
    for k in "$KEYS"/*; do
      [ -f "$k" ] || continue
      case "$k" in *.new|*.tmp.*) continue;; esac
      n="${k##*/}"
      case "$n" in
        shared) echo "shared   port $PORT (the key all machines shared before protocol 7: $0 revoke shared retires it)";;
        local)  echo "local    port $PORT (this Mac's own senders)";;
        *)      echo "$n   port $(cat "$PORTS/$n" 2>/dev/null || echo '?')";;
      esac
    done ;;
  new)
    need_mac; mkdir -p "$KEYS" && chmod 700 "$KEYS"
    new_key | put "$KEYS/local.new" || { say "could not write a new key; nothing changed"; exit 1; }
    mv -f "$KEYS/local.new" "$KEYS/local" || { rm -f "$KEYS/local.new"; say "could not write a new key; nothing changed"; exit 1; }
    if cp "$KEYS/local" "$F.tmp.$$" && chmod 600 "$F.tmp.$$" && mv -f "$F.tmp.$$" "$F" && echo local | put "$N"; then
      say "new key for this Mac's own senders ($KEYS/local)"
    else
      rm -f "$F.tmp.$$"; say "the listener has the new key, but this Mac's senders could not get it: run $0 new again"; exit 1
    fi ;;
  set)
    if [ $# -gt 2 ]; then
      say "refusing: a key given on the command line can be read by other users of this host, and stays in your shell history."
      say "Pipe it in instead ($0 set <name> < file), or run '$0 set <name>' and paste it. Better: on the Mac, $0 push <this host>."
      exit 2
    fi
    name="${2:-}"
    if ! name_ok "$name"; then
      case "$name" in *[!0123456789abcdef]*|"") ;; *) [ ${#name} -ge 24 ] && say "refusing: '$0 set' takes this machine's NAME; that looks like a key (and it is now in your shell history: on the Mac, $0 rotate <this host>)"; exit 2;; esac
      say "usage: $0 set <name> (the lowercase name the Mac knows this machine by), the key on standard input"; exit 2
    fi
    if [ -t 0 ]; then printf 'key (not shown): ' >&2; IFS= read -rs t; echo >&2; else IFS= read -r t; fi
    case "$t" in
      ""|*[!A-Za-z0-9._~+/=-]*) say "that does not look like a key (letters, digits and ._~+/=- only); nothing changed"; exit 1;;
    esac
    [ ${#t} -ge 16 ] || { say "too short for a key; nothing changed"; exit 1; }
    [ "$t" != "$name" ] || { say "the name and the key are the same; nothing changed"; exit 1; }
    printf '%s' "$t" | put "$F" && echo "$name" | put "$N" && say "key set for $name ($F)" ;;
  show)
    [ -s "$F" ] || { say "(no key: this machine sends nothing)"; exit 1; }
    echo "name: $(cat "$N" 2>/dev/null || echo 'shared (protocol 6)')"
    echo "key:  $(cat "$F")" ;;
  off)
    if is_mac; then say "not on the Mac: its senders and the stop hotkey need this key (to replace it: $0 new)"; exit 2; fi
    rm -f "$F" "$N"; say "key removed: this machine sends nothing" ;;
  *) usage ;;
esac
CCN_EOF_cc_token_sh
  cat > "$DIR/cc_tunnel_test.sh" <<'CCN_EOF_cc_tunnel_test_sh'
#!/bin/bash
# Self-test the notifier path. Usage: cc_tunnel_test.sh [ping|beep|alarm|ask|stop]
# ping only asks the listener to prove it holds this machine's token (nothing
# rings). alarm/ask carry a sample session, title and summary, so the banner and
# the phone push show the full layout a real round would; stop (no session)
# silences every alarm. Every request is signed (cc_client.py): the token never
# travels and never appears on a command line.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ACT="${1:-ping}"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
export CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR"
case "$ACT" in
  ping)
    out="$("$PYBIN" "$HERE/cc_client.py" ping 2>&1)"; ec=$?;;
  alarm|done|ask)
    out="$(CC_F_LABEL="$(hostname -s 2>/dev/null || echo host)/test" CC_F_SESSION="cc-tunnel-test" \
      CC_F_TITLE="cc-notifier test" CC_F_BRIEF="This is where the one-sentence summary of the round shows." \
      CC_F_BODY="This is where the one-sentence summary of the round shows.

The phone push goes on with the rest of the final message:
• lists stay lists
• tables become lines

and nothing is cut: a long message continues in further Telegram messages." \
      "$PYBIN" "$HERE/cc_client.py" send "$ACT" 2>&1)"; ec=$?;;
  beep|stop)
    out="$("$PYBIN" "$HERE/cc_client.py" send "$ACT" 2>&1)"; ec=$?;;
  *) echo "usage: $0 [ping|beep|alarm|ask|stop]" >&2; exit 2;;
esac
if [ "$ec" = 0 ]; then echo "OK   /${ACT} -> ${out}"; case "$out" in *as=shared*|*auth=shared*) ;; *) exit 0;; esac; else echo "FAIL /${ACT} -> ${out}"; fi
if [ -f "$DIR/cc_alarm_listener.py" ]; then FIX="on this Mac: ~/.cc-notifier/cc_token.sh new"
else FIX="on your Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>"; fi
OR="(or someone else holds port ${PORT} here, posing as the listener)"
if [ "$ec" = 0 ]; then
  echo "  (the listener proves itself, but this machine still uses the key all machines share: $FIX)"; exit 0
fi
case "$out" in
  unreachable*|*err=unreachable*|*err=timeout*)
    echo "  nothing answers on localhost:${PORT}. If this is a REMOTE machine, from your Mac: ssh -O cancel -R ${PORT}:localhost:${PORT} <host>; ssh -O forward -R ${PORT}:localhost:${PORT} <host>";;
  *no_token*|*bad_key_name*)
    echo "  no usable key on this machine ($DIR/token, $DIR/key-name). Fix, $FIX";;
  *key_unknown_at_listener*)
    echo "  the listener says it has no key under this machine's name on this machine's port (never issued, revoked, or the tunnel ends at the wrong port) $OR. Fix, $FIX";;
  *no_key_for_this_machine*)
    echo "  this machine has no key of its own, and the listener says it no longer takes the shared one $OR. Fix, $FIX";;
  *listener_has_no_token*)
    echo "  the listener says it has no token $OR: re-run install.sh on the Mac.";;
  *legacy=yes*)
    echo "  the Mac listener is protocol 5: notifications still work, with the old token in a header. Update the Mac (re-run install.sh there), then on the Mac: ~/.cc-notifier/cc_token.sh rotate <this machine>";;
  *old_listener*)
    echo "  the listener is older than these hooks: re-run install.sh on the Mac.";;
  *http=429*)
    echo "  the listener took the request but this machine has sent too many in a short time (a burst of 20, then one every 3 s)";;
  *unverified*|*http=401*|*http=403*)
    echo "  something answers on localhost:${PORT} but cannot prove it holds this machine's key: the two ends have different keys ($FIX), or someone else holds the port on this host. Nothing is sent to it.";;
esac
exit "$ec"
CCN_EOF_cc_tunnel_test_sh
  cat > "$DIR/notify_ask.sh" <<'CCN_EOF_notify_ask_sh'
#!/bin/bash
# PreToolUse(AskUserQuestion) hook: the agent is asking you a question and is
# BLOCKED waiting. Always notify (no time guard, independent of arm state). The
# request names the session and carries the agent, its title, the question, and
# for the phone push the questions with their choices.
# Usage (as a hook command): notify_ask.sh [agent]     (see notify_done.sh)
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"
log(){ ( umask 077; printf '%s ask %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" ) 2>/dev/null; }

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
AGENT="${1:-${CC_NOTIFY_AGENT:-}}"
verdict=""; sid=""; title=""; brief=""; info=""; agent=""; label=""; body=""; short=""
PAYLOAD="$(cat 2>/dev/null)"
if [ -n "$PAYLOAD" ]; then
  { IFS= read -r verdict; IFS= read -r sid; IFS= read -r title; IFS= read -r brief; IFS= read -r info
    IFS= read -r agent; IFS= read -r label; IFS= read -r body; IFS= read -r short; } \
    < <(printf '%s' "$PAYLOAD" | "$PYBIN" "$HERE/cc_hook.py" ask "$AGENT" 2>/dev/null)
fi
[ "$verdict" = "notify" ] || { sid=""; title=""; brief=""; agent="$AGENT"; label=""; body=""; short=""; info="helper-unavailable"; }

[ -n "$label" ] || label="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD" 2>/dev/null)"
# The request goes out through cc_client.py: signed with the token, which never
# travels, and only to a listener that proves it holds the token. The fields go in
# the environment, never on a command line (other users of the host can read those).
( res="$(CC_F_LABEL="$label" CC_F_AGENT="$agent" CC_F_SESSION="$sid" CC_F_TITLE="$title" CC_F_BRIEF="$brief" \
      CC_F_BODY_FILE="$body" CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" send ask 2>/dev/null)"
  log "sent ${res:-http=000 err=client_failed auth=-} $info" ) >/dev/null 2>&1 &
exit 0
CCN_EOF_notify_ask_sh
  cat > "$DIR/notify_done.sh" <<'CCN_EOF_notify_done_sh'
#!/bin/bash
# Stop hook: notify the Mac when a round finishes. Fire-and-forget.
# Usage (as a hook command): notify_done.sh [agent]
# Any agent whose Stop hook hands over a Claude Code style payload can use it;
# `agent` names the caller for the alert (e.g. `codex`; default: read off the payload).
#
# The decision uses only THIS session's payload and state (cc_hook.py):
#   - silent while the session is merely PAUSED on its own background work (the
#     Stop payload's `background_tasks`, CC >= 2.1.145) or in a forced
#     continuation (`stop_hook_active`). Open-ended watches (task type `monitor`,
#     e.g. "live updates for artifact ...") never finish, so they do not count;
#     change the list with CC_NOTIFY_STANDBY_IGNORE.
#   - that hold has limits, so a session is never silent for hours: a pause that
#     outlasts CC_NOTIFY_PAUSE_SECONDS (300) is reported once ("still waiting on
#     ..."), and a task in flight for CC_NOTIFY_LONG_TASK_SECONDS (1800) - a
#     standing watcher, a wait for a queued job - no longer holds anything.
#   - silent for quick turns (< CC_NOTIFY_MIN_SECONDS), timed from this session's
#     own turn start. A stop that completes work an earlier stop left paused is
#     timed from the last prompt a person typed, so the short wrap-up after a
#     long background task still notifies.
# The request names the session (the listener keeps one alarm per session) and
# carries the agent, the session title, a one-sentence summary (the sentence the
# final message opens with) for the alert, and the message itself as plain text,
# whole, for the phone push. It is signed (cc_client.py); the token never travels.
# Falls back to notifying if the payload/helper is unavailable (never over-suppresses).
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ARM_FLAG="${CC_NOTIFY_ARM_FLAG:-$DIR/armed}"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"
log(){ ( umask 077; printf '%s done %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" ) 2>/dev/null; }

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
verdict=""; sid=""; title=""; brief=""; info=""; agent=""; label=""; body=""; short=""
if [ "${1:-}" = "--late" ]; then
  # notify_done.sh --late <seconds> <session_id> <seq>: started by cc_hook.py after a
  # stop that background work held back. If the session is still paused when the
  # time is up, say so; if it woke up meanwhile, its own stop decides.
  sleep "$2"
  if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi
  { IFS= read -r verdict; IFS= read -r sid; IFS= read -r title; IFS= read -r brief; IFS= read -r info
    IFS= read -r agent; IFS= read -r label; IFS= read -r body; IFS= read -r short; } \
    < <("$PYBIN" "$HERE/cc_hook.py" late "$act" "$3" "$4" 2>/dev/null)
  [ "$verdict" = "notify" ] || exit 0
else
  if [ -f "$ARM_FLAG" ]; then act="alarm"; else act="beep"; fi
  AGENT="${1:-${CC_NOTIFY_AGENT:-}}"
  PAYLOAD="$(cat 2>/dev/null)"
  if [ -n "$PAYLOAD" ]; then
    { IFS= read -r verdict; IFS= read -r sid; IFS= read -r title; IFS= read -r brief; IFS= read -r info
      IFS= read -r agent; IFS= read -r label; IFS= read -r body; IFS= read -r short; } \
      < <(printf '%s' "$PAYLOAD" | "$PYBIN" "$HERE/cc_hook.py" done "$act" "$AGENT" 2>/dev/null)
  fi
  case "$verdict" in
    silent) log "silent $info"; exit 0;;
    notify) ;;
    *) sid=""; title=""; brief=""; agent="$AGENT"; label=""; body=""; short=""; info="helper-unavailable";;
  esac
fi

[ -n "$label" ] || label="$(hostname -s 2>/dev/null || echo host)/$(basename "$PWD" 2>/dev/null)"
# The request goes out through cc_client.py: signed with the token, which never
# travels, and only to a listener that proves it holds the token. The fields go in
# the environment, never on a command line (other users of the host can read those).
( res="$(CC_F_LABEL="$label" CC_F_AGENT="$agent" CC_F_SESSION="$sid" CC_F_TITLE="$title" CC_F_BRIEF="$brief" \
      CC_F_BODY_FILE="$body" CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" send "$act" 2>/dev/null)"
  log "sent act=${act} ${res:-http=000 err=client_failed auth=-} $info" ) >/dev/null 2>&1 &
exit 0
CCN_EOF_notify_done_sh
  cat > "$DIR/notify_healthcheck.sh" <<'CCN_EOF_notify_healthcheck_sh'
#!/bin/bash
# SessionStart hook: warn (into the agent's context) only if something is wrong —
# the notifier is unreachable, the listener cannot prove it holds this machine's
# token (cc_client.py ping), the Mac-side listener is older than these hooks, or
# the hook helper cannot run. Also tidies the per-session state and the hook log.
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
res="$(CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" "$PYBIN" "$HERE/cc_client.py" ping 2>/dev/null)"
if [ -f "$DIR/cc_alarm_listener.py" ]; then FIX="this Mac: ~/.cc-notifier/cc_token.sh new"     # the Mac's own senders
else FIX="the Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>"; fi
OR="(or someone else holds port ${PORT} on this host, posing as the listener)"
me="${res##*as=}"; me="${me%% *}"
case "$res" in
  proto=[0-6]\ verified=yes\ as=shared*)
    pv="${res%% *}"
    echo "NOTE: the cc-notifier listener on the Mac is protocol ${pv#proto=}; it works, but every machine still shares one key. Re-run the cc-notifier install.sh on the Mac, then give this machine a key of its own: on the Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>.";;
  proto=*\ verified=yes\ as=shared*)
    echo "NOTE: this machine still uses the cc-notifier key all machines share; it works, but give it a key of its own: on the Mac: ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>.";;
  proto=*\ verified=yes*) ;;
  ""|unreachable*)
    echo "NOTE: CC round-end notifier is unreachable (nothing answers on localhost:${PORT}). If this is a REMOTE machine, restore the tunnel from your Mac: ssh -O cancel -R ${PORT}:localhost:<its port> <host> 2>/dev/null; ssh -O forward -R ${PORT}:localhost:<its port> <host> (cc_token.sh keys on the Mac lists the ports). Verify: $DIR/cc_tunnel_test.sh";;
  *why=no_token*)
    echo "NOTE: cc-notifier has no key on this machine ($DIR/token), so it sends nothing. Fix, on $FIX.";;
  *why=bad_key_name*)
    echo "NOTE: cc-notifier cannot use $DIR/key-name (missing, malformed, or it looks like a key), so it sends nothing. Fix, on $FIX.";;
  *legacy=yes*)
    echo "NOTE: the cc-notifier listener on the Mac is protocol 5. Notifications still work, but this machine sends it the token itself (in a header) until the Mac is updated: re-run the cc-notifier install.sh on the Mac, then on the Mac: ~/.cc-notifier/cc_token.sh rotate <ssh alias of this machine>.";;
  *why=key_unknown_at_listener*)
    echo "NOTE: the cc-notifier listener says it has no key named ${me} on this machine's port (never issued, revoked, or the tunnel ends at the wrong port) $OR, so nothing is sent. Fix, on $FIX.";;
  *why=no_key_for_this_machine*)
    echo "NOTE: this machine has no cc-notifier key of its own, and the listener says it no longer takes the shared one $OR, so nothing is sent. Fix, on $FIX.";;
  *why=listener_has_no_token*)
    echo "NOTE: the cc-notifier listener says it has no token $OR, so nothing is sent. Re-run the cc-notifier install.sh on the Mac.";;
  *why=old_listener*)
    echo "NOTE: the cc-notifier listener on the Mac is older than the hooks on this machine (${res%% *}) $OR, so nothing is sent to it. Fix: re-run the cc-notifier install.sh on the Mac.";;
  *)
    echo "NOTE: something answers on localhost:${PORT} but cannot prove it holds this machine's cc-notifier key, so nothing is sent to it. Either the two ends have different keys (fix, on $FIX) or someone else holds that port on this host (then restore the tunnel from the Mac). Check: $DIR/cc_tunnel_test.sh";;
esac

if [ "$("$PYBIN" "$HERE/cc_hook.py" check 2>/dev/null)" != "ok" ]; then
  echo "NOTE: cc-notifier's hook helper cannot run ($PYBIN $HERE/cc_hook.py). Round-end notifications fall back to always notifying, with no brief and no per-session cancel."
fi

# Housekeeping: forget sessions idle for two weeks; keep the hook log bounded.
find "$DIR/sessions" -type f -mtime +14 -delete 2>/dev/null
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null | tr -d " ")" -gt 1048576 ] 2>/dev/null; then
  ( umask 077; tail -c 524288 "$LOG" | sed 1d > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG" ) 2>/dev/null
fi
exit 0
CCN_EOF_notify_healthcheck_sh
  cat > "$DIR/notify_stop.sh" <<'CCN_EOF_notify_stop_sh'
#!/bin/bash
# UserPromptSubmit hook: start THIS session's turn clock and, when a person typed
# the prompt, cancel the alarm this session raised. Other sessions are untouched.
# Usage (as a hook command): notify_stop.sh [agent]     (see notify_done.sh)
#
# Agents also fire this hook for their own messages (a subagent's turn; in Claude
# Code a finished background task, a hand-back, a scheduled wake-up). Those never
# cancel an alarm and never restart the clock of a turn that is already running
# (cc_hook.py).
PORT="${CC_NOTIFY_PORT:-28765}"
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CC_NOTIFY_LOG:-$DIR/hook.log}"
log(){ ( umask 077; printf '%s prompt %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" ) 2>/dev/null; }

PYBIN="$(command -v python3 || echo /usr/bin/python3)"
verdict=""; sid=""; info=""
PAYLOAD="$(cat 2>/dev/null)"
if [ -n "$PAYLOAD" ]; then
  { IFS= read -r verdict; IFS= read -r sid; IFS= read -r info; } \
    < <(printf '%s' "$PAYLOAD" | "$PYBIN" "$HERE/cc_hook.py" prompt "${1:-${CC_NOTIFY_AGENT:-}}" 2>/dev/null)
fi
case "$verdict" in
  cancel)
    # Signed, like every request (cc_client.py); the session id goes in the environment.
    ( res="$(CC_F_SESSION="$sid" CC_NOTIFY_TIMEOUT=2 CC_NOTIFY_PORT="$PORT" CC_NOTIFIER_DIR="$DIR" \
          "$PYBIN" "$HERE/cc_client.py" send stop 2>/dev/null)"
      log "cancel ${res:-http=000 err=client_failed auth=-} $info" ) >/dev/null 2>&1 &
    ;;
  keep) log "keep $info";;
  # No session to act for: leave every alarm alone rather than cancel someone else's.
  *)    log "keep helper-unavailable";;
esac
exit 0
CCN_EOF_notify_stop_sh
  chmod +x "$DIR"/*.sh "$DIR"/*.py 2>/dev/null || true
}
write_receiver(){
  mkdir -p "$DIR"
  cat > "$DIR/_attention.sh" <<'CCN_EOF__attention_sh'
#!/bin/bash
# Shared engine for the long attention alarms (cc_alarm.sh / cc_ask.sh).
# Caller sources this AFTER setting: SOUND, REPEATS, INTERVAL, TITLE, MSG,
# BUTTON, TIMEOUT. Plays SOUND, REPEATS times, INTERVAL apart, with a persistent
# alert (one button); any click (or /stop) silences it.
#
# The sender says what this is about (through the listener):
#   CC_AGENT  who is notifying (Claude Code, Codex, ...) -> TITLE, set by the caller
#   CC_LABEL  host/project             -> appended to the status line
#   CC_KEY    the machine whose key signed the request (set by the listener, not
#             the sender) -> leads the status line unless it is this Mac's own
#   CC_TITLE  session title            -> the alert's subtitle
#   CC_BRIEF  one-sentence summary of the round, or the question asked -> leads the body
#   CC_BODY_FILE  file with the final message as plain text (line breaks, any length)
#             -> the phone push only; the alert has no room for it
#
# The SOUND is gated by the active macOS Focus (cc_focus.sh): muted in
# Sleep / Do-Not-Disturb, played otherwise. The banner is gated independently by
# the per-app Focus allow-list. CC_SOUND_VIA_ALERTER=1 routes the sound through
# the notification instead of the afplay loop (Apple gates it for free; no loop).
# Optional Telegram push if CC_TELEGRAM_TOKEN + CC_TELEGRAM_CHAT_ID set: the session
# title, then the whole message (cc_telegram.py: as many Telegram messages as it
# takes, the long part folded) or, without one, the summary, then the status line.
# CC_TELEGRAM_BRIEF=0 sends the status line only.
find_bin(){ for p in "$@"; do [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done; return 1; }

# Which machine (verified by its key) and session/host finished (?label=... is the sender's word).
case "${CC_KEY:-local}" in
  local) [ -n "${CC_LABEL:-}" ] && MSG="$MSG — $CC_LABEL";;
  *)     MSG="$MSG — ${CC_KEY}${CC_LABEL:+: $CC_LABEL}";;
esac

# --- optional phone push (relayed from THIS Mac; senders like Aurora may block Telegram) ---
if [ -n "${CC_TELEGRAM_TOKEN:-}" ] && [ -n "${CC_TELEGRAM_CHAT_ID:-}" ]; then
  STATUS="${TITLE}: ${MSG}"
  PUSH="$STATUS"
  # Lead with what a phone preview should show: which session, and what happened.
  # That is text from the session; CC_TELEGRAM_BRIEF=0 keeps it on this Mac.
  if [ "${CC_TELEGRAM_BRIEF:-1}" != 0 ]; then
    LEAD="${CC_TITLE:-}"
    [ -n "${CC_BRIEF:-}" ] && LEAD="${LEAD:+$LEAD: }${CC_BRIEF}"
    [ -n "$LEAD" ] && PUSH="${LEAD}
${STATUS}"
  fi
  # The bot token is part of the URL, so curl reads it on stdin, never from its
  # command line (any local user can list those); the text goes in a private file.
  _push(){
    case "$CC_TELEGRAM_TOKEN$CC_TELEGRAM_CHAT_ID" in *[!A-Za-z0-9:@_-]*) return 1;; esac
    _f="$(mktemp "${TMPDIR:-/tmp}/ccpush.XXXXXX")" || return 1
    printf '%s' "$1" > "$_f"
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text@%s"\n' \
        "$CC_TELEGRAM_TOKEN" "$CC_TELEGRAM_CHAT_ID" "$_f" | curl -s --max-time 8 -o /dev/null -w '%{http_code}' --config - 2>/dev/null
    rm -f "$_f"; }
  _PY="$(command -v python3 || echo /usr/bin/python3)"
  # The whole message when there is one; if that does not go out, the short form does.
  ( if [ "${CC_TELEGRAM_BRIEF:-1}" = 0 ] || [ ! -s "${CC_BODY_FILE:-}" ] || \
       ! CC_TELEGRAM_TOKEN="$CC_TELEGRAM_TOKEN" CC_TELEGRAM_CHAT_ID="$CC_TELEGRAM_CHAT_ID" CC_TG_STATUS="$STATUS" \
         CC_TELEGRAM_FOLD_CHARS="${CC_TELEGRAM_FOLD_CHARS:-}" "$_PY" "$HERE/cc_telegram.py"; then
      _push "$PUSH"
    fi ) >/dev/null 2>&1 &
fi

# --- beeps: afplay loop, gated by the active Focus (loop preserved) ---
[ -f "$HERE/cc_focus.sh" ] && . "$HERE/cc_focus.sh"
_BEEP=""
if [ "${CC_SOUND_VIA_ALERTER:-0}" != 1 ]; then
  ( if ! command -v cc_should_play >/dev/null 2>&1 || cc_should_play; then
      for ((i = 1; i <= REPEATS; i++)); do
        afplay "$SOUND"
        [ "$i" -lt "$REPEATS" ] && sleep "$INTERVAL"
      done
    fi ) &
  _BEEP=$!
fi
_stop(){ [ -n "$_BEEP" ] && { kill "$_BEEP" 2>/dev/null; pkill -P "$_BEEP" afplay 2>/dev/null; }; }
_wait(){ [ -n "$_BEEP" ] && wait "$_BEEP" 2>/dev/null; }

# Static hint: the stop hotkey (read from Karabiner) + how it's configured to play.
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
HOTKEY="$("$PYBIN" "$HERE/cc_hotkey.py" 2>/dev/null)"
INFO="auto-off ${TIMEOUT:-60}s · ${REPEATS}x$(basename "${SOUND%.*}")"
[ -n "$HOTKEY" ] && INFO="${HOTKEY} to stop · ${INFO}"
BANNER="$MSG  (${INFO})"
# The brief leads the body; the status line and the hint follow on the next line.
[ -n "${CC_BRIEF:-}" ] && BANNER="${CC_BRIEF}
${BANNER}"

# When routing sound through the notification (escape hatch), attach it.
SND=(); [ "${CC_SOUND_VIA_ALERTER:-0}" = 1 ] && SND=(--sound "$(basename "${SOUND%.*}")")

ALERTER="$(find_bin "$(command -v alerter 2>/dev/null)" /opt/homebrew/bin/alerter /usr/local/bin/alerter)"
TN="$(find_bin "$(command -v terminal-notifier 2>/dev/null)" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier)"
if [ -n "$ALERTER" ]; then
  SUB=(); [ -n "${CC_TITLE:-}" ] && SUB=(--subtitle "$CC_TITLE")
  _t0=$SECONDS
  "$ALERTER" --title "$TITLE" "${SUB[@]}" --message "$BANNER" --actions "${BUTTON:-Stop}" --timeout "${TIMEOUT:-60}" "${SND[@]}" >/dev/null 2>&1
  # An alerter build that rejects --subtitle exits at once with an error: show
  # the alert without it rather than lose the banner and cut the sound.
  if [ $? -ne 0 ] && [ ${#SUB[@]} -gt 0 ] && [ $((SECONDS - _t0)) -lt 2 ]; then
    "$ALERTER" --title "$TITLE" --message "$CC_TITLE — $BANNER" --actions "${BUTTON:-Stop}" --timeout "${TIMEOUT:-60}" "${SND[@]}" >/dev/null 2>&1
  fi
  _stop
elif [ -n "$TN" ]; then
  # terminal-notifier misreads a value that starts with a bracket, quote or dash
  # unless that first character is escaped. One group per session, so alerts from
  # different sessions do not replace each other.
  _tn(){ case "$1" in [\[\(\{\<\"\'-]*) printf '\\%s' "$1";; *) printf '%s' "$1";; esac; }
  SUB=(); [ -n "${CC_TITLE:-}" ] && SUB=(-subtitle "$(_tn "$CC_TITLE")")
  "$TN" -title "$TITLE" "${SUB[@]}" -message "$(_tn "$BANNER")" -group "cc-notifier${CC_SESSION:+-$CC_SESSION}" >/dev/null 2>&1; _wait
else
  osascript -e 'on run a' -e 'display notification (item 1 of a) with title (item 2 of a) subtitle (item 3 of a)' \
    -e 'end run' "$BANNER" "$TITLE" "${CC_TITLE:-}" >/dev/null 2>&1; _wait
fi
CCN_EOF__attention_sh
  cat > "$DIR/cc_alarm_listener.py" <<'CCN_EOF_cc_alarm_listener_py'
#!/usr/bin/env python3
"""Local alarm listener. Binds loopback on BOTH 127.0.0.1 and ::1 (ssh forwards
`localhost` may hit ::1 first). Endpoints: /beep /alarm /done /ask /stop /ping.

Ports. PORT (28765) is this Mac's own: its local senders (the stop hotkey, local
sessions) and, while machines move to keys of their own, the key they all shared.
Each remote machine has a port of its own, from PORT+1 on (its tunnel ends there:
`RemoteForward 28765 localhost:<its port>`; cc_token.sh push assigns it, in
<dir>/ports/<name>). A machine's key is taken, and proven, only on its own port, so
a connection relayed through another machine's tunnel gets nothing, and each port
has its own connection limit, so a flood on one tunnel does not silence the others.

Keys (protocol 7). One key per machine in <dir>/keys/<name>. A key is never sent
anywhere. An action is carried out only when the request names a key that may be
used on this port (X-CC-Key), is signed with it over the name and the request
(X-CC-Time, X-CC-Nonce, X-CC-Sig: see cc_client.py), is within WINDOW seconds of its
time, its nonce has not been seen before, and the key is within its rate limit.
/ping?c=<challenge>&k=<name> answers with a proof that this listener holds that
key, so a sender can tell it from anyone else who might listen at its end of the
tunnel. A request that names no key is the form of protocol 6, checked against
keys/shared on PORT only, and only while that file exists (`cc_token.sh revoke
shared` retires it). Keys are read per request: issuing or revoking one needs no
restart. Each request carried out or refused is one line in the log, with the
key's name (refused ones at most one a second).

Alarms are kept per machine and session: ?session=<id> on /alarm or /ask replaces
only that machine's alarm for that session, and /stop?session=<id> silences only
that one. /stop without a session silences all of the sender's alarms; from this
Mac's own key (the stop hotkey) it silences every alarm. The alarm gets the
verified machine name as $CC_KEY, so the banner shows who really sent it.

Guards against web pages: a request whose Origin, or whose Host, is not local is
refused (browser CSRF / DNS rebinding).
The ?agent=, ?label=, ?title= and ?brief= queries are sanitized and passed to the
alarm as $CC_AGENT (who is notifying: Claude Code, Codex, ...), $CC_LABEL,
$CC_TITLE and $CC_BRIEF ($CC_SESSION carries the session id). The message itself,
for the phone push, has line breaks and no length limit to speak of: it is the
body of a POST (text/plain), or ?body= from senders that cannot post, and
reaches the alarm in a file, $CC_BODY_FILE (too long for the environment).
Any sender can use these; none is required.
"""
import hashlib, hmac, http.server, os, re, signal, socket, socketserver, subprocess, sys, threading, time
from urllib.parse import urlsplit, parse_qs

PORT = int(os.environ.get("CC_NOTIFY_PORT", "28765"))
TUNNEL_PORTS = range(PORT + 1, PORT + 17)  # one per remote machine (cc_token.sh push assigns them)
HERE = os.path.dirname(os.path.abspath(__file__))
ALARM = os.path.join(HERE, "cc_alarm.sh")
BEEP = os.path.join(HERE, "cc_beep.sh")
ASK = os.path.join(HERE, "cc_ask.sh")
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")
BODIES = os.path.join(HERE, "tmp")      # message bodies on their way to the phone push
PROTO = 7            # 2: per-session alarms, title + brief; 3: agent name, summary in the phone push; 4: message body in the phone push; 5: the whole message, posted; 6: signed requests, the token never travels; 7: one key per machine. Reported by /ping.
MAX_POST = 1 << 20   # bytes of posted text read from one request
MAX_BODY = 60000     # characters of it passed on (about fifteen Telegram messages)
MAX_ALARMS = 16      # alarms alive at once; the oldest gives way beyond this
WINDOW = 300         # seconds a signed request stays good (the two clocks may differ by this much)
DEADLINE = 5         # seconds a connection has for its whole request; a slow one is cut off
MAX_CONNECTIONS = 32 # connections handled at once on each port; more are closed at once
RATE = (20, 3.0)     # per key: a burst of 20 requests, then one every 3 seconds
HEX32 = re.compile(r"[0-9a-f]{32}\Z"); HEX64 = re.compile(r"[0-9a-f]{64}\Z"); TIME = re.compile(r"[0-9]{1,12}\Z")
NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}\Z"); KEYLIKE = re.compile(r"[0-9a-f]{24,}\Z")

_lock = threading.Lock()
_alarms = {}     # (machine, session id) -> alarm process
_seen = {}       # nonce -> when it was used; a nonce is good once
_buckets = {}    # machine -> (requests left, when counted)


def valid_name(name):
    """A machine's key name: lowercase (macOS file names ignore case), not one the
    kit uses for its own files, not the shared key's."""
    return bool(NAME.match(name)) and name != "shared" and ".." not in name and not KEYLIKE.match(name) \
        and not re.search(r"\.(new|tmp|bak|port)\Z|\.tmp\.", name)


def allowed(name, port):
    """May the key `name` ("" = the shared key) be used on this port? This Mac's own
    key and the shared key only on PORT; a remote machine's only on its own port."""
    if port == PORT:
        return name in ("", "local")
    if not name or name == "local" or not valid_name(name):
        return False
    # The port must be this machine's, and no other machine's: two names on one
    # port would let either one's connections be relayed for the other.
    try:
        holders = []
        for other in os.listdir(os.path.join(HERE, "ports")):
            if valid_name(other):
                try:
                    with open(os.path.join(HERE, "ports", other)) as f:
                        if int(f.read().strip()) == port: holders.append(other)
                except (OSError, ValueError):
                    pass
        return holders == [name]
    except OSError:
        return False


def _key(name):
    """The key of the machine called `name` ("" = the shared key); b"" when there is none."""
    if name and not valid_name(name):
        return b""
    try:
        with open(os.path.join(HERE, "keys", name or "shared"), "rb") as f:
            return f.read().strip()
    except Exception:
        return b""


# The protocol; cc_client.py holds the same functions (tests/test_security.py checks they agree).
def request_sig(key, method, path, query, body, t, nonce, name=""):
    """Protocol 7 when the request names its key, protocol 6 (the shared key) when not."""
    digest = hashlib.sha256(body).hexdigest()
    if name:
        msg = "cc-notifier/7 req\n%s\n%s\n%s\n%s\n%s\n%d\n%s" % (name, method, path, query, digest, t, nonce)
    else:
        msg = "cc-notifier/6 req\n%s\n%s\n%s\n%s\n%d\n%s" % (method, path, query, digest, t, nonce)
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).hexdigest()


def ping_proof(key, challenge, name=""):
    msg = ("cc-notifier/7 pong\n%s\n%s" % (name, challenge)) if name else ("cc-notifier/6 pong\n" + challenge)
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).hexdigest()


def check_request(headers, method, path, query, body, port, now=None):
    """-> None when the request may be carried out, else (HTTP status, reason)."""
    name = headers.get("X-CC-Key") or ""
    if name and not valid_name(name):
        return 403, "not a key name"
    if not allowed(name, port):
        return 403, ("%s may not send on this port" % name) if name else "names no key, which this port does not take"
    key = _key(name)
    if not key:
        return 403, ("no key for %s" % name) if name else "names no key, and the shared key is retired"
    t, nonce, sig = (headers.get(h) or "" for h in ("X-CC-Time", "X-CC-Nonce", "X-CC-Sig"))
    if not (TIME.match(t) and HEX32.match(nonce) and HEX64.match(sig)):
        return 401, "not signed"
    now = time.time() if now is None else now
    if abs(now - int(t)) > WINDOW:
        return 401, "too old or too new (the clocks differ by %d s?)" % (now - int(t))
    if not hmac.compare_digest(sig.encode(), request_sig(key, method, path, query, body, int(t), nonce, name).encode()):
        return 403, "bad signature"
    with _lock:
        if len(_seen) > 2048:
            for n in [n for n, when in _seen.items() if now - when > 2 * WINDOW]: del _seen[n]
        if nonce in _seen:
            return 403, "replayed"
        _seen[nonce] = now
        left, then = _buckets.get(name, (RATE[0], now))
        left = min(RATE[0], left + (now - then) / RATE[1])
        if left < 1:
            _buckets[name] = (left, now)
            return 429, "too many requests from %s" % (name or "shared")
        _buckets[name] = (left - 1, now)
    return None


_gate = {"last": 0.0, "dropped": 0}


def _note(line, limited=False):
    """One line for the log: what was done or refused, for which key; never a
    secret. Refused requests (anyone can send those) at most one a second."""
    if limited:
        with _lock:
            now = time.time()
            if now - _gate["last"] < 1.0:
                _gate["dropped"] += 1
                return
            if _gate["dropped"]:
                line += " (and %d more refused before this)" % _gate["dropped"]
            _gate["last"], _gate["dropped"] = now, 0
    try: print(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + line, file=sys.stderr, flush=True)
    except Exception: pass


def _clean(s, limit=80):
    """Untrusted text for a log line: printable ASCII only, bounded."""
    return re.sub(r"[^\x21-\x7e]", "?", s)[:limit]


def _text(s, limit):
    """Free text for the banner: one printable line, bounded, never option-like."""
    s = "".join(c if c.isprintable() else " " for c in s)
    return " ".join(s.split()).lstrip("- ")[:limit].strip()


def _body(s, limit):
    """Longer text for the phone push: printable, line breaks kept, bounded. The
    bound counts as Telegram does (a character outside the basic plane is two)."""
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    s = "".join(c if (c.isprintable() or c == "\n") else " " for c in s)
    s = re.sub(r"\n{3,}", "\n\n", re.sub(r"[ \t]+\n", "\n", s)).strip()
    out, n = [], 0
    for c in s:
        n += 2 if ord(c) > 0xFFFF else 1
        if n > limit: break
        out.append(c)
    return "".join(out)


def _body_file(session, text):
    """Keep the body for the alarm script (cc_telegram.py reads and removes it).
    Whatever an earlier alarm left behind is cleared out here. -> path or "" """
    try:
        os.makedirs(BODIES, mode=0o700, exist_ok=True)
        now = time.time()
        for name in os.listdir(BODIES):
            if now - os.path.getmtime(os.path.join(BODIES, name)) > 600: os.unlink(os.path.join(BODIES, name))
        if not text: return ""
        path = os.path.join(BODIES, "%s-%d.txt" % (session or "none", time.time() * 1000))
        with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f: f.write(text)
        return path
    except Exception:
        return ""


def _kill(p):
    if p.poll() is None:
        try: os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        except ProcessLookupError: pass


def stop_alarm(owner, session=None):
    """Silence the alarms of machine `owner` (that session's, or all of them). This
    Mac's own key ("local") reaches every machine's alarms."""
    with _lock:
        for (who, sid) in list(_alarms):
            if (owner == "local" or who == owner) and (session is None or sid == session):
                _kill(_alarms.pop((who, sid)))


def start_proc(script, owner, session="", **fields):
    env = dict(os.environ)
    env.update({k: v for k, v in fields.items() if v})
    with _lock:
        for k in [k for k, p in _alarms.items() if p.poll() is not None]: del _alarms[k]
        old = _alarms.pop((owner, session), None)
        if old: _kill(old)
        while len(_alarms) >= MAX_ALARMS: _kill(_alarms.pop(next(iter(_alarms))))
        _alarms[(owner, session)] = subprocess.Popen(["/bin/bash", script], start_new_session=True, env=env)


def play_beep():
    subprocess.Popen(["/bin/bash", BEEP], start_new_session=True)


def _local(value):
    """Is this Origin / Host value a local address?"""
    try: return urlsplit(value if "//" in value else "//" + value).hostname in LOCAL_HOSTS
    except ValueError: return False


class Handler(http.server.BaseHTTPRequestHandler):
    # Anyone on a shared login node can connect to the port at the far end of the
    # tunnel. A connection that sends its request slowly, or not at all, is cut off
    # after DEADLINE seconds in all (one request per connection: HTTP/1.0).
    timeout = DEADLINE
    def setup(self):
        super().setup()
        self._cutoff = threading.Timer(DEADLINE, self._cut); self._cutoff.daemon = True; self._cutoff.start()
    def _cut(self):
        try: self.connection.shutdown(socket.SHUT_RDWR)
        except OSError: pass
    def handle(self):
        try: super().handle()
        except OSError: pass                      # cut off, or the sender went away: nothing to answer
    def finish(self):
        self._cutoff.cancel()
        try: super().finish()
        except OSError: pass
    def _route(self):
        origin, host = self.headers.get("Origin"), self.headers.get("Host")
        if (origin and not _local(origin)) or (host is not None and not _local(host)):
            self.send_response(403); self.end_headers(); return
        port = self.server.server_address[1]
        u = urlsplit(self.path)
        path = u.path.rstrip("/")
        q = parse_qs(u.query)
        arg = lambda name: q.get(name, [""])[0]
        if path in ("/ping", ""):
            words, k = ["ok", "proto=%d" % PROTO], arg("k")
            key = _key(k) if (not k or valid_name(k)) and allowed(k, port) else b""
            if not key: words.append("key=unknown" if k else "shared=none")
            elif HEX32.match(arg("c")): words.append("proof=" + ping_proof(key, arg("c"), k))
            return self._answer(200, " ".join(words))
        raw = b""
        if self.command == "POST":
            try: size = int(self.headers.get("Content-Length") or 0)
            except ValueError: size = 0
            if size > MAX_POST: self.send_response(413); self.end_headers(); return
            if size > 0: raw = self.rfile.read(size)
        refused = check_request(self.headers, self.command, u.path, u.query, raw, port)
        owner = self.headers.get("X-CC-Key") or "shared"
        if refused:
            _note("refused %s %s from %s on port %d: %s" % (self.command, _clean(path), _clean(owner, 64), port, refused[1]),
                  limited=True)
            return self._answer(refused[0], "refused: " + refused[1])
        _note("%s %s from %s" % (self.command, _clean(path), owner))
        posted = raw.decode("utf-8", "replace")
        session = re.sub(r"[^A-Za-z0-9_-]", "", arg("session"))[:64]
        fields = dict(CC_LABEL=re.sub(r"[^\w\-./ ]", "", arg("label"))[:64], CC_SESSION=session, CC_KEY=owner,
                      CC_AGENT=_text(arg("agent"), 32), CC_TITLE=_text(arg("title"), 80),
                      CC_BRIEF=_text(arg("brief"), 400))
        if path in ("/alarm", "/done", "/ask"):
            fields["CC_BODY_FILE"] = _body_file(session, _body(posted or arg("body"), MAX_BODY))
        try:
            if path in ("/alarm", "/done"): start_proc(ALARM, owner, session, **fields); body = b"alarm\n"
            elif path == "/ask": start_proc(ASK, owner, session, **fields); body = b"ask\n"
            elif path == "/beep": play_beep(); body = b"beep\n"
            elif path == "/stop": stop_alarm(owner, session if "session" in q else None); body = b"stopped\n"
            else: self.send_response(404); self.end_headers(); return
        except OSError:                           # the alarm could not be started: say so, do not look delivered
            self.send_response(500); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def _answer(self, code, text):
        data = (text + "\n").encode("utf-8")
        self.send_response(code); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    do_GET = _route; do_POST = _route
    def log_message(self, *a): pass


_busy = {"dropped": 0, "noted": 0.0}


class Capped(socketserver.ThreadingTCPServer):
    """At most MAX_CONNECTIONS handled at once on this port (and address family)."""
    allow_reuse_address = True; daemon_threads = True
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        super().__init__(*args, **kwargs)
    def process_request(self, request, client_address):
        slots = self.slots
        if not slots.acquire(blocking=False):
            self.shutdown_request(request)
            _busy["dropped"] += 1
            if time.time() - _busy["noted"] > 60:
                _note("busy: %d connections closed unanswered (more than %d at once on port %d)"
                      % (_busy["dropped"], MAX_CONNECTIONS, self.server_address[1]))
                _busy["noted"] = time.time()
            return
        def serve():
            try: self.finish_request(request, client_address)
            except Exception: self.handle_error(request, client_address)
            finally:
                self.shutdown_request(request); slots.release()
        try: threading.Thread(target=serve, daemon=True).start()
        except Exception: self.shutdown_request(request); slots.release()


class V4(Capped): pass
class V6(Capped): address_family = socket.AF_INET6


def main():
    servers = []
    for port in [PORT] + list(TUNNEL_PORTS):
        for cls, host in ((V4, "127.0.0.1"), (V6, "::1")):
            try: servers.append(cls((host, port), Handler))
            except OSError as e: print("warn: bind %s:%d: %s" % (host, port, e), file=sys.stderr, flush=True)
    if not any(s.server_address[1] == PORT for s in servers): raise SystemExit("could not bind %d" % PORT)
    ts = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for t in ts: t.start()
    for t in ts: t.join()


if __name__ == "__main__": main()
CCN_EOF_cc_alarm_listener_py
  cat > "$DIR/cc_alarm.sh" <<'CCN_EOF_cc_alarm_sh'
#!/bin/bash
# Round-complete alarm (armed mode). Configurable via ~/.cc-notifier/config:
#   CC_ALARM_SOUND     default Blow ("Breeze")
#   CC_ALARM_REPEATS   how many times the sound plays (default 10)
#   CC_ALARM_INTERVAL  seconds between plays (default 1)
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_ALARM_SOUND:-/System/Library/Sounds/Blow.aiff}"
REPEATS="${CC_ALARM_REPEATS:-10}"
INTERVAL="${CC_ALARM_INTERVAL:-1}"
TITLE="${CC_ALARM_TITLE:-${CC_AGENT:-Claude Code}}"   # the sender names its agent (Claude Code, Codex, ...)
MSG="${CC_ALARM_MSG:-Round complete}"
BUTTON="Stop"
TIMEOUT="${CC_ALARM_TIMEOUT:-60}"
. "$HERE/_attention.sh"
CCN_EOF_cc_alarm_sh
  cat > "$DIR/cc_ask.sh" <<'CCN_EOF_cc_ask_sh'
#!/bin/bash
# "The agent needs your input" alarm (AskUserQuestion). Configurable via ~/.cc-notifier/config:
#   CC_ASK_SOUND     default Funk
#   CC_ASK_REPEATS   how many times the sound plays (default 3)
#   CC_ASK_INTERVAL  seconds between plays (default 1)
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_ASK_SOUND:-/System/Library/Sounds/Funk.aiff}"
REPEATS="${CC_ASK_REPEATS:-3}"
INTERVAL="${CC_ASK_INTERVAL:-1}"
TITLE="${CC_ASK_TITLE:-${CC_AGENT:-Claude Code}}"
MSG="${CC_ASK_MSG:-Needs your input — answer the question in VSCode}"
BUTTON="OK"
TIMEOUT="${CC_ASK_TIMEOUT:-120}"
. "$HERE/_attention.sh"
CCN_EOF_cc_ask_sh
  cat > "$DIR/cc_beep.sh" <<'CCN_EOF_cc_beep_sh'
#!/bin/bash
# Short chime — single play, gated by the active macOS Focus (cc_focus.sh):
# muted in Sleep / Do-Not-Disturb, played otherwise. Sound configurable; no repeats.
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/config" ] && . "$HERE/config"
SOUND="${CC_BEEP_SOUND:-/System/Library/Sounds/Glass.aiff}"
[ -f "$HERE/cc_focus.sh" ] && . "$HERE/cc_focus.sh"
if ! command -v cc_should_play >/dev/null 2>&1 || cc_should_play; then afplay "$SOUND"; fi
CCN_EOF_cc_beep_sh
  cat > "$DIR/cc_check_hotkeys.py" <<'CCN_EOF_cc_check_hotkeys_py'
#!/usr/bin/env python3
"""List enabled macOS *system* keyboard shortcuts (does NOT cover app/3rd-party).
Usage: cc_check_hotkeys.py [filter]"""
import os, plistlib, subprocess, sys
PLIST = os.path.expanduser("~/Library/Preferences/com.apple.symbolichotkeys.plist")
MODS = [(1<<17,"Shift"),(1<<18,"Control"),(1<<19,"Option"),(1<<20,"Command")]
def mods(m): return "+".join(s for b,s in MODS if int(m)&b) or "(none)"
def kc(p1,p2): p1=int(p1); return chr(p1).upper() if 32<=p1<127 else f"keycode-{int(p2)}"
def main():
    needle = sys.argv[1].lower() if len(sys.argv)>1 else None
    try:
        xml = subprocess.run(["plutil","-convert","xml1","-o","-",PLIST],capture_output=True,check=True).stdout
        keys = plistlib.loads(xml).get("AppleSymbolicHotKeys",{})
    except Exception as e: print(f"could not read {PLIST}: {e}"); return
    rows=[]
    for kid,info in keys.items():
        if not isinstance(info,dict) or not info.get("enabled"): continue
        v=info.get("value",{}); p=v.get("parameters") if isinstance(v,dict) else None
        if not p or len(p)<3: continue
        rows.append(f"{mods(p[2])+' + '+kc(p[0],p[1]):28s}  system hotkey id {kid}")
    for r in sorted(rows):
        if not needle or needle in r.lower(): print(r)
    print("\nApp-menu & third-party global hotkeys are NOT listed — also check System Settings > Keyboard > Keyboard Shortcuts.")
if __name__=="__main__": main()
CCN_EOF_cc_check_hotkeys_py
  cat > "$DIR/cc_focus.sh" <<'CCN_EOF_cc_focus_sh'
#!/bin/bash
# Decide whether the alarm/beep SOUND should play under the active macOS Focus.
# Source this, then call cc_should_play: returns 0 = PLAY, 1 = MUTE.
#
# afplay is direct audio, not a notification, so Focus/DND can't mute it — we
# detect the active Focus ourselves and skip afplay in the muted modes. The
# banner is gated separately by the per-app Focus allow-list (System Settings).
#
# Detection, in order:
#   1. `shortcuts run CurrentFocus` — a 1-action "Get Current Focus" Shortcut you
#      create once (no Full Disk Access; sees scheduled + manual focuses).
#   2. ~/Library/DoNotDisturb/DB/Assertions.json — fallback (may need Full Disk
#      Access; misses scheduled focuses). Parsed with python3 (no jq dependency).
#   Undetected/unknown => PLAY (never silently swallow an alarm).
#
# Config (~/.cc-notifier/config):
#   CC_MUTE_FOCUS   space-separated substrings to mute on (case-insensitive),
#                   matched against the Shortcut name AND the raw mode id.
#   CC_FOCUS_DEBUG  1 => print the detected token to stderr.
: "${CC_MUTE_FOCUS:=sleep donotdisturb.mode.default}"

_cc_focus_token() {
  if command -v shortcuts >/dev/null 2>&1; then
    # --output-path writes the result to a FILE (documented behavior); the
    # shortcut must end with "Stop and Output" (or an output-producing action).
    local tmp n=""
    tmp="${TMPDIR:-/tmp}/cc_focus.$$"; rm -f "$tmp"
    if shortcuts run CurrentFocus --output-path "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      n="$(tr -d '\r' < "$tmp" | head -n1)"
    fi
    rm -f "$tmp"
    # Fallback: some builds emit to stdout when it is a pipe.
    [ -n "$n" ] || n="$(shortcuts run CurrentFocus 2>/dev/null | tr -d '\r' | head -n1)"
    [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  fi
  local A="$HOME/Library/DoNotDisturb/DB/Assertions.json"
  if [ -r "$A" ]; then
    local PYB; PYB="$(command -v python3 || echo /usr/bin/python3)"
    "$PYB" -c 'import sys, json
try:
    d = json.load(open(sys.argv[1]))
    recs = (d.get("data") or [{}])[0].get("storeAssertionRecords") or []
    r = max(recs, key=lambda x: x.get("assertionDetails", {}).get("assertionStartDateTimestamp", 0)) if recs else {}
    sys.stdout.write(r.get("assertionDetails", {}).get("assertionDetailsModeIdentifier", ""))
except Exception:
    pass' "$A" 2>/dev/null
  fi
}

cc_should_play() {
  local tok; tok="$(_cc_focus_token)"
  [ "${CC_FOCUS_DEBUG:-0}" = 1 ] && printf 'cc-focus: token=[%s] mute=[%s]\n' "$tok" "$CC_MUTE_FOCUS" >&2
  [ -z "$tok" ] && return 0                          # unknown -> PLAY
  local lc m mm; lc="$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')"
  for m in $CC_MUTE_FOCUS; do
    mm="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in *"$mm"*) return 1;; esac
  done
  case "$lc" in *"do not disturb"*) return 1;; esac   # Shortcut display name for DND
  return 0
}
CCN_EOF_cc_focus_sh
  cat > "$DIR/cc_hotkey.py" <<'CCN_EOF_cc_hotkey_py'
#!/usr/bin/env python3
"""Print the cc-notifier stop hotkey as a chord (e.g. "⌃⌥Z"), read from the
Karabiner-Elements config, so the alarm banner can remind you how to silence it.
Looks at the active config first, then the staged asset. Prints nothing if no
cc-notifier rule is found (e.g. Karabiner not used)."""
import json
import os

SYM = {"control": "⌃", "option": "⌥", "command": "⌘", "shift": "⇧", "fn": "fn"}
ORDER = ["control", "option", "shift", "command", "fn"]


def _base(mod):
    return mod.replace("left_", "").replace("right_", "")


def chord_from_rule(rule):
    for m in rule.get("manipulators", []):
        frm = m.get("from", {})
        key = frm.get("key_code")
        if not key:
            continue
        mods = frm.get("modifiers", {}).get("mandatory", [])
        mods = sorted(mods, key=lambda x: ORDER.index(_base(x)) if _base(x) in ORDER else 99)
        syms = "".join(SYM.get(_base(x), "") for x in mods)
        return f"{syms}{key.upper()}"
    return None


def find_chord():
    home = os.path.expanduser("~")
    active = os.path.join(home, ".config/karabiner/karabiner.json")
    try:
        with open(active) as f:
            cfg = json.load(f)
        for prof in cfg.get("profiles", []):
            for rule in prof.get("complex_modifications", {}).get("rules", []):
                if "cc-notifier" in rule.get("description", "").lower():
                    c = chord_from_rule(rule)
                    if c:
                        return c
    except Exception:
        pass
    asset = os.path.join(home, ".config/karabiner/assets/complex_modifications/cc-notifier.json")
    try:
        with open(asset) as f:
            data = json.load(f)
        for rule in data.get("rules", []):
            c = chord_from_rule(rule)
            if c:
                return c
    except Exception:
        pass
    return None


if __name__ == "__main__":
    c = find_chord()
    if c:
        print(c)
CCN_EOF_cc_hotkey_py
  cat > "$DIR/cc_preview_sounds.sh" <<'CCN_EOF_cc_preview_sounds_sh'
#!/bin/bash
# Preview macOS sounds. cc_preview_sounds.sh [once|loop] [Name...]
MODE="once"; case "$1" in once|loop) MODE="$1"; shift;; esac
if [ "$#" -gt 0 ]; then FILES=(); for n in "$@"; do FILES+=("/System/Library/Sounds/${n}.aiff"); done
else FILES=(/System/Library/Sounds/*.aiff ~/Library/Sounds/*.aiff); fi
for f in "${FILES[@]}"; do [ -f "$f" ] || continue; printf '> %s\n' "$(basename "$f" .aiff)"
  if [ "$MODE" = loop ]; then e=$((SECONDS+5)); while [ "$SECONDS" -lt "$e" ]; do afplay "$f"; done; else afplay "$f"; fi
  sleep 0.4; done
CCN_EOF_cc_preview_sounds_sh
  cat > "$DIR/cc_stop.sh" <<'CCN_EOF_cc_stop_sh'
#!/bin/bash
# Instant local stop — bind to a hotkey (Karabiner / Shortcuts: Run Shell Script).
# Silences every alarm. Signed with the token like every request (cc_client.py,
# installed next to this script); the token is never on a command line.
DIR="$(cd "$(dirname "$0")" && pwd)"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
CC_NOTIFIER_DIR="$DIR" CC_NOTIFY_TIMEOUT=2 "$PYBIN" "$DIR/cc_client.py" send stop >/dev/null 2>&1
CCN_EOF_cc_stop_sh
  cat > "$DIR/cc_telegram.py" <<'CCN_EOF_cc_telegram_py'
#!/usr/bin/env python3
"""Send one notification to Telegram, whatever its length (receiver side).

Called by _attention.sh with everything in the environment:
  CC_TELEGRAM_TOKEN, CC_TELEGRAM_CHAT_ID   the bot and the chat
  CC_TG_STATUS            last line: agent, status, host/project
  CC_TITLE                session title
  CC_BODY_FILE            file with the final message as plain text, any length
                          (removed here once read; $CC_BODY is used when there is no file)
  CC_TELEGRAM_FOLD_CHARS  a body longer than this is folded (default 1500; 0 = never)

One Telegram message holds 4,096 characters, so a longer text goes out as several
messages, in order. To keep the chat short, a long body shows its opening and
folds the rest into an expandable quote: tap it to read on. Nothing is hosted
anywhere; the text lives in the chat and nowhere else.

The HTTPS call is curl's, as everywhere else in this kit. The bot token is part of
the URL, so curl reads the URL from its standard input (a config), never from its
command line, which any local user can list. Exit status 0 when the first message
was accepted; the caller sends its short form otherwise.
"""
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time

LIMIT = 4000          # per message, counted as Telegram counts (UTF-16 units); the hard limit is 4096
OPENING = 700         # how much of a folded body stays visible above the fold
HERE = os.path.dirname(os.path.abspath(__file__))


def u16(s):
    return len(s.encode("utf-16-le")) // 2


def take(text, budget):
    """-> (head, rest): the longest head within budget that ends at a paragraph,
    else at a line, a sentence, a word."""
    if u16(text) <= budget:
        return text, ""
    cut = text[:budget]
    while u16(cut) > budget:                      # characters outside the basic plane count twice
        cut = cut[:-max(1, (u16(cut) - budget) // 2)]
    for sep, keep, least in (("\n\n", 0, 0.5), ("\n", 0, 0.5), (". ", 1, 0.4), (" ", 0, 0.3)):
        at = cut.rfind(sep)
        if at >= len(cut) * least:
            before = cut[:at].rfind("\n\n")
            last = cut[before + 2:at] if before >= 0 else ""
            if sep == "\n\n" and last and len(last) <= 80 and "\n" not in last and last[-1] not in ".!?:)\u2026" \
                    and before >= len(cut) * 0.3:
                at = before                       # a heading goes with the section it opens
            return cut[:at + keep].rstrip(), text[at + keep:].lstrip()
    return cut, text[len(cut):]


def compose(title, body, status, fold=1500, limit=LIMIT):
    """-> the messages to send, each a dict: head (bold), text (shown), fold (in an
    expandable quote), tail (status line). Their shown length stays within limit."""
    title, body, status = title.strip(), body.strip(), status.strip()
    shown, rest = body, ""
    if fold > 0 and u16(body) > fold:
        shown, rest = take(body, OPENING)
    first = dict(head=title, text=shown, fold="", tail=status)
    room = limit - u16(title) - u16(shown) - u16(status) - 8
    if fold <= 0:                                 # no folding: the body simply continues in the next message
        first["text"], rest = take(body, limit - u16(title) - u16(status) - 8)
    elif rest:
        first["fold"], rest = take(rest, max(room, 200))
    parts = [first]
    while rest:
        chunk, rest = take(rest, limit - u16(title) - 24)
        parts.append(dict(head="", text="" if fold > 0 else chunk, fold=chunk if fold > 0 else "", tail=""))
    for i, part in enumerate(parts[1:], 2):
        part["head"] = ("(%d/%d) %s" % (i, len(parts), title)).strip()
    return parts


def render(part, as_html):
    """One message as Telegram HTML, or as plain text when Telegram would not take that."""
    esc = (lambda s: html.escape(s, quote=False)) if as_html else (lambda s: s)
    out = []
    if part["head"]:
        out.append("<b>%s</b>" % esc(part["head"]) if as_html else part["head"])
    if part["text"]:
        out.append(esc(part["text"]))
    if part["fold"]:
        out.append("<blockquote expandable>%s</blockquote>" % esc(part["fold"]) if as_html else "\n" + part["fold"])
    text = "\n".join(out)
    if part["tail"]:
        text += ("\n" if part["fold"] and as_html else "\n\n") + esc(part["tail"])
    return text


def curl_config(options):
    """[(option, value)] -> a curl config file (curl --config -), values quoted."""
    q = lambda v: '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
    return "".join("%s = %s\n" % (name, q(value)) for name, value in options).encode("utf-8")


def send(token, chat, text, as_html):
    """-> Telegram's answer as a dict ({} when there was none)."""
    if not (re.match(r"[0-9A-Za-z:_-]+\Z", token) and re.match(r"[0-9A-Za-z@_-]+\Z", chat)):
        return {"description": "CC_TELEGRAM_TOKEN or CC_TELEGRAM_CHAT_ID has an unexpected character"}
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as f:
        f.write(text)
    options = [("url", "https://api.telegram.org/bot%s/sendMessage" % token),
               ("data-urlencode", "chat_id=" + chat), ("data-urlencode", "text@" + f.name),
               ("data-urlencode", "disable_web_page_preview=true")]
    if as_html:
        options.append(("data-urlencode", "parse_mode=HTML"))
    try:
        p = subprocess.run(["curl", "-s", "--max-time", "15", "--config", "-"], input=curl_config(options),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return json.loads(p.stdout.decode("utf-8", "replace"))
    except Exception:
        return {}
    finally:
        os.unlink(f.name)


def deliver(token, chat, part):
    """Send one message: as HTML, then as plain text if Telegram refuses the HTML;
    wait once when it asks for a pause. -> (accepted?, what Telegram said)"""
    answer = {}
    for as_html in (True, False):
        for attempt in (1, 2):
            answer = send(token, chat, render(part, as_html), as_html)
            if answer.get("ok"):
                return True, "html" if as_html else "plain"
            wait = (answer.get("parameters") or {}).get("retry_after")
            if answer.get("error_code") != 429 or not isinstance(wait, int):
                break
            time.sleep(min(wait, 20) + 1)
    return False, "%s %s" % (answer.get("error_code", "no answer"), answer.get("description", ""))


def log(line):
    path = os.path.join(HERE, "telegram.log")
    try:
        if os.path.exists(path) and os.path.getsize(path) > 200000:
            os.replace(path, path + ".1")
        with open(path, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), line))
    except Exception:
        pass


def main():
    env = os.environ
    try:
        os.setsid()       # outlive the alarm: stopping it must not leave half a message in the chat
    except OSError:
        pass
    token, chat = env.get("CC_TELEGRAM_TOKEN", ""), env.get("CC_TELEGRAM_CHAT_ID", "")
    body, path = env.get("CC_BODY", ""), env.get("CC_BODY_FILE", "")
    if path:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                body = f.read()
            os.unlink(path)
        except Exception:
            pass
    if not (token and chat and body.strip()):
        return 1
    try:
        fold = int(env.get("CC_TELEGRAM_FOLD_CHARS") or 1500)
    except ValueError:
        fold = 1500
    parts = compose(env.get("CC_TITLE", ""), body, env.get("CC_TG_STATUS", ""), fold)
    tag = "session=%s chars=%d parts=%d" % (env.get("CC_SESSION", "")[:8] or "-", len(body), len(parts))
    for i, part in enumerate(parts, 1):
        ok, said = deliver(token, chat, part)
        if not ok:
            log("%s FAILED at part %d: %s" % (tag, i, said))
            return 1 if i == 1 else 0             # nothing sent: the caller's short form goes out instead
        if said == "plain":
            log("%s part %d sent as plain text (Telegram refused the formatted one)" % (tag, i))
        if i < len(parts):
            time.sleep(0.4)                       # keep the order, stay under the per-chat rate
    log("%s sent" % tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
CCN_EOF_cc_telegram_py
  cat > "$DIR/cc_tunnel_keep.sh" <<'CCN_EOF_cc_tunnel_keep_sh'
#!/bin/bash
# Keep the cc-notifier reverse tunnels alive (run periodically by launchd on the Mac).
# It only ever touches EXISTING ssh masters (your shared ControlPath), so:
#   - each forward stays co-located with your VSCode/CC session (right login node), and
#   - NO new ssh connection is opened (nothing for an HPC admin to flag).
# No-op unless CC_TUNNEL_HOST is set in config: your ssh host alias for each remote,
# separated by spaces or commas (CC_TUNNEL_HOST="aurora polaris").
#
# Each tunnel is checked with a proof only this Mac's listener can give, made with
# that host's own key on that host's own port (ports/<host>; the shared key's
# machines end at this Mac's own port). A forward is changed only when that is
# clearly right: nothing listens at the far end (put it back), or the tunnel leads
# to this Mac but to the wrong port (point it at the right one). A busy or silent
# port, or someone else holding it, is left alone and logged: cancelling there
# would hand the port to whoever grabs it first.
export LC_ALL=C                              # character sets below mean ASCII, whatever the locale
DIR="${CC_NOTIFIER_DIR:-$HOME/.cc-notifier}"
[ -f "$DIR/config" ] && . "$DIR/config"
PORT="${CC_NOTIFY_PORT:-28765}"             # this Mac's own port
RPORT="${CC_REMOTE_PORT:-28765}"            # the port the hooks use at the far end
HOSTS="$(printf '%s' "${CC_TUNNEL_HOST:-}" | tr ',' ' ')"
[ -n "$HOSTS" ] || exit 0                                # not configured -> off
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
say(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
client(){ CC_NOTIFIER_DIR="$DIR" CC_NOTIFY_PORT="$PORT" "$PYBIN" "$DIR/cc_client.py" "$@"; }

# Without a working key of its own this Mac cannot tell a healthy tunnel from a
# broken one: change nothing.
case "$(client ping 2>/dev/null)" in
  proto=*\ verified=yes\ as=local\ *) ;;
  *) say "this Mac's own key does not work with its listener: run ~/.cc-notifier/cc_token.sh new (no tunnel touched)"; exit 0;;
esac

# probe <host> <query>: the far end's answer to /ping?<query>, then " curl_exit=<n>"
probe(){ ssh "$1" "sh -c 'curl -s --noproxy \"*\" --max-time 2 \"http://localhost:$RPORT/ping?$2\"; echo \" curl_exit=\$?\"'" 2>/dev/null; }
proves(){ printf '%s' "${1% curl_exit=*}" | client verify "$2" >/dev/null 2>&1; }

for HOST in $HOSTS; do
  case "$HOST" in [abcdefghijklmnopqrstuvwxyz0123456789]*) ;; *) say "skipping '$HOST': not a lowercase ssh alias"; continue;; esac
  case "$HOST" in *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) say "skipping '$HOST': not a lowercase ssh alias"; continue;; esac
  ssh -O check "$HOST" >/dev/null 2>&1 || continue      # no live master -> nothing to inject into
  if [ -s "$DIR/keys/$HOST" ] && [ -s "$DIR/ports/$HOST" ]; then want="$(cat "$DIR/ports/$HOST")"; k="$HOST"
  else want="$PORT"; k="local"; fi                      # still on the shared key: ends at this Mac's own port
  q="$(client challenge "$k" 2>/dev/null)" || continue
  out="$(probe "$HOST" "$q")"
  proves "$out" "$q" && continue                         # healthy
  ec="${out##*curl_exit=}"
  case "$ec" in
    7)  # nothing listens at the far end: put the forward back
        ssh -O cancel -R "$RPORT:localhost:$PORT" "$HOST" >/dev/null 2>&1
        ssh -O cancel -R "$RPORT:localhost:$want" "$HOST" >/dev/null 2>&1
        if ! err="$(ssh -O forward -R "$RPORT:localhost:$want" "$HOST" 2>&1)"; then
          say "could not forward port $RPORT on $HOST to $want: $err"
        fi;;
    0)  # something answered, but not with this host's proof: our listener on the wrong port?
        if [ "$want" != "$PORT" ]; then
          q2="$(client challenge local 2>/dev/null)"
          if [ -n "$q2" ] && proves "$(probe "$HOST" "$q2")" "$q2"; then
            ssh -O cancel -R "$RPORT:localhost:$PORT" "$HOST" >/dev/null 2>&1
            ssh -O forward -R "$RPORT:localhost:$want" "$HOST" >/dev/null 2>&1 \
              && say "$HOST: its tunnel led to port $PORT; now to $want (set 'RemoteForward $RPORT localhost:$want' under Host $HOST in ~/.ssh/config)"
            continue
          fi
        fi
        say "$HOST: something answers on port $RPORT there but cannot prove it is this Mac (someone else holds the port, or a relay): nothing is sent to it; left alone";;
    *)  say "$HOST: no clear answer from port $RPORT there (curl exit ${ec:-?}: busy, or the check failed): left alone";;
  esac
done
exit 0
CCN_EOF_cc_tunnel_keep_sh
  cat > "$DIR/karabiner-stop.json" <<'CCN_EOF_karabiner_stop_json'
{
  "title": "cc-notifier",
  "rules": [
    {
      "description": "cc-notifier: Ctrl+Opt+Z -> stop the alarm (works even in the Claude Code chat box)",
      "manipulators": [
        {
          "type": "basic",
          "from": {
            "key_code": "z",
            "modifiers": { "mandatory": ["control", "option"], "optional": ["caps_lock"] }
          },
          "to": [
            { "shell_command": "$HOME/.cc-notifier/cc_stop.sh" }
          ]
        }
      ]
    }
  ]
}
CCN_EOF_karabiner_stop_json
  chmod +x "$DIR"/*.sh "$DIR"/*.py 2>/dev/null || true
}

write_config(){
  local cfg="$DIR/config"
  [ -f "$cfg" ] && return 0
  cat > "$cfg" <<'CFG_EOF'
# cc-notifier config — uncomment & edit. Read on each alarm (no reload needed).
# Long round-end alarm (armed mode):
#CC_ALARM_SOUND=/System/Library/Sounds/Blow.aiff
#CC_ALARM_REPEATS=10
#CC_ALARM_INTERVAL=1
# "Needs your input" alarm (AskUserQuestion):
#CC_ASK_SOUND=/System/Library/Sounds/Funk.aiff
#CC_ASK_REPEATS=3
#CC_ASK_INTERVAL=1
# Short chime (single play; sound only, no repeats):
#CC_BEEP_SOUND=/System/Library/Sounds/Glass.aiff
# Optional phone push via Telegram (relayed from THIS Mac). See README for setup.
#CC_TELEGRAM_TOKEN=123456789:ABCdef_your_bot_token
#CC_TELEGRAM_CHAT_ID=123456789
# The phone push carries the session title and the final message of the round,
# whole (plain text, over as many Telegram messages as it takes). That is text
# from your session; 0 keeps it on this Mac and sends the status and host/project
# only.
#CC_TELEGRAM_BRIEF=1
# A message longer than this many characters shows its opening and folds the rest
# into a quote you tap to expand, so the chat stays short. 0 = never fold.
#CC_TELEGRAM_FOLD_CHARS=1500
# Focus-aware sound: skip the alarm/beep AUDIO while these Focus modes are active
# (space-separated substrings, case-insensitive vs the Shortcut name + raw mode
# id). Empty = always play. Banner is gated separately via System Settings > Focus.
# Needs a "CurrentFocus" Shortcut on the Mac — see README.
#CC_MUTE_FOCUS="sleep donotdisturb.mode.default"
# Escape hatch: route the sound through the notification so Apple gates it for
# free (no detection) — but loses the looping alarm. 1 = on.
#CC_SOUND_VIA_ALERTER=0
# Reverse-tunnel auto-heal (REMOTE setups): your ssh host alias for the machine
# running Claude Code. Set this to enable the launchd keeper that re-injects the
# RemoteForward after network changes / window reloads / wake. Empty = off.
#CC_TUNNEL_HOST=aurora
CFG_EOF
  log "wrote config template: $cfg"
}

merge_hooks(){
  python3 - "$SETTINGS" "$DIR" <<'PYMERGE'
import json, os, sys
settings_path, d = sys.argv[1], sys.argv[2]
events = {
    "SessionStart":     ("notify_healthcheck.sh", 10, None),
    "UserPromptSubmit": ("notify_stop.sh", 5, None),
    "Stop":             ("notify_done.sh", 5, None),
    "PreToolUse":       ("notify_ask.sh", 5, "AskUserQuestion"),
}
try:
    with open(settings_path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
hooks = cfg.setdefault("hooks", {})
for ev, (script, to, matcher) in events.items():
    cmd = os.path.join(d, script)
    arr = hooks.setdefault(ev, [])
    present = any(
        isinstance(h, dict) and h.get("command") == cmd
        for grp in arr if isinstance(grp, dict)
        for h in grp.get("hooks", []) )
    if present: continue
    entry = {"hooks": [{"type": "command", "command": cmd, "timeout": to}]}
    if matcher: entry["matcher"] = matcher
    arr.append(entry)
os.makedirs(os.path.dirname(settings_path) or ".", exist_ok=True)
with open(settings_path, "w") as f: json.dump(cfg, f, indent=2)
print("  hooks merged into", settings_path)
PYMERGE
}

# Codex takes the same hook scripts. Its hooks file is the user's to change, so
# this only happens on request; otherwise say how to switch it on.
codex_hooks(){
  [ -d "${CODEX_HOME:-$HOME/.codex}" ] || return 0
  if [ "$CODEX" = 1 ]; then "$DIR/cc_codex_hooks.sh" on | sed 's/^/  /' || true
  elif ! "$DIR/cc_codex_hooks.sh" status >/dev/null 2>&1; then
    log "Codex found: for round-end notifications from it too, run  $DIR/cc_codex_hooks.sh on"
  fi
}

install_launchd(){
  local plist="$HOME/Library/LaunchAgents/com.ccnotifier.listener.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ccnotifier.listener</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>$DIR/cc_alarm_listener.py</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>CC_NOTIFY_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>$DIR/listener.log</string>
  <key>StandardErrorPath</key><string>$DIR/listener.log</string>
</dict></plist>
PLIST_EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist" && log "launchd listener loaded (port $PORT)"
}

install_tunnel_keeper(){
  local plist="$HOME/Library/LaunchAgents/com.ccnotifier.tunnel.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ccnotifier.tunnel</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$DIR/cc_tunnel_keep.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>WatchPaths</key><array><string>/etc/resolv.conf</string></array>
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>$DIR/tunnel.log</string>
  <key>StandardErrorPath</key><string>$DIR/tunnel.log</string>
</dict></plist>
PLIST_EOF
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist" && log "tunnel keeper loaded (re-heals the reverse tunnel every 60s + on network change; set CC_TUNNEL_HOST to enable)"
}

apply_port(){
  [ "$PORT" = "28765" ] && return 0
  find "$DIR" -type f \( -name '*.sh' -o -name '*.py' \) -exec sed -i.bak "s/28765/$PORT/g" {} \;
  find "$DIR" -name '*.bak' -delete
}

do_uninstall(){
  hdr "uninstall"
  if [ "$OS" = Darwin ]; then
    local p
    for p in com.ccnotifier.listener com.ccnotifier.tunnel; do
      p="$HOME/Library/LaunchAgents/$p.plist"
      launchctl unload "$p" 2>/dev/null || true; rm -f "$p"
    done
    log "launchd agents removed"
  fi
  python3 - "$SETTINGS" "$DIR" <<'PYUNMERGE'
import json, os, sys
settings_path, d = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f: cfg = json.load(f)
except Exception: sys.exit(0)
mine = {os.path.join(d, n) for n in
        ("notify_healthcheck.sh","notify_stop.sh","notify_done.sh","notify_ask.sh")}
for ev, arr in list(cfg.get("hooks", {}).items()):
    arr[:] = [g for g in arr if not any(
        isinstance(h, dict) and h.get("command") in mine for h in (g.get("hooks", []) if isinstance(g, dict) else []))]
    if not arr: del cfg["hooks"][ev]
with open(settings_path, "w") as f: json.dump(cfg, f, indent=2)
print("  hooks removed from", settings_path)
PYUNMERGE
  if [ -x "$DIR/cc_codex_hooks.sh" ] && [ -d "${CODEX_HOME:-$HOME/.codex}" ]; then
    "$DIR/cc_codex_hooks.sh" off | grep -v 'already absent' | sed 's/^/  /' || true
  fi
  log "(left $DIR in place — 'rm -rf $DIR' to fully remove)"
  exit 0
}

[ "$UNINSTALL" = 1 ] && do_uninstall

hdr "cc-notifier install — role: $ROLE (port $PORT, dir $DIR)"
if [ "$ROLE" = receiver ]; then
  write_receiver
  write_sender
  write_config
  apply_port
  secure_files
  receiver_keys
  merge_hooks
  codex_hooks
  if [ "$OS" = Darwin ]; then
    if ! command -v alerter >/dev/null 2>&1; then
      if command -v brew >/dev/null 2>&1; then
        log "installing alerter…"; brew install vjeantet/tap/alerter || log "WARN: alerter install failed"
      else
        log "WARN: install Homebrew then: brew install vjeantet/tap/alerter (needed for the Stop button)"
      fi
    fi
    install_launchd
    own_key
    install_tunnel_keeper
    if [ -d "$HOME/.config/karabiner" ]; then
      mkdir -p "$HOME/.config/karabiner/assets/complex_modifications"
      cp "$DIR/karabiner-stop.json" "$HOME/.config/karabiner/assets/complex_modifications/cc-notifier.json"
      log "Karabiner rule staged — enable it in Karabiner › Complex Modifications › Add rule"
    else
      log "tip: install Karabiner-Elements + import $DIR/karabiner-stop.json for a hotkey that works in the CC chat box"
    fi
    command -v alerter >/dev/null 2>&1 && alerter --title "cc-notifier" --message "installed — allow Terminal notifications (Alerts style); for Focus, allow Terminal in Work" --timeout 4 >/dev/null 2>&1 || true
  else
    own_key
    log "NOTE: receiver role outside macOS — wrote files but skipped launchd/alerter."
  fi
  hdr "manual steps (one-time, GUI)"
  cat <<EOF_NEXT
  1. macOS notifications: System Settings > Notifications > Terminal -> Allow,
       style "Alerts". (alerter posts under Terminal's identity — it has no
       entry of its own in either pane.)
  2. Break Focus (banner): System Settings > Focus > Work > Allowed Notifications
       > Apps > add "Terminal". Keep Terminal OUT of Sleep / DND.
  3. Focus-aware sound: in Shortcuts.app create a shortcut named exactly
       "CurrentFocus" with TWO actions: [Get Current Focus] then
       [Stop and Output <Current Focus>]. The Stop-and-Output step is REQUIRED.
       Verify: shortcuts run CurrentFocus --output-path /tmp/f.txt && cat /tmp/f.txt
  4. Stop hotkey (works in the CC chat box): Karabiner-Elements > Complex
       Modifications > Add rule > Enable "cc-notifier: Ctrl+Opt+Z -> stop".
       (No Karabiner? A macOS Shortcut running $DIR/cc_stop.sh works everywhere
       EXCEPT the CC input box.)
  5. Pick sounds / repeats: $DIR/cc_preview_sounds.sh loop   (set knobs in $DIR/config)
  6. For REMOTE machines: give each one its key and port, from here:
       $DIR/cc_token.sh push <ssh alias of the remote>
     and put the line it prints under that host in ~/.ssh/config:
       RemoteForward $PORT localhost:<the port it prints, one per remote>
  7. Auto-heal the tunnels (REMOTE setups): set CC_TUNNEL_HOST="<alias> <alias>..."
       in $DIR/config — the launchd keeper then re-injects each forward after
       network changes / reloads / wake (no new ssh connections).
  Test now:  $DIR/cc_tunnel_test.sh beep   (and: $DIR/cc_tunnel_test.sh ask)
  Arm/disarm any session:  $DIR/cc_notify_arm.sh on | off | status
  Diagnose anytime:  $DIR/cc_doctor.sh
  Each REMOTE needs a key of its own from this Mac (it moves over ssh, never on a command line):
       $DIR/cc_token.sh push <ssh alias of the remote>...
EOF_NEXT
  if [ "$FROM_OLD" = 1 ]; then
    hdr "now: new keys"
    cat <<EOF_ROTATE
  The kit you had sent the token itself with every request, so it may have been
  seen. Once each remote runs the new sender too, give each one a new key of its
  own, then retire the old token:
       $DIR/cc_token.sh rotate <ssh alias of each remote>...
       $DIR/cc_token.sh revoke shared
EOF_ROTATE
  elif [ "$FROM_SHARED" = 1 ]; then
    hdr "now: a key for each remote"
    cat <<EOF_KEYS
  Your remotes still share one token; it keeps working until you retire it.
  Give each remote a key of its own, then retire the shared token:
       $DIR/cc_token.sh push <ssh alias of each remote>...
       $DIR/cc_token.sh revoke shared
EOF_KEYS
  fi
else
  write_sender
  apply_port
  if [ "$FROM_OLD" = 1 ]; then
    # Until the Mac runs protocol 6, keep serving its listener the way it expects,
    # but only with THIS token, which it had already. A new token never travels.
    python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read().strip()).hexdigest())' \
      "$DIR/token" > "$DIR/legacy-token.sha256"
  fi
  secure_files
  merge_hooks
  codex_hooks
  hdr "remote sender installed"
  cat <<EOF_NEXT
  Hooks wired into $SETTINGS (restart this CC session to load them).
  Notifies on round-complete (Stop) and questions (AskUserQuestion).
  Anything else can notify too:  $DIR/cc_notify.sh --title "..." "one-sentence summary"
  This machine notifies your Mac THROUGH an ssh reverse tunnel. On your Mac:
    1. Make sure the Mac receiver is installed (run this script on the Mac).
    2. Give this machine a key of its own and its port, from the Mac (over ssh,
       never on a command line):
         ~/.cc-notifier/cc_token.sh push <ssh alias of this machine>
    3. Put the line that prints under that host in the Mac's ~/.ssh/config:
         RemoteForward $PORT localhost:<its port>
  Verify from here:  $DIR/cc_tunnel_test.sh   (or full check: $DIR/cc_doctor.sh)
  Arm/disarm any session:  $DIR/cc_notify_arm.sh on | off | status
EOF_NEXT
  if [ ! -s "$DIR/token" ]; then log "NOTE: no key here yet, so nothing is sent: step 2."; fi
  if [ "$FROM_OLD" = 1 ]; then
    log "NOTE: until the Mac is updated too, its listener (protocol 5) still gets this machine's current token in a header. Then on the Mac: ~/.cc-notifier/cc_token.sh rotate <this machine>"
  fi
fi
hdr "done"
