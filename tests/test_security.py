#!/usr/bin/env python3
"""What protocols 6 and 7 promise, checked against the real code:

  - the listener carries out a request only when it is signed with the key of the
    machine it names, on that machine's own port, fresh, seen for the first time,
    and within the key's rate limit; one machine cannot pass as another, and a
    connection relayed through another machine's tunnel gets nothing;
  - a key never travels, and nothing secret or private reaches a command line, on
    either end (hooks, cc_notify.sh, the test tool, the stop hotkey, the tunnel
    keeper, the Telegram push, cc_token.sh);
  - a sender talks only to a listener that proves it holds its key, so whoever
    else listens on the port gets nothing; the shared key of protocol 6 works only
    on the Mac's own port and until it is retired, and a protocol-5 listener gets
    the old token only during the move from that version;
  - each machine's alarms are its own; web pages, floods on one tunnel and log
    lines cannot reach further than they should;
  - cc_token.sh gives each machine its key and port, rotates or revokes one without
    touching the others, and leaves a machine as it was when a step fails; the
    tunnel keeper changes a forward only when that is clearly right;
  - the installer leaves the kit private and moves the Mac to keys per machine.

Never alerts the real Mac. CC_TEST_BASH=<bash> runs the shell scripts with that
shell (the Mac runs bash 3.2).
"""
import hashlib
import http.client
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _harness as H  # noqa: E402

C, L = H.C, H.L
TOKEN = "a" * 8 + hashlib.sha256(b"test token").hexdigest()[8:]
OTHER = hashlib.sha256(b"another token").hexdigest()
SHARED = hashlib.sha256(b"the shared token").hexdigest()
PRIVATE = "Distinctive private summary 7f3a."
NAME = "m1"


def fields(**kw):
    return [(name, kw.get(name, "")) for name, _ in C.FIELDS]


def read(path):
    with open(path) as f:
        return f.read().strip()


class Base(unittest.TestCase):
    def setUp(self):
        self.kit = H.private_dir("cck-")            # this machine's kit (sender side)
        C.DIR = self.kit
        L._buckets.clear()                          # each test starts within every key's rate limit
        self.closers = []

    def tearDown(self):
        for c in self.closers:
            c()
        shutil.rmtree(self.kit, ignore_errors=True)

    def listener(self, token=TOKEN, name=NAME, shared=None, keys=None, spare=4):
        lis = H.Listener(token, name=name, shared=shared, keys=keys, spare=spare)
        C.PORT = lis.port
        self.closers.append(lis.close)
        return lis

    def squatter(self, text):
        sq = H.Squatter(text)
        C.PORT = sq.port
        self.closers.append(sq.close)
        return sq

    def token(self, value=TOKEN, name=NAME):
        """This machine's key; name None = the shared key of protocol 6 (no key-name)."""
        H.write(os.path.join(self.kit, "token"), value + "\n")
        path = os.path.join(self.kit, "key-name")
        if name is None:
            if os.path.exists(path):
                os.unlink(path)
        else:
            H.write(path, name + "\n")

    def legacy(self, value=TOKEN):
        H.write(os.path.join(self.kit, C.LEGACY), hashlib.sha256(value.encode()).hexdigest() + "\n")

    def post(self, port, target, headers, body=b"", method="POST"):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request(method, target, body=body, headers=headers)
        r = conn.getresponse()
        out = (r.status, r.read().decode())
        conn.close()
        return out

    def signed(self, key, path, name="", query="", body=b"", t=None):
        t, nonce = int(time.time()) if t is None else t, os.urandom(16).hex()
        h = {"X-CC-Time": str(t), "X-CC-Nonce": nonce,
             "X-CC-Sig": C.request_sig(key.encode(), "POST", path, query, body, t, nonce, name)}
        if name:
            h["X-CC-Key"] = name
        return h


class Protocol(Base):
    def test_both_ends_compute_the_same_signature_and_proof(self):
        for name in ("", "aurora"):
            for key, query, body in ((b"k", "", b""), (TOKEN.encode(), "title=%C3%A9%20x&session=s", "é\n".encode())):
                self.assertEqual(C.request_sig(key, "POST", "/alarm", query, body, 1700000000, "0" * 32, name),
                                 L.request_sig(key, "POST", "/alarm", query, body, 1700000000, "0" * 32, name))
                self.assertEqual(C.ping_proof(key, "f" * 32, name), L.ping_proof(key, "f" * 32, name))
        sig = lambda name: C.request_sig(b"k", "POST", "/", "", b"", 0, "f" * 32, name)
        self.assertEqual(len({sig(""), sig("a"), sig("b")}), 3)     # the name is part of what is signed
        self.assertNotEqual(C.ping_proof(b"k", "f" * 32, "a"), sig("a"))
        self.assertNotEqual(C.ping_proof(b"k", "f" * 32), C.ping_proof(b"k", "f" * 32, "a"))

    def test_both_ends_take_the_same_names(self):
        for name in ("aurora", "polaris-1", "x1000c0s0", "uan.12", "a"):
            self.assertTrue(C.valid_name(name) and L.valid_name(name), name)
        for name in ("Aurora", "Local", "Shared", "shared", "a.new", "a.port", "a.tmp.1", "a..b", ".a", "-a",
                     "a/b", "a b", "", "x" * 65, TOKEN, "0123456789abcdef01234567"):
            self.assertFalse(C.valid_name(name) or L.valid_name(name), name)


