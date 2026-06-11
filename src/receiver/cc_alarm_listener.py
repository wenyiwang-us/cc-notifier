#!/usr/bin/env python3
"""Local alarm listener. Binds loopback on BOTH 127.0.0.1 and ::1 (ssh forwards
`localhost` may hit ::1 first). Endpoints: /beep /alarm /done /ask /stop /ping.

Guards:
  - rejects requests carrying a non-local Origin header (browser CSRF / DNS-rebind);
  - if a token file (<dir>/token) exists, action endpoints require a matching
    X-CC-Token header (/ping stays open for liveness). The token is re-read per
    request, so enabling/disabling auth needs no listener restart.
A ?label=... query is sanitized and passed to the alarm as $CC_LABEL.
"""
import http.server, os, re, signal, socket, socketserver, subprocess, threading
from urllib.parse import urlsplit, parse_qs

PORT = int(os.environ.get("CC_NOTIFY_PORT", "28765"))
HERE = os.path.dirname(os.path.abspath(__file__))
ALARM = os.path.join(HERE, "cc_alarm.sh")
BEEP = os.path.join(HERE, "cc_beep.sh")
ASK = os.path.join(HERE, "cc_ask.sh")
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1")

_lock = threading.Lock(); _current = None


def _token():
    try:
        with open(os.path.join(HERE, "token")) as f:
            return f.read().strip()
    except Exception:
        return ""


def stop_alarm():
    global _current
    with _lock:
        if _current and _current.poll() is None:
            try: os.killpg(os.getpgid(_current.pid), signal.SIGTERM)
            except ProcessLookupError: pass
        _current = None


def start_proc(script, label=""):
    global _current
    stop_alarm()
    env = dict(os.environ)
    if label: env["CC_LABEL"] = label
    with _lock:
        _current = subprocess.Popen(["/bin/bash", script], start_new_session=True, env=env)


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
        label = re.sub(r"[^\w\-./ ]", "", parse_qs(u.query).get("label", [""])[0])[:64]
        if path in ("/alarm", "/done"): start_proc(ALARM, label); body = b"alarm\n"
        elif path == "/ask": start_proc(ASK, label); body = b"ask\n"
        elif path == "/beep": play_beep(); body = b"beep\n"
        elif path == "/stop": stop_alarm(); body = b"stopped\n"
        elif path in ("/ping", ""): body = b"ok\n"
        else: self.send_response(404); self.end_headers(); return
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
