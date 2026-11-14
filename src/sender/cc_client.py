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
