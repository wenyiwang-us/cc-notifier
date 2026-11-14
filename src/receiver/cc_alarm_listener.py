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
