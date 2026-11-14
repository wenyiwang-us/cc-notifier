#!/usr/bin/env python3
"""The one HTTP client of cc-notifier: every script, on either end, sends through it.

Protocol 6. The shared token (<dir>/token, the same value on the Mac and on each
remote) is a key, and the key never travels:

  * Every request carries X-CC-Time, X-CC-Nonce and X-CC-Sig: an HMAC-SHA256,
    under the token, of the method, path, query, a hash of the body, the time and
    the nonce. The listener takes a request once, and only within WINDOW seconds
    of its time, so a copy of one can be neither changed nor sent again.
  * Before anything goes out, /ping?c=<challenge> has to answer with
    proof=HMAC(token, challenge), which only a listener holding the token can
    give. On a shared login node a dropped tunnel leaves the port free, and any
    user there can listen on it; such a listener gets nothing from us.
  * Nothing secret, and no message text, goes on a command line: any user of a
    shared host can list those. The fields come in the environment, which only
    the same user can read.

Moving from protocol 5. A listener of protocol 5 (the version before this one)
takes the token itself, in a header. A machine upgraded from that version keeps
<dir>/legacy-token.sha256, the hash of the token it had then; while that file
names the current token, and for LEGACY_HOURS after it was written, this client
still serves a protocol-5 listener that way (in a header, never on a command
line). The first time a protocol-6 listener proves itself the file is deleted,
and from then on the token never leaves this machine. A new token never matches
the file, so a new token never travels.

usage:
  cc_client.py send <alarm|done|ask|beep|stop>
      fields from the environment: CC_F_LABEL, CC_F_AGENT, CC_F_SESSION,
      CC_F_TITLE, CC_F_BRIEF, and the text for the phone push in the file
      CC_F_BODY_FILE (or in CC_F_BODY). `stop` without CC_F_SESSION silences
      every alarm. Prints "http=<code> err=<reason> auth=<signed|legacy|->";
      exit 0 when the listener answered 200.
  cc_client.py ping       prints what the listener says; exit 0 when it proved itself
  cc_client.py challenge  prints a fresh challenge (cc_tunnel_keep.sh on the Mac)
  cc_client.py verify <challenge>
      reads a /ping answer on stdin; exit 0 when its proof is right for <challenge>
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
from urllib.parse import quote, urlencode

PROTO = 6
PORT = int(os.environ.get("CC_NOTIFY_PORT") or "28765")
DIR = os.environ.get("CC_NOTIFIER_DIR") or os.path.join(os.path.expanduser("~"), ".cc-notifier")
LEGACY = "legacy-token.sha256"
LEGACY_HOURS = 72           # the move from protocol 5 must be finished by then
MAX_POST = 1 << 20          # the listener refuses a longer body
ACTS = ("alarm", "done", "ask", "beep", "stop")
FIELDS = (("label", "CC_F_LABEL"), ("agent", "CC_F_AGENT"), ("session", "CC_F_SESSION"),
          ("title", "CC_F_TITLE"), ("brief", "CC_F_BRIEF"))
CHALLENGE = re.compile(r"[0-9a-f]{32}\Z")


# --- the protocol (cc_alarm_listener.py holds the same three functions) ------

def request_sig(key, method, path, query, body, t, nonce):
    msg = "cc-notifier/6 req\n%s\n%s\n%s\n%s\n%d\n%s" % (
        method, path, query, hashlib.sha256(body).hexdigest(), t, nonce)
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).hexdigest()


def ping_proof(key, challenge):
    return hmac.new(key, ("cc-notifier/6 pong\n" + challenge).encode("utf-8"), hashlib.sha256).hexdigest()


def same(a, b):
    """Constant-time comparison of two strings of any content."""
    return hmac.compare_digest(str(a).encode("utf-8", "replace"), str(b).encode("utf-8", "replace"))


# --- this machine's side -----------------------------------------------------

def token_key():
    """The shared token as bytes, b"" when there is none."""
    try:
        with open(os.path.join(DIR, "token"), "rb") as f:
            return f.read().strip()
    except OSError:
        return b""


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
    """'ok proto=6 proof=...' -> {'proto': 6, 'proof': '...', ...}"""
    out = {}
    for word in (text or "").split():
        name, sep, value = word.partition("=")
        if sep:
            out[name] = value
    m = re.match(r"[0-9]{1,4}", out.get("proto", ""))
    out["proto"] = int(m.group(0)) if m else 0
    return out


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
    key = token_key()
    first = None
    for addr in addresses():
        challenge = secrets.token_hex(16)
        try:
            status, text = exchange(addr, "GET", "/ping?c=" + challenge, timeout=timeout)
        except (OSError, http.client.HTTPException):
            continue
        if status != 200:
            continue
        info = parse_ping(text)
        info["addr"] = addr
        info["verified"] = bool(key) and info["proto"] >= PROTO and same(info.get("proof", ""), ping_proof(key, challenge))
        if info["verified"]:
            return info
        if first is None:
            first = info
    return first


def send(act, fields, body=b"", timeout=5.0):
    """-> (HTTP status or 0, reason, how it was authenticated)"""
    key = token_key()
    if not key:
        return 0, "no_token", "-"
    info = ping(min(timeout, 2.0))
    if info is None:
        return 0, "unreachable", "-"
    path = "/" + act
    query = urlencode([(name, value) for name, value in fields if value], quote_via=quote)
    headers = {"Content-Type": "text/plain; charset=utf-8"}
    if info["verified"]:
        drop_legacy()
        t, nonce = int(time.time()), secrets.token_hex(16)
        headers.update({"X-CC-Time": str(t), "X-CC-Nonce": nonce,
                        "X-CC-Sig": request_sig(key, "POST", path, query, body, t, nonce)})
        auth = "signed"
    elif info["proto"] == 5 and legacy_allowed(key):
        headers["X-CC-Token"] = key.decode("utf-8", "replace")
        auth = "legacy"
    elif info["proto"] >= PROTO and info.get("auth") == "none":
        return 0, "listener_has_no_token", "-"
    elif info["proto"] >= PROTO:
        # It answers like a listener but cannot prove it holds our token: the two
        # ends have different tokens, or someone else holds the port here.
        return 0, "unverified", "-"
    else:
        return 0, "old_listener_proto%d" % info["proto"], "-"
    try:
        status, _ = exchange(info["addr"], "POST", path + ("?" + query if query else ""),
                             body=body, headers=headers, timeout=timeout)
    except socket.timeout:
        return 0, "timeout", auth
    except (OSError, http.client.HTTPException):
        return 0, "unreachable", auth
    return status, "ok" if status == 200 else "http_%d" % status, auth


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
        status, why, auth = send(argv[2], fields, body, timeout)
        print("http=%03d err=%s auth=%s" % (status, why, auth))
        return 0 if status == 200 else 1
    if cmd == "ping" and len(argv) == 2:
        info = ping(min(timeout, 2.0))
        if info is None:
            print("unreachable")
            return 1
        notes = ""
        if not info["verified"]:
            if not token_key():
                notes = " token=none"
            elif info["proto"] == 5 and legacy_allowed(token_key()):
                notes = " legacy=yes until=" + time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(legacy_until()))
            elif info["proto"] == 5 and legacy_until():
                notes = " legacy=expired"
        if info.get("auth"):
            notes += " listener_auth=" + info["auth"]
        print("proto=%d verified=%s%s" % (info["proto"], "yes" if info["verified"] else "no", notes))
        return 0 if info["verified"] else 1
    if cmd == "challenge" and len(argv) == 2:
        print(secrets.token_hex(16))
        return 0
    if cmd == "verify" and len(argv) == 3:
        key, challenge = token_key(), argv[2]
        info = parse_ping(sys.stdin.read(4096))
        ok = bool(key) and bool(CHALLENGE.match(challenge)) and info["proto"] >= PROTO \
            and same(info.get("proof", ""), ping_proof(key, challenge))
        return 0 if ok else 1
    sys.stderr.write(__doc__[__doc__.index("usage:"):])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
