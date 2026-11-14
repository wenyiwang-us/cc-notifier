"""Test fixtures shared by the test files. Nothing here reaches the real Mac or the
real kit: listeners run on spare loopback ports, kits live in temporary folders.

  Listener   the real cc_alarm_listener (its checks and routing) on a spare port;
             the alarms it would start are recorded in CALLS instead, and every
             request it receives is kept whole (request line, headers, body).
  Squatter   someone else listening on the port: answers /ping as told, 200 to
             everything else, and keeps every request it receives.
  wrap()     programs on PATH that log their command line, then run the real one.
"""
import fcntl
import http.server
import importlib.util
import json
import os
import shutil
import socketserver
import stat
import sys
import tempfile
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SENDER = os.path.join(ROOT, "src", "sender")
RECEIVER = os.path.join(ROOT, "src", "receiver")
BASH = os.environ.get("CC_TEST_BASH") or shutil.which("bash")   # CC_TEST_BASH: e.g. a bash 3.2 build, as on macOS


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


C = load("cc_client", os.path.join(SENDER, "cc_client.py"))
L = load("cc_alarm_listener", os.path.join(RECEIVER, "cc_alarm_listener.py"))

CALLS = []


def _start_proc(script, session="", **fields):
    rec = dict(act=os.path.basename(script), session=session, fields=dict(fields))
    if fields.get("CC_BODY_FILE"):
        with open(fields["CC_BODY_FILE"], encoding="utf-8") as f:
            rec["body"] = f.read()
    CALLS.append(rec)


L.start_proc = _start_proc
L.play_beep = lambda: CALLS.append(dict(act="beep"))
L.stop_alarm = lambda session=None: CALLS.append(dict(act="stop", session=session))


def private_dir(prefix):
    d = tempfile.mkdtemp(prefix=prefix)
    os.chmod(d, 0o700)
    return d


def write(path, text, mode=0o600):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


class Listener:
    def __init__(self, token=None):
        self.dir = private_dir("ccl-")
        if token is not None:
            write(os.path.join(self.dir, "token"), token + "\n")
        self.raw = []
        raw = self.raw

        class Recording(L.Handler):
            def _route(h):
                entry = {"line": h.requestline, "headers": str(h.headers), "body": b""}
                inner = h.rfile

                class Reader:
                    def read(_, n=-1):
                        data = inner.read(n)
                        entry["body"] += data
                        return data

                    def __getattr__(_, name):
                        return getattr(inner, name)
                h.rfile = Reader()
                raw.append(entry)      # before the answer goes out: the body is read before that, too
                return L.Handler._route(h)
            do_GET = _route
            do_POST = _route

        L.HERE = self.dir
        L.BODIES = os.path.join(self.dir, "tmp")
        self.server = L.V4(("127.0.0.1", 0), Recording)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        del CALLS[:]

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.dir, ignore_errors=True)


class Squatter:
    def __init__(self, ping_text):
        self.raw = []
        raw = self.raw

        class Handler(http.server.BaseHTTPRequestHandler):
            def _any(h):
                n = int(h.headers.get("Content-Length") or 0)
                raw.append({"line": h.requestline, "headers": str(h.headers), "body": h.rfile.read(n) if n else b""})
                data = ((ping_text if h.path.startswith("/ping") else "alarm") + "\n").encode()
                h.send_response(200)
                h.send_header("Content-Length", str(len(data)))
                h.end_headers()
                h.wfile.write(data)
            do_GET = _any
            do_POST = _any

            def log_message(h, *args):
                pass

        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True
        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def everything_sent(raw):
    """All the bytes a set of recorded requests carried, as text."""
    return "\n".join(e["line"] + "\n" + e["headers"] + "\n" + e["body"].decode("utf-8", "replace") for e in raw)


WRAPPER = '''#!%(python)s
import fcntl, json, os, sys
rec = {"argv": sys.argv}
if %(read_config)r and ("--config" in sys.argv or "-K" in sys.argv):
    rec["stdin"] = sys.stdin.read()
    import re
    for m in re.finditer(r'"text@([^"]+)"', rec["stdin"]):
        with open(m.group(1), encoding="utf-8") as f:
            rec["text"] = f.read()
with open(os.environ["CC_ARGV_LOG"], "a") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(json.dumps(rec) + "\\n")
real = %(real)r
if real:
    os.execv(real, [real] + sys.argv[1:])
sys.stdout.write(%(answer)r)
sys.exit(%(code)d)
'''


def wrap(bindir, name, real=None, answer="", code=0, read_config=False):
    """Put `name` on PATH (bindir first): it logs its command line to $CC_ARGV_LOG,
    then runs `real`, or prints `answer` and exits with `code`."""
    path = os.path.join(bindir, name)
    with open(path, "w") as f:
        f.write(WRAPPER % dict(python=sys.executable, real=real, answer=answer, code=code, read_config=read_config))
    os.chmod(path, 0o700)
    return path


def argv_log(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def wait_for(check, seconds=10.0):
    end = time.time() + seconds
    while time.time() < end:
        if check():
            return True
        time.sleep(0.05)
    return check()


def modes(top):
    """{path: permission bits} for top and everything under it."""
    out = {top: stat.S_IMODE(os.stat(top).st_mode)}
    for base, dirs, files in os.walk(top):
        for name in dirs + files:
            p = os.path.join(base, name)
            out[p] = stat.S_IMODE(os.lstat(p).st_mode)
    return out
