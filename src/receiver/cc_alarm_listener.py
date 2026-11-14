#!/usr/bin/env python3
"""Local alarm listener. Binds loopback on BOTH 127.0.0.1 and ::1 (ssh forwards
`localhost` may hit ::1 first). Endpoints: /beep /alarm /done /ask /stop /ping.

Alarms are kept per session: ?session=<id> on /alarm or /ask replaces only that
session's alarm, and /stop?session=<id> silences only that one. /stop without a
session (the stop hotkey, cc_stop.sh) silences them all. Requests that name no
session share one slot.

Guards:
  - rejects requests carrying a non-local Origin header (browser CSRF / DNS-rebind);
  - if a token file (<dir>/token) exists, action endpoints require a matching
    X-CC-Token header (/ping stays open for liveness). The token is re-read per
    request, so enabling/disabling auth needs no listener restart.
The ?agent=, ?label=, ?title= and ?brief= queries are sanitized and passed to the
alarm as $CC_AGENT (who is notifying: Claude Code, Codex, ...), $CC_LABEL,
$CC_TITLE and $CC_BRIEF ($CC_SESSION carries the session id). The message itself,
for the phone push, has line breaks and no length limit to speak of: it is the
body of a POST (text/plain), or ?body= from senders that cannot post, and
reaches the alarm in a file, $CC_BODY_FILE (too long for the environment).
Any sender can use these; none is required.
"""
import http.server, os, re, signal, socket, socketserver, subprocess, threading, time
from urllib.parse import urlsplit, parse_qs

PORT = int(os.environ.get("CC_NOTIFY_PORT", "28765"))
HERE = os.path.dirname(os.path.abspath(__file__))
ALARM = os.path.join(HERE, "cc_alarm.sh")
BEEP = os.path.join(HERE, "cc_beep.sh")
ASK = os.path.join(HERE, "cc_ask.sh")
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")
BODIES = os.path.join(HERE, "tmp")      # message bodies on their way to the phone push
PROTO = 5            # 2: per-session alarms, title + brief; 3: agent name, summary in the phone push; 4: message body in the phone push; 5: the whole message, posted. Reported by /ping.
MAX_POST = 1 << 20   # bytes of posted text read from one request
MAX_BODY = 60000     # characters of it passed on (about fifteen Telegram messages)
MAX_ALARMS = 16      # alarms alive at once; the oldest gives way beyond this

_lock = threading.Lock(); _alarms = {}   # session id ("" = none given) -> alarm process


def _token():
    try:
        with open(os.path.join(HERE, "token")) as f:
            return f.read().strip()
    except Exception:
        return ""


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


def stop_alarm(session=None):
    """Silence one session's alarm, or every alarm when no session is named."""
    with _lock:
        for key in (list(_alarms) if session is None else [session]):
            p = _alarms.pop(key, None)
            if p: _kill(p)


def start_proc(script, session="", **fields):
    env = dict(os.environ)
    env.update({k: v for k, v in fields.items() if v})
    with _lock:
        for key in [k for k, p in _alarms.items() if p.poll() is not None]: del _alarms[key]
        old = _alarms.pop(session, None)
        if old: _kill(old)
        while len(_alarms) >= MAX_ALARMS: _kill(_alarms.pop(next(iter(_alarms))))
        _alarms[session] = subprocess.Popen(["/bin/bash", script], start_new_session=True, env=env)


def play_beep():
    subprocess.Popen(["/bin/bash", BEEP], start_new_session=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def _route(self):
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).hostname not in LOCAL_HOSTS:
            self.send_response(403); self.end_headers(); return
        u = urlsplit(self.path)
        path = u.path.rstrip("/")
        tok = _token()
        if path != "/ping" and tok and self.headers.get("X-CC-Token", "") != tok:
            self.send_response(403); self.end_headers(); return
        q = parse_qs(u.query)
        arg = lambda name: q.get(name, [""])[0]
        posted = ""
        if self.command == "POST":
            try: size = int(self.headers.get("Content-Length") or 0)
            except ValueError: size = 0
            if size > MAX_POST: self.send_response(413); self.end_headers(); return
            if size > 0: posted = self.rfile.read(size).decode("utf-8", "replace")
        session = re.sub(r"[^A-Za-z0-9_-]", "", arg("session"))[:64]
        fields = dict(CC_LABEL=re.sub(r"[^\w\-./ ]", "", arg("label"))[:64], CC_SESSION=session,
                      CC_AGENT=_text(arg("agent"), 32), CC_TITLE=_text(arg("title"), 80),
                      CC_BRIEF=_text(arg("brief"), 400))
        if path in ("/alarm", "/done", "/ask"):
            fields["CC_BODY_FILE"] = _body_file(session, _body(posted or arg("body"), MAX_BODY))
        try:
            if path in ("/alarm", "/done"): start_proc(ALARM, session, **fields); body = b"alarm\n"
            elif path == "/ask": start_proc(ASK, session, **fields); body = b"ask\n"
            elif path == "/beep": play_beep(); body = b"beep\n"
            elif path == "/stop": stop_alarm(session if "session" in q else None); body = b"stopped\n"
            elif path in ("/ping", ""): body = b"ok proto=%d\n" % PROTO
            else: self.send_response(404); self.end_headers(); return
        except OSError:                           # the alarm could not be started: say so, do not look delivered
            self.send_response(500); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    do_GET = _route; do_POST = _route
    def log_message(self, *a): pass


class V4(socketserver.ThreadingTCPServer): allow_reuse_address = True; daemon_threads = True
class V6(socketserver.ThreadingTCPServer): address_family = socket.AF_INET6; allow_reuse_address = True; daemon_threads = True


def main():
    servers = []
    for cls, host in ((V4, "127.0.0.1"), (V6, "::1")):
        try: servers.append(cls((host, PORT), Handler))
        except OSError as e: print(f"warn: bind {host}:{PORT}: {e}", flush=True)
    if not servers: raise SystemExit(f"could not bind {PORT}")
    ts = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for t in ts: t.start()
    for t in ts: t.join()


if __name__ == "__main__": main()