class ListenerChecks(Base):
    def test_a_signed_request_is_carried_out(self):
        lis = self.listener()
        self.token()
        body = "The whole message.\nLine two, é."
        self.assertEqual(C.send("alarm", fields(session="s1", title="T", brief=PRIVATE), body.encode()),
                         (200, "ok", "signed"))
        call = H.CALLS[-1]
        self.assertEqual((call["act"], call["owner"], call["session"], call["fields"]["CC_TITLE"], call["fields"]["CC_BRIEF"]),
                         ("cc_alarm.sh", NAME, "s1", "T", PRIVATE))
        self.assertEqual((call["body"], call["fields"]["CC_KEY"]), (body, NAME))
        self.assertEqual(C.send("stop", fields(session="s1")), (200, "ok", "signed"))
        self.assertEqual(H.CALLS[-1], dict(act="stop", owner=NAME, session="s1"))
        self.assertEqual(C.send("stop", fields()), (200, "ok", "signed"))
        self.assertEqual(H.CALLS[-1], dict(act="stop", owner=NAME, session=None))
        self.assertEqual(C.send("beep", fields()), (200, "ok", "signed"))
        self.assertIn("X-CC-Key: " + NAME, lis.raw[-1]["headers"])

    def test_the_key_never_travels(self):
        lis = self.listener()
        self.token()
        for act in ("alarm", "ask", "beep", "stop"):
            self.assertEqual(C.send(act, fields(session="s", brief="b"), b"text")[0], 200)
        self.assertGreaterEqual(len(lis.raw), 8)                 # a ping before each request
        self.assertNotIn(TOKEN, H.everything_sent(lis.raw))

    def captured(self, lis):
        """The last signed request the listener received: (target, headers, body)."""
        e = lis.raw[-1]
        target = e["line"].split()[1]
        heads = dict(line.split(": ", 1) for line in e["headers"].strip().splitlines())
        keep = {k: v for k, v in heads.items() if k.startswith("X-CC-") or k == "Content-Type"}
        return target, keep, e["body"]

    def test_a_copied_request_is_refused(self):
        lis = self.listener()
        self.token()
        self.assertEqual(C.send("alarm", fields(session="s", title="T"), b"x")[0], 200)
        n = len(H.CALLS)
        target, heads, body = self.captured(lis)
        self.assertEqual(self.post(lis.port, target, heads, body), (403, "refused: replayed\n"))
        self.assertEqual(len(H.CALLS), n)

    def test_a_changed_request_is_refused(self):
        lis = self.listener(keys={"m2": OTHER})
        self.token()
        self.assertEqual(C.send("alarm", fields(session="s", title="T"), b"x")[0], 200)
        n = len(H.CALLS)
        target, heads, body = self.captured(lis)
        self.assertEqual(self.post(lis.port, target.replace("title=T", "title=U"), heads, body)[0], 403)
        self.assertEqual(self.post(lis.port, target, heads, b"y")[0], 403)
        self.assertEqual(self.post(lis.port, target.replace("/alarm", "/ask"), heads, body)[0], 403)
        for other in ("m2", "nobody"):                            # passed off under another machine's name
            self.assertEqual(self.post(lis.port, target, dict(heads, **{"X-CC-Key": other}), body)[0], 403)
            self.assertEqual(self.post(lis.port_for("m2"), target, dict(heads, **{"X-CC-Key": other}), body)[0], 403)
        no_name = {k: v for k, v in heads.items() if k != "X-CC-Key"}
        self.assertEqual(self.post(lis.port, target, no_name, body)[0], 403)
        self.assertEqual(len(H.CALLS), n)

    def test_one_machine_cannot_pass_as_another(self):
        lis = self.listener(keys={"m2": OTHER})
        self.token(TOKEN, name="m2")                             # m1's key, m2's name
        C.PORT = lis.port_for("m2")
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "unverified"))
        self.assertEqual(self.post(lis.port_for("m2"), "/alarm", self.signed(TOKEN, "/alarm", "m2"))[0], 403)
        self.assertEqual(H.CALLS, [])

    def test_a_relayed_connection_gets_nothing(self):
        lis = self.listener(keys={"m2": OTHER})
        self.token()
        C.PORT = lis.port_for("m2")                              # m1's sender lands on m2's tunnel
        self.assertEqual(C.send("alarm", fields(title=PRIVATE, brief=PRIVATE), PRIVATE.encode())[:2],
                         (0, "key_unknown_at_listener"))
        self.assertTrue(all(e["line"].startswith("GET /ping?c=") for e in lis.raw))
        self.assertNotIn(PRIVATE, H.everything_sent(lis.raw))
        self.assertEqual(self.post(lis.port_for("m2"), "/alarm", self.signed(TOKEN, "/alarm", NAME))[0], 403)
        self.assertEqual(H.CALLS, [])

    def test_the_macs_own_key_and_the_shared_key_only_on_the_macs_port(self):
        lis = self.listener(shared=SHARED, keys={"local": OTHER})
        for port, ok in ((lis.base, 200), (lis.port, 403)):
            self.assertEqual(self.post(port, "/beep", self.signed(OTHER, "/beep", "local"))[0], ok)
            self.assertEqual(self.post(port, "/beep", self.signed(SHARED, "/beep"))[0], ok)
        self.token(SHARED, name=None)                            # an unnamed sender reaching a remote's port
        self.assertEqual(C.send("beep", fields())[:2], (0, "no_key_for_this_machine"))
        self.token()
        C.PORT = lis.base                                       # a remote's key on the Mac's own port
        self.assertEqual(C.send("beep", fields())[:2], (0, "key_unknown_at_listener"))

    def test_an_old_or_unsigned_request_is_refused(self):
        lis = self.listener()
        old = self.signed(TOKEN, "/alarm", NAME, t=int(time.time()) - L.WINDOW - 60)
        self.assertEqual(self.post(lis.port, "/alarm", old)[0], 401)
        self.assertEqual(self.post(lis.port, "/alarm", {"X-CC-Key": NAME})[0], 401)
        for port in (lis.port, lis.base):
            for heads in ({}, {"X-CC-Token": TOKEN}):             # no key named (protocol 5's way, or nothing)
                self.assertEqual(self.post(port, "/alarm", heads)[0], 403)
                self.assertEqual(self.post(port, "/stop", heads)[0], 403)
        for name in ("shared", "Shared", "../keys/m1", "M1", "m1.new"):
            self.assertEqual(self.post(lis.port, "/alarm", self.signed(TOKEN, "/alarm", name))[0], 403, name)
            self.assertEqual(self.post(lis.port, "/ping?c=%s&k=%s" % ("0" * 32, name), {}, method="GET"),
                             (200, "ok proto=7 key=unknown\n"), name)
        self.assertEqual(H.CALLS, [])

    def test_two_machines_on_one_port_are_both_refused(self):
        lis = self.listener(keys={"m2": OTHER})
        self.token()
        H.write(os.path.join(lis.dir, "ports", "m2"), "%d\n" % lis.port)     # m2 claims m1's port too
        self.assertEqual(C.send("beep", fields())[:2], (0, "key_unknown_at_listener"))
        self.assertEqual(self.post(lis.port, "/beep", self.signed(OTHER, "/beep", "m2"))[0], 403)
        self.assertEqual(H.CALLS, [])

    def test_a_listener_without_keys_refuses_everything(self):
        lis = self.listener(token=None)
        self.token()
        self.assertEqual(C.ping()["key"], "unknown")
        self.assertEqual(C.send("alarm", fields(title="T")), (0, "key_unknown_at_listener", "-"))
        self.token(name=None)
        self.assertEqual(C.ping()["shared"], "none")
        self.assertEqual(C.send("alarm", fields(title="T")), (0, "no_key_for_this_machine", "-"))
        self.assertEqual(self.post(lis.base, "/stop", self.signed("", "/stop"))[0], 403)
        self.assertEqual(H.CALLS, [])

    def test_a_revoked_key_is_refused(self):
        lis = self.listener()
        self.token()
        self.assertEqual(C.send("beep", fields())[0], 200)
        os.unlink(os.path.join(lis.dir, "keys", NAME))
        self.assertEqual(C.send("beep", fields())[:2], (0, "key_unknown_at_listener"))
        self.assertEqual(self.post(lis.port, "/beep", self.signed(TOKEN, "/beep", NAME))[0], 403)
        self.assertEqual(H.CALLS, [dict(act="beep")])

    def test_the_shared_key_works_until_it_is_retired(self):
        lis = self.listener(token=None, shared=SHARED)
        self.token(SHARED, name=None)                            # a machine still on protocol 6
        self.assertEqual(C.send("alarm", fields(title="T")), (200, "ok", "shared"))
        self.assertNotIn("X-CC-Key", lis.raw[-1]["headers"])
        self.assertEqual(H.CALLS[-1]["owner"], "shared")
        os.unlink(os.path.join(lis.dir, "keys", "shared"))
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "no_key_for_this_machine"))
        self.assertEqual(len(H.CALLS), 1)

    def test_a_listener_with_another_key_gets_only_pings(self):
        lis = self.listener(token=OTHER)
        self.token()
        self.assertEqual(C.send("alarm", fields(title="T", brief=PRIVATE), PRIVATE.encode()), (0, "unverified", "-"))
        self.assertEqual(H.CALLS, [])
        self.assertTrue(lis.raw and all(e["line"].startswith("GET /ping?c=") for e in lis.raw))
        self.assertNotIn(PRIVATE, H.everything_sent(lis.raw))

    def test_no_usable_key_here_sends_nothing(self):
        lis = self.listener()
        self.assertEqual(C.send("alarm", fields(title="T")), (0, "no_token", "-"))
        H.write(os.path.join(self.kit, "token"), TOKEN)
        for bad in ("not a name!", "M1", TOKEN, "0123456789abcdef0123456789"):   # a key-like name never goes out
            H.write(os.path.join(self.kit, "key-name"), bad)
            self.assertEqual(C.send("alarm", fields(title="T")), (0, "bad_key_name", "-"), bad)
        self.assertEqual(lis.raw, [])

    def test_requests_from_a_web_page_are_refused(self):
        lis = self.listener()
        self.token()
        for heads in ({"Host": "evil.example:%d" % lis.port}, {"Origin": "http://evil.example"}):
            self.assertEqual(self.post(lis.port, "/ping?c=" + "0" * 32 + "&k=m1", heads, method="GET")[0], 403)
            self.assertEqual(self.post(lis.port, "/beep", dict(self.signed(TOKEN, "/beep", NAME), **heads))[0], 403)
        self.assertEqual(H.CALLS, [])
        self.assertEqual(C.send("beep", fields())[0], 200)

    def test_each_key_has_a_rate_limit(self):
        saved = L.RATE
        L.RATE = (3, 60.0)
        self.closers.append(lambda: setattr(L, "RATE", saved))
        lis = self.listener(keys={"m2": OTHER})
        self.token()
        self.assertEqual([C.send("beep", fields())[0] for _ in range(4)], [200, 200, 200, 429])
        self.assertEqual(self.post(lis.port_for("m2"), "/beep", self.signed(OTHER, "/beep", "m2"))[0], 200)

    def test_alarms_belong_to_their_machine(self):
        started, killed = [], []

        class Proc:
            def __init__(self, args, **kw):
                self.args = args
                started.append(self)
                self.pid = len(started)

            def poll(self):
                return None if self not in killed else 0
        saved = (L.subprocess.Popen, L._kill, dict(L._alarms))
        self.closers.append(lambda: (setattr(L.subprocess, "Popen", saved[0]), setattr(L, "_kill", saved[1]),
                                     L._alarms.clear(), L._alarms.update(saved[2])))
        L.subprocess.Popen, L._kill = Proc, killed.append
        L._alarms.clear()
        start, stop = H.REAL["start_proc"], H.REAL["stop_alarm"]
        start("a.sh", "m1", "s1")
        start("a.sh", "m2", "s1")                                # the same session id from another machine
        self.assertEqual(sorted(L._alarms), [("m1", "s1"), ("m2", "s1")])
        stop("m2")                                               # a remote stops only its own alarms
        self.assertEqual(sorted(L._alarms), [("m1", "s1")])
        start("a.sh", "m2", "s2")
        stop("m2", "s1")
        self.assertEqual(sorted(L._alarms), [("m1", "s1"), ("m2", "s2")])
        stop("local")                                            # the Mac's own stop hotkey: every alarm
        self.assertEqual(L._alarms, {})
        self.assertEqual(len(killed), 3)

    def test_log_lines_are_clean(self):
        dirty = "/\x1b[31mred\x07" + "x" * 200
        clean = L._clean(dirty)
        self.assertEqual(len(clean), 80)
        self.assertTrue(all(0x21 <= ord(c) <= 0x7e for c in clean))


class SlowSenders(Base):
    """Anyone on a login node can connect; a slow or idle connection, or a flood on
    one tunnel, must not silence the alarms of the others."""

    def setUp(self):
        super().setUp()
        self.saved = (L.DEADLINE, L.Handler.timeout, L.MAX_CONNECTIONS)
        L.DEADLINE, L.Handler.timeout = 1, 1
        self.closers.append(self.restore)

    def restore(self):
        L.DEADLINE, L.Handler.timeout, L.MAX_CONNECTIONS = self.saved

    def idle(self, port, first=b"GET /pi"):
        import socket
        c = socket.create_connection(("127.0.0.1", port), timeout=5)
        if first:
            c.sendall(first)
        return c

    def closed_within(self, conn, seconds):
        t0 = time.time()
        try:
            data = conn.recv(100)
        except OSError:
            data = b""
        finally:
            conn.close()
        return data == b"" and time.time() - t0 < seconds

    def test_a_slow_connection_is_cut_off_and_others_go_through(self):
        lis = self.listener()
        self.token()
        slow = [self.idle(lis.port), self.idle(lis.port, first=None)]
        self.assertEqual(C.send("alarm", fields(title="T")), (200, "ok", "signed"))
        for conn in slow:
            self.assertTrue(self.closed_within(conn, 3))

    def test_a_flood_on_one_tunnel_spares_the_others_and_passes(self):
        L.MAX_CONNECTIONS = 3
        lis = self.listener(keys={"m2": OTHER})
        self.token()
        held = [self.idle(lis.port_for("m2")) for _ in range(3)]  # someone floods m2's tunnel
        time.sleep(0.2)
        extra = self.idle(lis.port_for("m2"))
        self.assertTrue(self.closed_within(extra, 0.9))         # closed at once, not after the deadline
        self.assertEqual(C.send("beep", fields())[0], 200)      # m1's tunnel is not touched
        for conn in held:
            self.assertTrue(self.closed_within(conn, 3))
        self.assertEqual(self.post(lis.port_for("m2"), "/beep", self.signed(OTHER, "/beep", "m2"))[0], 200)


class Squatters(Base):
    def assert_got_nothing(self, sq):
        self.assertTrue(all(e["line"].startswith("GET /ping?c=") for e in sq.raw), [e["line"] for e in sq.raw])
        sent = H.everything_sent(sq.raw)
        self.assertNotIn(TOKEN, sent)
        self.assertNotIn(PRIVATE, sent)

    def test_someone_else_on_the_port_gets_nothing(self):
        for name in (NAME, None):
            self.token(name=name)
            for text in ("ok proto=7", "ok proto=7 proof=" + "0" * 64, "ok proto=6 proof=" + "0" * 64,
                         "ok proto=7 key=unknown", "ok proto=5", "ok", "hello"):
                sq = self.squatter(text)
                status, why, _ = C.send("alarm", fields(title=PRIVATE, brief=PRIVATE), PRIVATE.encode())
                self.assertEqual(status, 0, (name, text))
                self.assert_got_nothing(sq)

    def test_a_key_of_its_own_needs_protocol_7(self):
        self.token()
        self.squatter("ok proto=6 proof=" + "0" * 64)            # a protocol-6 listener (or someone posing as one)
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto6"))

    def test_the_old_way_only_with_the_old_token_and_only_until_the_listener_proves_itself(self):
        self.token(name=None)
        sq = self.squatter("ok proto=5")                        # a protocol-5 listener, or someone posing as one
        self.legacy(OTHER)                                      # the file names another token
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assert_got_nothing(sq)
        self.legacy(TOKEN)                                      # upgraded from protocol 5 with this very token
        self.assertEqual(C.send("alarm", fields(title="T")), (200, "ok", "legacy"))
        self.assertIn("X-CC-Token: " + TOKEN, sq.raw[-1]["headers"])
        self.listener(token=None, shared=TOKEN)                 # the Mac updated: it proves itself
        self.assertEqual(C.send("alarm", fields(title="T")), (200, "ok", "shared"))
        self.assertFalse(os.path.exists(os.path.join(self.kit, C.LEGACY)))
        sq2 = self.squatter("ok proto=5")                       # from now on, never the old way again
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assert_got_nothing(sq2)

    def test_a_named_key_never_goes_the_old_way(self):
        self.token()
        self.legacy(TOKEN)
        sq = self.squatter("ok proto=5")
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assert_got_nothing(sq)

    def test_the_old_way_ends_after_its_time(self):
        self.token(name=None)
        self.legacy(TOKEN)
        stale = time.time() - C.LEGACY_HOURS * 3600 - 60
        os.utime(os.path.join(self.kit, C.LEGACY), (stale, stale))
        sq = self.squatter("ok proto=5")
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assert_got_nothing(sq)

    def test_a_listener_that_trickles_cannot_hold_the_client(self):
        import socket
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(8)
        stop = []

        def trickle():
            while not stop:
                try:
                    conn, _ = server.accept()
                except OSError:
                    return

                def drip(c=conn):
                    try:
                        c.recv(4096)
                        c.sendall(b"HTTP/1.0 200 OK\r\n")
                        while not stop:
                            c.sendall(b"x")
                            time.sleep(0.3)
                    except OSError:
                        pass
                    finally:
                        c.close()
                threading.Thread(target=drip, daemon=True).start()
        threading.Thread(target=trickle, daemon=True).start()
        self.closers.append(lambda: (stop.append(1), server.close()))
        self.token()
        env = dict(os.environ, CC_NOTIFIER_DIR=self.kit, CC_NOTIFY_PORT=str(server.getsockname()[1]), CC_NOTIFY_TIMEOUT="2")
        for cmd, limit in ((["ping"], 6.5), (["send", "alarm"], 9.5)):
            t0 = time.time()
            p = subprocess.run([sys.executable, os.path.join(H.SENDER, "cc_client.py")] + cmd, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            self.assertLess(time.time() - t0, limit, cmd)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn(b"timed out" if cmd == ["ping"] else b"err=timeout", p.stdout)

    def test_a_new_token_never_goes_the_old_way(self):
        self.legacy(TOKEN)
        self.token(OTHER, name=None)                            # rotated: the file names the old token
        sq = self.squatter("ok proto=5")
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assertNotIn(OTHER, H.everything_sent(sq.raw))


FAKE_SSH = '''#!%s
# ssh for the tests. A host's "remote" command runs here, as if HOME were that host's
# folder (FAKE_SSH_HOMES), and its port %s leads where its forward points: the last
# -O forward made for it (kept in FAKE_SSH_STATE), else FAKE_SSH_PORTS. -O check
# succeeds; every call is logged.
import fcntl, json, os, re, subprocess, sys
with open(os.environ["CC_ARGV_LOG"], "a") as f:
    fcntl.flock(f, fcntl.LOCK_EX); f.write(json.dumps({"argv": sys.argv}) + "\\n")
args, rest, ctl, spec, i = sys.argv[1:], [], None, None, 0
while i < len(args):
    if args[i] == "-O": ctl = args[i + 1]; i += 2; continue
    if args[i] == "-R": spec = args[i + 1]; i += 2; continue
    rest.append(args[i]); i += 1
host, cmd = rest[0], " ".join(rest[1:])
homes = json.loads(os.environ.get("FAKE_SSH_HOMES") or "{}")
ports = json.loads(os.environ.get("FAKE_SSH_PORTS") or "{}")
fail = json.loads(os.environ.get("FAKE_SSH_FAIL") or "{}")
state_file = os.environ["FAKE_SSH_STATE"]
state = json.load(open(state_file)) if os.path.exists(state_file) else {}
if host not in homes:
    sys.exit(255)
if ctl:
    if ctl in ("cancel", "forward") and spec:
        target = int(spec.rsplit(":", 1)[1])
        if ctl == "forward":
            state[host] = target
        elif state.get(host, ports.get(host)) == target:
            state[host] = 0
        with open(state_file, "w") as f:
            json.dump(state, f)
    sys.exit(0)
if fail.get(host) == "stage" and "token.new" in cmd and "cat >" in cmd:
    sys.exit(1)
env = dict(os.environ, HOME=homes[host])
env.pop("CC_NOTIFIER_DIR", None)
to = state.get(host, ports.get(host))
if to is not None:
    to = to or 1                                    # a cancelled forward: nothing listens there
    cmd = cmd.replace("localhost:%%s/" %% "%s", "localhost:%%d/" %% to)
    env["CC_NOTIFY_PORT"] = str(to)
sys.exit(subprocess.call(["bash", "-c", cmd], env=env))
'''


class CommandLines(Base):
    """Run the real scripts with wrapped programs and look at every command line."""

    def setUp(self):
        super().setUp()
        self.bin = H.private_dir("ccb-")
        self.log = os.path.join(self.bin, "argv.log")
        self.closers.append(lambda: shutil.rmtree(self.bin, ignore_errors=True))
        self.env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], CC_ARGV_LOG=self.log,
                        CC_NOTIFIER_DIR=self.kit, CC_NOTIFY_LOG=os.path.join(self.kit, "hook.log"),
                        CC_NOTIFY_ARM_FLAG=os.path.join(self.kit, "armed"), CC_NOTIFY_MIN_SECONDS="0",
                        HOME=self.kit, http_proxy="http://127.0.0.1:1", HTTP_PROXY="http://127.0.0.1:1",
                        ALL_PROXY="http://127.0.0.1:1", FAKE_SSH_STATE=os.path.join(self.bin, "forwards.json"))
        for name in ("CLAUDECODE", "CODEX_THREAD_ID", "CC_NOTIFY_AGENT", "CC_REMOTE_PORT", "CC_TUNNEL_PORTS"):
            self.env.pop(name, None)
        H.wrap(self.bin, "python3", real=sys.executable)

    def run_script(self, path, *args, stdin=""):
        p = subprocess.run([H.BASH, path] + list(args), env=self.env, input=stdin.encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return p.returncode, p.stdout.decode(), p.stderr.decode()

    def assert_clean_argv(self, *secrets):
        logged = H.argv_log(self.log)
        self.assertTrue(logged, "nothing ran")
        for rec in logged:
            line = "\x1f".join(rec["argv"])
            for s in secrets:
                self.assertNotIn(s, line)
        return logged

    def hook_log(self):
        try:
            with open(self.env["CC_NOTIFY_LOG"]) as f:
                return f.read()
        except OSError:
            return ""

    def fake_ssh(self, homes, ports=None):
        script = os.path.join(self.bin, "ssh")
        with open(script, "w") as f:
            f.write(FAKE_SSH % (sys.executable, "28765", "28765"))
        os.chmod(script, 0o700)
        self.env["FAKE_SSH_HOMES"] = json.dumps(homes)
        self.env["FAKE_SSH_PORTS"] = json.dumps(ports or {})

    def ssh_calls(self, what):
        """The -O <what> calls made: [(spec, host)]."""
        out = []
        for rec in H.argv_log(self.log):
            a = rec["argv"]
            if os.path.basename(a[0]) == "ssh" and "-O" in a and a[a.index("-O") + 1] == what:
                out.append((a[a.index("-R") + 1] if "-R" in a else None, a[-1]))
        return out

    def remote(self, token=None, client=True, name=None):
        """A remote machine's home with a kit: its token (the shared key unless named) and its client."""
        home = H.private_dir("ccr-")
        self.closers.append(lambda: shutil.rmtree(home, ignore_errors=True))
        kit = os.path.join(home, ".cc-notifier")
        os.mkdir(kit, 0o700)
        if token:
            H.write(os.path.join(kit, "token"), token)
        if name:
            H.write(os.path.join(kit, "key-name"), name)
        if client:
            shutil.copy(os.path.join(H.SENDER, "cc_client.py"), kit)
        return home, kit

    def remote_ping(self, home, port):
        env = dict(os.environ, HOME=home, CC_NOTIFY_PORT=str(port))
        env.pop("CC_NOTIFIER_DIR", None)
        return subprocess.run([sys.executable, os.path.join(home, ".cc-notifier", "cc_client.py"), "ping"], env=env,
                              stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()

    def mac(self):
        """A Mac kit: the receiver files and the sender files in one folder, with its own key (local)."""
        mac = H.private_dir("ccm-")
        self.closers.append(lambda: shutil.rmtree(mac, ignore_errors=True))
        for src in (H.RECEIVER, H.SENDER):
            for name in os.listdir(src):
                if os.path.isfile(os.path.join(src, name)):
                    shutil.copy(os.path.join(src, name), mac)
        for sub in ("keys", "ports"):
            os.mkdir(os.path.join(mac, sub), 0o700)
        H.write(os.path.join(mac, "keys", "local"), TOKEN)
        H.write(os.path.join(mac, "token"), TOKEN)
        H.write(os.path.join(mac, "key-name"), "local")
        return mac

    def test_the_hooks(self):
        lis = self.listener()
        self.token()
        H.wrap(self.bin, "curl", code=7)                        # the hooks must not need curl at all
        self.env["CC_NOTIFY_PORT"] = str(lis.port)
        H.write(self.env["CC_NOTIFY_ARM_FLAG"], "")
        sid = "test-session-1"
        stop = {"session_id": sid, "hook_event_name": "Stop", "stop_hook_active": False, "cwd": self.kit,
                "last_assistant_message": PRIVATE + " The rest of the message.", "background_tasks": []}
        rc, _, _ = self.run_script(os.path.join(H.SENDER, "notify_done.sh"), stdin=json.dumps(stop))
        self.assertEqual(rc, 0)
        self.assertTrue(H.wait_for(lambda: "done sent" in self.hook_log()), self.hook_log())
        self.assertIn("http=200 err=ok auth=signed", self.hook_log())
        alarm = [c for c in H.CALLS if c["act"] == "cc_alarm.sh"][-1]
        self.assertEqual((alarm["owner"], alarm["session"], alarm["fields"]["CC_BRIEF"]), (NAME, sid, PRIVATE))
        self.assertIn("The rest of the message.", alarm["body"])

        ask = {"session_id": sid, "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
               "tool_input": {"questions": [{"question": PRIVATE + " Which one?", "header": "Pick", "multiSelect": False,
                                             "options": [{"label": "A", "description": "a"}, {"label": "B", "description": "b"}]}]}}
        self.assertEqual(self.run_script(os.path.join(H.SENDER, "notify_ask.sh"), stdin=json.dumps(ask))[0], 0)
        self.assertTrue(H.wait_for(lambda: "ask sent" in self.hook_log()), self.hook_log())
        self.assertTrue(any(c["act"] == "cc_ask.sh" for c in H.CALLS))

        prompt = {"session_id": sid, "hook_event_name": "UserPromptSubmit", "prompt": "next please"}
        self.assertEqual(self.run_script(os.path.join(H.SENDER, "notify_stop.sh"), stdin=json.dumps(prompt))[0], 0)
        self.assertTrue(H.wait_for(lambda: "prompt cancel http=200" in self.hook_log()), self.hook_log())
        self.assertIn(dict(act="stop", owner=NAME, session=sid), H.CALLS)

        logged = self.assert_clean_argv(TOKEN, PRIVATE, "The rest of the message")
        self.assertFalse([r for r in logged if os.path.basename(r["argv"][0]) == "curl"], "a hook called curl")
        self.assertNotIn(TOKEN, H.everything_sent(lis.raw))

    def test_cc_notify_and_the_test_tool(self):
        lis = self.listener()
        self.token()
        H.wrap(self.bin, "curl", code=7)
        self.env["CC_NOTIFY_PORT"] = str(lis.port)
        rc, out, err = self.run_script(os.path.join(H.SENDER, "cc_notify.sh"), "--title", "T", "--body-file", "-",
                                       "Short summary.", stdin=PRIVATE + "\nsecond line")
        self.assertEqual(rc, 0, err)
        self.assertIn("HTTP 200", out)
        self.assertEqual(H.CALLS[-1]["act"], "beep")            # disarmed
        rc, out, err = self.run_script(os.path.join(H.SENDER, "cc_notify.sh"), "--action", "alarm", "--body-file", "-",
                                       "Short summary.", stdin=PRIVATE + "\nsecond line")
        self.assertEqual(rc, 0, err)
        self.assertEqual(H.CALLS[-1]["body"], PRIVATE + "\nsecond line")
        for act in ("ping", "alarm", "stop"):
            rc, out, err = self.run_script(os.path.join(H.SENDER, "cc_tunnel_test.sh"), act)
            self.assertEqual(rc, 0, out + err)
            self.assertTrue(out.startswith("OK"), out)
        self.assert_clean_argv(TOKEN, PRIVATE)

    def test_the_failures_say_what_is_wrong(self):
        lis = self.listener(token=OTHER)
        self.token()
        self.env["CC_NOTIFY_PORT"] = str(lis.port)
        check = lambda: self.run_script(os.path.join(H.SENDER, "notify_healthcheck.sh"))[1]
        rc, out, err = self.run_script(os.path.join(H.SENDER, "cc_notify.sh"), "Ready.")
        self.assertEqual(rc, 1)
        self.assertIn("err=unverified", err)
        self.assertIn("different keys", err)
        self.assertIn("cannot prove it holds", check())
        rc, out, _ = self.run_script(os.path.join(H.SENDER, "cc_tunnel_test.sh"), "ping")
        self.assertEqual(rc, 1)
        self.assertIn("cannot prove it holds", out)
        self.assertEqual(H.CALLS, [])
        os.unlink(os.path.join(lis.dir, "keys", NAME))           # revoked, or never issued
        out = check()
        self.assertIn("has no key named m1", out)
        self.assertIn("or someone else holds port", out)
        self.assertIn("cc_token.sh push", out)
        self.token(name=None)                                    # no key of its own; the shared one not on this port
        self.assertIn("no cc-notifier key of its own", check())
        os.unlink(os.path.join(self.kit, "token"))
        self.assertIn("no key on this machine", check())
        H.write(os.path.join(lis.dir, "keys", "shared"), TOKEN)  # on the shared key: works, but told to move
        self.token(name=None)
        self.env["CC_NOTIFY_PORT"] = str(lis.base)
        self.assertIn("still uses the cc-notifier key all machines share", check())
        H.write(os.path.join(lis.dir, "keys", NAME), TOKEN)      # its own key: nothing to say
        self.token()
        self.env["CC_NOTIFY_PORT"] = str(lis.port)
        self.assertNotIn("NOTE", check())
        mac = self.mac()                                         # on the Mac itself, the fix is cc_token.sh new
        H.write(os.path.join(mac, "token"), OTHER)
        L.HERE = mac
        self.env.update(CC_NOTIFIER_DIR=mac, CC_NOTIFY_PORT=str(lis.base))
        out = self.run_script(os.path.join(mac, "notify_healthcheck.sh"))[1]
        self.assertIn("cc_token.sh new", out)
        self.assertNotIn("cc_token.sh push", out)

    def test_the_stop_hotkey(self):
        mac = self.mac()
        lis = self.listener(token=None)
        L.HERE = mac                                            # the listener reads the Mac kit's keys
        self.env["CC_NOTIFY_PORT"] = str(lis.base)
        self.assertEqual(self.run_script(os.path.join(mac, "cc_stop.sh"))[0], 0)
        self.assertEqual(H.CALLS[-1], dict(act="stop", owner="local", session=None))
        self.assert_clean_argv(TOKEN)

    def run_alarm(self, mac, **env):
        for name in ("afplay", "alerter", "terminal-notifier", "osascript", "shortcuts"):
            H.wrap(self.bin, name)
        self.env.update(CC_ALARM_REPEATS="1", CC_ALARM_INTERVAL="0", CC_ALARM_TIMEOUT="1", CC_AGENT="Claude Code", **env)
        self.run_script(os.path.join(mac, "cc_alarm.sh"))

    def test_the_telegram_push(self):
        mac = self.mac()
        bot, chat = "123456:ABC-def_ghi", "-100123"
        H.wrap(self.bin, "curl", answer='{"ok":true,"result":{}}', read_config=True)
        # Without a message file: the short form, from _attention.sh itself. (The alarm
        # script's own exit status is not looked at by anyone; the push is what counts.)
        self.run_alarm(mac, CC_TELEGRAM_TOKEN=bot, CC_TELEGRAM_CHAT_ID=chat, CC_TITLE="Session T", CC_BRIEF=PRIVATE)
        tg = lambda: [r for r in H.argv_log(self.log) if os.path.basename(r["argv"][0]) == "curl"]
        self.assertTrue(H.wait_for(lambda: len(tg()) >= 1), H.argv_log(self.log))
        short = tg()[0]
        self.assertIn('url = "https://api.telegram.org/bot%s/sendMessage"' % bot, short["stdin"])
        self.assertIn(PRIVATE, short["text"])
        # With the whole message: cc_telegram.py.
        body = os.path.join(mac, "body.txt")
        H.write(body, PRIVATE + "\n\nThe whole message.")
        self.run_alarm(mac, CC_BODY_FILE=body)
        self.assertTrue(H.wait_for(lambda: len(tg()) >= 2))
        whole = tg()[1]
        self.assertIn("bot%s/sendMessage" % bot, whole["stdin"])
        self.assertIn("The whole message.", whole["text"])
        self.assert_clean_argv(bot, chat)
        for rec in tg():            # the alert itself shows the summary on the Mac's screen; curl never carries it
            self.assertNotIn(PRIVATE, "\x1f".join(rec["argv"]))
            self.assertNotIn("The whole message", "\x1f".join(rec["argv"]))

    def test_the_banner_names_the_machine_whose_key_signed(self):
        mac = self.mac()
        self.run_alarm(mac, CC_KEY="polaris", CC_LABEL="login-1/proj")    # the label is the sender's word
        banners = [r["argv"] for r in H.argv_log(self.log) if os.path.basename(r["argv"][0]) == "alerter"]
        self.assertTrue(banners)
        message = banners[0][banners[0].index("--message") + 1]
        self.assertIn("polaris: login-1/proj", message)

    def keeper_setup(self, plan):
        """A Mac kit whose hosts' tunnels lead where `plan` says: {host: "own" | "base" | port}."""
        mac = self.mac()
        lis = self.listener(token=None, spare=len(plan))
        L.HERE = mac
        homes, ports = {}, {}
        for (h, where), port in zip(sorted(plan.items()), lis.spare):
            homes[h] = self.remote()[0]
            H.write(os.path.join(mac, "keys", h), hashlib.sha256(h.encode()).hexdigest())
            H.write(os.path.join(mac, "ports", h), "%d\n" % port)
            ports[h] = port if where == "own" else (lis.base if where == "base" else where)
        H.write(os.path.join(mac, "config"), 'CC_TUNNEL_HOST="%s"\n' % ", ".join(sorted(plan)))
        self.fake_ssh(homes, ports)
        self.env.update(CC_NOTIFIER_DIR=mac, CC_NOTIFY_PORT=str(lis.base))
        return mac, lis

    def test_the_tunnel_keeper_changes_a_forward_only_when_that_is_clearly_right(self):
        sq = H.Squatter("ok proto=7")
        self.closers.append(sq.close)
        import socket
        free = socket.socket()
        free.bind(("127.0.0.1", 0))
        closed = free.getsockname()[1]
        free.close()                                            # nothing listens there
        mac, lis = self.keeper_setup({"healthy": "own", "wrongport": "base", "squatted": sq.port, "gone": closed})
        self.assertEqual(self.run_script(os.path.join(mac, "cc_tunnel_keep.sh"))[0], 0)
        forwards = self.ssh_calls("forward")
        self.assertEqual(sorted(h for _, h in forwards), ["gone", "wrongport"])
        self.assertEqual({h for _, h in self.ssh_calls("cancel")}, {"gone", "wrongport"})   # never the squatted one
        for spec, h in forwards:
            self.assertEqual(spec, "28765:localhost:%s" % read(os.path.join(mac, "ports", h)))
        self.assert_clean_argv(TOKEN)

    def test_the_tunnel_keeper_touches_nothing_without_a_working_key_of_its_own(self):
        mac, lis = self.keeper_setup({"gone": 1, "wrongport": "base"})
        H.write(os.path.join(mac, "token"), OTHER)              # this Mac's own key is broken
        rc, out, _ = self.run_script(os.path.join(mac, "cc_tunnel_keep.sh"))
        self.assertEqual(rc, 0)
        self.assertIn("cc_token.sh new", out)
        self.assertEqual(self.ssh_calls("forward") + self.ssh_calls("cancel"), [])

    def test_cc_token_on_a_remote(self):
        tool = os.path.join(H.SENDER, "cc_token.sh")             # a sender kit: no listener here
        rc, _, err = self.run_script(tool, "set", NAME, TOKEN)
        self.assertEqual(rc, 2)
        self.assertIn("refusing", err)
        rc, _, err = self.run_script(tool, "set", TOKEN, stdin=TOKEN + "\n")   # the key typed as the name
        self.assertEqual(rc, 2)
        self.assertIn("looks like a key", err)
        self.assertFalse(os.path.exists(os.path.join(self.kit, "token")))
        self.assertEqual(self.run_script(tool, "set", stdin=TOKEN + "\n")[0], 2)          # which name?
        self.assertEqual(self.run_script(tool, "set", "M1", stdin=TOKEN + "\n")[0], 2)    # lowercase only
        self.assertEqual(self.run_script(tool, "set", NAME, stdin=TOKEN + "\n")[0], 0)
        self.assertEqual((read(os.path.join(self.kit, "token")), read(os.path.join(self.kit, "key-name"))), (TOKEN, NAME))
        modes = H.modes(self.kit)
        self.assertEqual((modes[os.path.join(self.kit, "token")], modes[os.path.join(self.kit, "key-name")]), (0o600, 0o600))
        self.assertNotEqual(self.run_script(tool, "set", NAME, stdin="not a token!\n")[0], 0)
        rc, _, err = self.run_script(tool, "push", "far")
        self.assertEqual(rc, 2)
        self.assertIn("issued on the Mac", err)
        self.assertEqual(self.run_script(tool, "off")[0], 0)
        self.assertFalse(os.path.exists(os.path.join(self.kit, "token")))

    def test_push_rotate_revoke(self):
        mac = self.mac()
        H.write(os.path.join(mac, "keys", "shared"), SHARED)      # both remotes still share one key
        lis = self.listener(token=None)
        L.HERE = mac
        homes, kits = {}, {}
        for h in ("far1", "far2"):
            homes[h], kits[h] = self.remote(SHARED)
        self.fake_ssh(homes, {h: lis.base for h in homes})        # their tunnels end at the Mac's own port
        self.env.update(CC_NOTIFIER_DIR=mac, CC_NOTIFY_PORT=str(lis.base),
                        CC_TUNNEL_PORTS=" ".join(str(p) for p in lis.spare))
        tool = os.path.join(mac, "cc_token.sh")
        self.assertIn("verified=yes as=shared", self.remote_ping(homes["far1"], lis.base))

        rc, _, err = self.run_script(tool, "push", "far1", "far2")
        self.assertEqual(rc, 0, err)
        keys = {h: read(os.path.join(mac, "keys", h)) for h in homes}
        ports = {h: int(read(os.path.join(mac, "ports", h))) for h in homes}
        self.assertEqual(sorted(ports.values()), sorted(lis.spare[:2]))
        for h in homes:
            self.assertEqual(read(os.path.join(kits[h], "token")), keys[h])
            self.assertEqual(read(os.path.join(kits[h], "key-name")), h)
            self.assertRegex(keys[h], r"\A[0-9a-f]{64}\Z")
            self.assertIn("RemoteForward 28765 localhost:%d" % ports[h], err)
            self.assertIn("%s: the listener proves itself to it" % h, err)
            self.assertIn(("28765:localhost:%d" % ports[h], h), self.ssh_calls("forward"))   # its live tunnel moved
            self.assertIn("verified=yes as=%s" % h, self.remote_ping(homes[h], ports[h]))
            self.assertIn("why=key_unknown_at_listener", self.remote_ping(homes[h], lis.base))  # not on another port
            self.assertEqual(H.modes(kits[h])[os.path.join(kits[h], "token")], 0o600)
        self.assertEqual(len({keys["far1"], keys["far2"], SHARED, TOKEN}), 4)
        self.assertTrue(os.path.exists(os.path.join(mac, "keys", "shared")))      # retired only when you say so
        self.assertIn("revoke shared", err)

        rc, _, err = self.run_script(tool, "rotate", "far2")     # one machine; the other is not touched
        self.assertEqual(rc, 0, err)
        new2 = read(os.path.join(mac, "keys", "far2"))
        self.assertNotEqual(new2, keys["far2"])
        self.assertEqual(read(os.path.join(kits["far2"], "token")), new2)
        self.assertEqual(int(read(os.path.join(mac, "ports", "far2"))), ports["far2"])
        self.assertEqual(read(os.path.join(mac, "keys", "far1")), keys["far1"])
        self.assertEqual(read(os.path.join(kits["far1"], "token")), keys["far1"])

        self.env["FAKE_SSH_FAIL"] = json.dumps({"far1": "stage"})  # a step fails: far1 stays as it was
        rc, _, err = self.run_script(tool, "rotate", "far1")
        self.env.pop("FAKE_SSH_FAIL")
        self.assertEqual(rc, 1)
        self.assertIn("nothing changed for far1", err)
        self.assertEqual(read(os.path.join(mac, "keys", "far1")), keys["far1"])
        self.assertEqual(read(os.path.join(kits["far1"], "token")), keys["far1"])
        self.assertFalse(os.path.exists(os.path.join(mac, "keys", "far1.new")))
        self.assertIn("verified=yes as=far1", self.remote_ping(homes["far1"], ports["far1"]))

        rc, _, err = self.run_script(tool, "revoke", "far2")
        self.assertEqual(rc, 0)
        self.assertIn("shared key is still taken", err)
        self.assertFalse(os.path.exists(os.path.join(mac, "keys", "far2")))
        self.assertIn("why=key_unknown_at_listener", self.remote_ping(homes["far2"], ports["far2"]))
        self.assertEqual(self.run_script(tool, "revoke", "shared")[0], 0)
        self.assertFalse(os.path.exists(os.path.join(mac, "keys", "shared")))
        self.assertIn("verified=yes as=far1", self.remote_ping(homes["far1"], ports["far1"]))
        rc, out, _ = self.run_script(tool, "keys")
        self.assertEqual(sorted(line.split()[0] for line in out.splitlines()), ["far1", "local"])
        self.assertIn("far1   port %d" % ports["far1"], out)
        self.assert_clean_argv(TOKEN, SHARED, keys["far1"], keys["far2"], new2)

    def test_keys_are_given_only_when_both_ends_are_ready(self):
        mac = self.mac()
        tool = os.path.join(mac, "cc_token.sh")
        home, kit = self.remote(SHARED, client=False)              # an old sender: no protocol-7 client
        self.env.update(CC_NOTIFIER_DIR=mac, CC_NOTIFY_PORT="9")
        self.fake_ssh({"far": home})
        rc, _, err = self.run_script(tool, "push", "far")          # no protocol-7 listener here
        self.assertEqual(rc, 1)
        self.assertIn("does not take keys of their own yet", err)
        lis = self.listener(token=None)
        L.HERE = mac
        self.env.update(CC_NOTIFY_PORT=str(lis.base), CC_TUNNEL_PORTS=" ".join(str(p) for p in lis.spare))
        self.fake_ssh({"far": home}, {"far": lis.base})
        rc, _, err = self.run_script(tool, "rotate", "far")
        self.assertEqual(rc, 1)
        self.assertIn("no sender that can use a key of its own", err)
        self.assertEqual(read(os.path.join(kit, "token")), SHARED)
        self.assertFalse(os.path.exists(os.path.join(kit, "key-name")))
        self.assertFalse(os.path.exists(os.path.join(mac, "keys", "far")))
        for bad in ("shared", "local", "-x", "user@far", "a b", "Aurora", "far.new", TOKEN):
            self.assertEqual(self.run_script(tool, "push", bad)[0], 2, bad)
        self.assertEqual(self.run_script(tool, "off")[0], 2)      # not on the Mac
        self.assertTrue(os.path.exists(os.path.join(mac, "token")))

    def test_one_home_under_two_names_is_caught(self):
        mac = self.mac()
        lis = self.listener(token=None)
        L.HERE = mac
        home, kit = self.remote(SHARED)
        self.fake_ssh({"alpha": home, "beta": home}, {"alpha": lis.base, "beta": lis.base})
        self.env.update(CC_NOTIFIER_DIR=mac, CC_NOTIFY_PORT=str(lis.base),
                        CC_TUNNEL_PORTS=" ".join(str(p) for p in lis.spare))
        tool = os.path.join(mac, "cc_token.sh")
        self.assertEqual(self.run_script(tool, "push", "alpha")[0], 0)
        rc, _, err = self.run_script(tool, "push", "beta")
        self.assertEqual(rc, 1)
        self.assertIn("already holds the key of alpha", err)
        self.assertEqual(read(os.path.join(kit, "key-name")), "alpha")
        self.assertFalse(os.path.exists(os.path.join(mac, "keys", "beta")))


class Installer(Base):
    def install(self, role, home):
        env = dict(os.environ, HOME=home)
        for name in ("CC_NOTIFIER_DIR", "CC_NOTIFIER_SETTINGS", "CODEX_HOME"):
            env.pop(name, None)
        p = subprocess.run([H.BASH, os.path.join(H.ROOT, "install.sh"), role], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stdout.decode() + p.stderr.decode())
        return p.stdout.decode()

    def assert_private(self, kit):
        for path, mode in H.modes(kit).items():
            self.assertEqual(mode & 0o077, 0, "%s is mode %o" % (path, mode))

    def home(self):
        home = H.private_dir("cch-")
        self.closers.append(lambda: shutil.rmtree(home, ignore_errors=True))
        return home, os.path.join(home, ".cc-notifier")

    def test_fresh_and_upgraded_senders(self):
        home, kit = self.home()
        out = self.install("sender", home)
        self.assertIn("no key here yet", out)
        self.assertFalse(os.path.exists(os.path.join(kit, C.LEGACY)))
        self.assert_private(kit)
        with open(os.path.join(home, ".claude", "settings.json")) as f:
            self.assertEqual(f.read().count("/.cc-notifier/"), 4)
        # Upgrade from an old kit (a token, no cc_client.py): the old token's hash is kept for the move.
        shutil.rmtree(kit)
        os.mkdir(kit)
        H.write(os.path.join(kit, "token"), TOKEN + "\n", 0o644)
        out = self.install("sender", home)
        self.assertIn("rotate", out)
        with open(os.path.join(kit, C.LEGACY)) as f:
            self.assertEqual(f.read().strip(), hashlib.sha256(TOKEN.encode()).hexdigest())
        self.assert_private(kit)
        # Installing again: nothing old about it any more.
        os.unlink(os.path.join(kit, C.LEGACY))
        self.install("sender", home)
        self.assertFalse(os.path.exists(os.path.join(kit, C.LEGACY)))

    def assert_own_key(self, kit):
        local = read(os.path.join(kit, "keys", "local"))
        self.assertRegex(local, r"\A[0-9a-f]{64}\Z")
        self.assertEqual((read(os.path.join(kit, "token")), read(os.path.join(kit, "key-name"))), (local, "local"))
        return local

    def test_receiver_keys(self):
        home, kit = self.home()
        out = self.install("receiver", home)                    # fresh: its own key, no shared one
        self.assert_own_key(kit)
        self.assertFalse(os.path.exists(os.path.join(kit, "keys", "shared")))
        self.assertTrue(os.path.isdir(os.path.join(kit, "ports")))
        self.assertTrue(os.path.exists(os.path.join(kit, "config")))
        self.assertIn("cc_token.sh push", out)
        self.assertNotIn("rotate", out)
        self.assert_private(kit)
        again = read(os.path.join(kit, "keys", "local"))
        self.install("receiver", home)                          # installing again changes no key
        self.assertEqual(read(os.path.join(kit, "keys", "local")), again)
        H.write(os.path.join(kit, "token"), OTHER)              # a broken own key is repaired
        self.install("receiver", home)
        self.assertEqual(self.assert_own_key(kit), again)
        # A protocol-6 Mac (one token shared by every machine): kept as the shared key until revoked.
        shutil.rmtree(os.path.join(kit, "keys"))
        os.unlink(os.path.join(kit, "key-name"))
        H.write(os.path.join(kit, "token"), SHARED)
        os.chmod(os.path.join(kit, "config"), 0o644)
        out = self.install("receiver", home)
        self.assertEqual(read(os.path.join(kit, "keys", "shared")), SHARED)
        self.assertNotEqual(self.assert_own_key(kit), SHARED)
        self.assertIn("a key for each remote", out)
        self.assertIn("revoke shared", out)
        self.assert_private(kit)
        # An older Mac still (protocol 5: no cc_client.py): told to rotate.
        shutil.rmtree(os.path.join(kit, "keys"))
        os.unlink(os.path.join(kit, "key-name"))
        os.unlink(os.path.join(kit, "cc_client.py"))
        H.write(os.path.join(kit, "token"), SHARED)
        out = self.install("receiver", home)
        self.assertEqual(read(os.path.join(kit, "keys", "shared")), SHARED)
        self.assertIn("cc_token.sh rotate", out)
        self.assert_private(kit)


if __name__ == "__main__":
    unittest.main(verbosity=1)
