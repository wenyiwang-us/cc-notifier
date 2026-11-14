#!/usr/bin/env python3
"""What protocol 6 promises, checked against the real code:

  - the listener carries out a request only when it is signed with the token,
    fresh, and seen for the first time; with no token it refuses everything;
  - the token never travels, and nothing secret or private reaches a command line,
    on either end (hooks, cc_notify.sh, the test tool, the stop hotkey, the tunnel
    keeper, the Telegram push, cc_token.sh);
  - a sender talks only to a listener that proves it holds the token, so whoever
    else listens on the port gets nothing, and a token is handed to a protocol-5
    listener only during the move from that version, and only the old token;
  - the installer leaves the kit private.

Never alerts the real Mac. CC_TEST_BASH=<bash> runs the shell scripts with that
shell (the Mac runs bash 3.2).
"""
import hashlib
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _harness as H  # noqa: E402

C, L = H.C, H.L
TOKEN = "a" * 8 + hashlib.sha256(b"test token").hexdigest()[8:]
OTHER = hashlib.sha256(b"another token").hexdigest()
PRIVATE = "Distinctive private summary 7f3a."


def fields(**kw):
    return [(name, kw.get(name, "")) for name, _ in C.FIELDS]


class Base(unittest.TestCase):
    def setUp(self):
        self.kit = H.private_dir("cck-")            # this machine's kit (sender side)
        C.DIR = self.kit
        self.closers = []

    def tearDown(self):
        for c in self.closers:
            c()
        shutil.rmtree(self.kit, ignore_errors=True)

    def listener(self, token=TOKEN):
        lis = H.Listener(token)
        C.PORT = lis.port
        self.closers.append(lis.close)
        return lis

    def squatter(self, text):
        sq = H.Squatter(text)
        C.PORT = sq.port
        self.closers.append(sq.close)
        return sq

    def token(self, value=TOKEN):
        H.write(os.path.join(self.kit, "token"), value + "\n")

    def legacy(self, value=TOKEN):
        H.write(os.path.join(self.kit, C.LEGACY), hashlib.sha256(value.encode()).hexdigest() + "\n")

    def post(self, port, target, headers, body=b""):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("POST", target, body=body, headers=headers)
        r = conn.getresponse()
        out = (r.status, r.read().decode())
        conn.close()
        return out


class Protocol(Base):
    def test_both_ends_compute_the_same_signature_and_proof(self):
        for key, query, body in ((b"k", "", b""), (TOKEN.encode(), "title=%C3%A9%20x&session=s", "é\n".encode())):
            self.assertEqual(C.request_sig(key, "POST", "/alarm", query, body, 1700000000, "0" * 32),
                             L.request_sig(key, "POST", "/alarm", query, body, 1700000000, "0" * 32))
            self.assertEqual(C.ping_proof(key, "f" * 32), L.ping_proof(key, "f" * 32))
        self.assertNotEqual(C.ping_proof(b"k", "f" * 32), C.request_sig(b"k", "POST", "/", "", b"", 0, "f" * 32))


class ListenerChecks(Base):
    def test_a_signed_request_is_carried_out(self):
        lis = self.listener()
        self.token()
        body = "The whole message.\nLine two, é."
        self.assertEqual(C.send("alarm", fields(session="s1", title="T", brief=PRIVATE), body.encode()),
                         (200, "ok", "signed"))
        call = H.CALLS[-1]
        self.assertEqual((call["act"], call["session"], call["fields"]["CC_TITLE"], call["fields"]["CC_BRIEF"]),
                         ("cc_alarm.sh", "s1", "T", PRIVATE))
        self.assertEqual(call["body"], body)
        self.assertEqual(C.send("stop", fields(session="s1")), (200, "ok", "signed"))
        self.assertEqual(H.CALLS[-1], dict(act="stop", session="s1"))
        self.assertEqual(C.send("stop", fields()), (200, "ok", "signed"))
        self.assertEqual(H.CALLS[-1], dict(act="stop", session=None))       # no session: every alarm
        self.assertEqual(C.send("beep", fields()), (200, "ok", "signed"))

    def test_the_token_never_travels(self):
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
        lis = self.listener()
        self.token()
        self.assertEqual(C.send("alarm", fields(session="s", title="T"), b"x")[0], 200)
        n = len(H.CALLS)
        target, heads, body = self.captured(lis)
        self.assertEqual(self.post(lis.port, target.replace("title=T", "title=U"), heads, body)[0], 403)
        self.assertEqual(self.post(lis.port, target, heads, b"y")[0], 403)
        self.assertEqual(self.post(lis.port, target.replace("/alarm", "/ask"), heads, body)[0], 403)
        self.assertEqual(len(H.CALLS), n)

    def test_an_old_or_unsigned_request_is_refused(self):
        lis = self.listener()
        t, nonce = int(time.time()) - L.WINDOW - 60, "1" * 32
        old = {"X-CC-Time": str(t), "X-CC-Nonce": nonce,
               "X-CC-Sig": C.request_sig(TOKEN.encode(), "POST", "/alarm", "", b"", t, nonce)}
        self.assertEqual(self.post(lis.port, "/alarm", old)[0], 401)
        self.assertEqual(self.post(lis.port, "/alarm", {})[0], 401)
        self.assertEqual(self.post(lis.port, "/alarm", {"X-CC-Token": TOKEN})[0], 401)   # protocol 5's way
        self.assertEqual(self.post(lis.port, "/stop", {"X-CC-Token": TOKEN})[0], 401)
        self.assertEqual(H.CALLS, [])

    def test_a_listener_without_a_token_refuses_everything(self):
        lis = self.listener(token=None)
        self.token()
        self.assertEqual(C.ping()["auth"], "none")
        self.assertEqual(C.send("alarm", fields(title="T")), (0, "listener_has_no_token", "-"))
        t, nonce = int(time.time()), "2" * 32
        signed = {"X-CC-Time": str(t), "X-CC-Nonce": nonce, "X-CC-Sig": C.request_sig(b"", "POST", "/stop", "", b"", t, nonce)}
        self.assertEqual(self.post(lis.port, "/stop", signed)[0], 403)
        self.assertEqual(H.CALLS, [])

    def test_a_listener_with_another_token_gets_only_pings(self):
        lis = self.listener(token=OTHER)
        self.token()
        self.assertEqual(C.send("alarm", fields(title="T", brief=PRIVATE), PRIVATE.encode()), (0, "unverified", "-"))
        self.assertEqual(H.CALLS, [])
        self.assertTrue(lis.raw and all(e["line"].startswith("GET /ping?c=") for e in lis.raw))
        self.assertNotIn(PRIVATE, H.everything_sent(lis.raw))

    def test_no_token_here_sends_nothing(self):
        lis = self.listener()
        self.assertEqual(C.send("alarm", fields(title="T")), (0, "no_token", "-"))
        self.assertEqual(lis.raw, [])


class SlowSenders(Base):
    """Anyone on the login node can connect; a slow or idle connection must not silence the alarms."""

    def setUp(self):
        super().setUp()
        self.saved = (L.DEADLINE, L.Handler.timeout, L._slots)
        L.DEADLINE, L.Handler.timeout = 1, 1
        self.closers.append(self.restore)

    def restore(self):
        L.DEADLINE, L.Handler.timeout, L._slots = self.saved

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

    def test_a_flood_is_capped_and_the_listener_recovers(self):
        import threading
        L._slots = threading.BoundedSemaphore(3)
        lis = self.listener()
        self.token()
        held = [self.idle(lis.port) for _ in range(3)]
        time.sleep(0.2)
        extra = self.idle(lis.port)
        self.assertTrue(self.closed_within(extra, 0.9))         # closed at once, not after the deadline
        for conn in held:
            self.assertTrue(self.closed_within(conn, 3))
        self.assertTrue(H.wait_for(lambda: C.send("beep", fields())[0] == 200, 5))


class Squatters(Base):
    def assert_got_nothing(self, sq):
        self.assertTrue(all(e["line"].startswith("GET /ping?c=") for e in sq.raw), [e["line"] for e in sq.raw])
        sent = H.everything_sent(sq.raw)
        self.assertNotIn(TOKEN, sent)
        self.assertNotIn(PRIVATE, sent)

    def test_someone_else_on_the_port_gets_nothing(self):
        self.token()
        for text in ("ok proto=6", "ok proto=6 proof=" + "0" * 64, "ok proto=7 proof=x", "ok proto=5", "ok", "hello"):
            sq = self.squatter(text)
            status, why, _ = C.send("alarm", fields(title=PRIVATE, brief=PRIVATE), PRIVATE.encode())
            self.assertEqual(status, 0, text)
            self.assert_got_nothing(sq)

    def test_the_old_way_only_with_the_old_token_and_only_until_the_listener_proves_itself(self):
        self.token()
        sq = self.squatter("ok proto=5")                        # a protocol-5 listener, or someone posing as one
        self.legacy(OTHER)                                      # the file names another token
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assert_got_nothing(sq)
        self.legacy(TOKEN)                                      # upgraded from protocol 5 with this very token
        self.assertEqual(C.send("alarm", fields(title="T")), (200, "ok", "legacy"))
        self.assertIn("X-CC-Token: " + TOKEN, sq.raw[-1]["headers"])
        lis = self.listener()                                   # the Mac updated: it proves itself
        self.assertEqual(C.send("alarm", fields(title="T")), (200, "ok", "signed"))
        self.assertFalse(os.path.exists(os.path.join(self.kit, C.LEGACY)))
        sq2 = self.squatter("ok proto=5")                       # from now on, never the old way again
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assert_got_nothing(sq2)

    def test_the_old_way_ends_after_its_time(self):
        self.token()
        self.legacy(TOKEN)
        stale = time.time() - C.LEGACY_HOURS * 3600 - 60
        os.utime(os.path.join(self.kit, C.LEGACY), (stale, stale))
        sq = self.squatter("ok proto=5")
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assert_got_nothing(sq)

    def test_a_listener_that_trickles_cannot_hold_the_client(self):
        import socket
        import threading
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
        self.token(OTHER)                                       # rotated: the file names the old token
        sq = self.squatter("ok proto=5")
        self.assertEqual(C.send("alarm", fields(title="T"))[:2], (0, "old_listener_proto5"))
        self.assertNotIn(OTHER, H.everything_sent(sq.raw))


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
                        ALL_PROXY="http://127.0.0.1:1")
        for name in ("CLAUDECODE", "CODEX_THREAD_ID", "CC_NOTIFY_AGENT"):
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
        self.assertEqual((alarm["session"], alarm["fields"]["CC_BRIEF"]), (sid, PRIVATE))
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
        self.assertIn(dict(act="stop", session=sid), H.CALLS)

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
        rc, out, err = self.run_script(os.path.join(H.SENDER, "cc_notify.sh"), "Ready.")
        self.assertEqual(rc, 1)
        self.assertIn("err=unverified", err)
        self.assertIn("different tokens", err)
        rc, out, _ = self.run_script(os.path.join(H.SENDER, "notify_healthcheck.sh"))
        self.assertIn("cannot prove it holds", out)
        rc, out, _ = self.run_script(os.path.join(H.SENDER, "cc_tunnel_test.sh"), "ping")
        self.assertEqual(rc, 1)
        self.assertIn("cannot prove it holds", out)
        self.assertEqual(H.CALLS, [])
        os.unlink(os.path.join(self.kit, "token"))
        rc, out, _ = self.run_script(os.path.join(H.SENDER, "notify_healthcheck.sh"))
        self.assertIn("no token on this machine", out)
        H.write(os.path.join(lis.dir, "token"), TOKEN)
        self.token()
        rc, out, _ = self.run_script(os.path.join(H.SENDER, "notify_healthcheck.sh"))
        self.assertNotIn("NOTE: CC round-end", out)
        self.assertNotIn("token", out)

    def mac(self):
        """A Mac kit: the receiver files and the sender files in one folder, with the token."""
        mac = H.private_dir("ccm-")
        self.closers.append(lambda: shutil.rmtree(mac, ignore_errors=True))
        for src in (H.RECEIVER, H.SENDER):
            for name in os.listdir(src):
                if os.path.isfile(os.path.join(src, name)):
                    shutil.copy(os.path.join(src, name), mac)
        H.write(os.path.join(mac, "token"), TOKEN)
        return mac

    def test_the_stop_hotkey(self):
        mac = self.mac()
        lis = self.listener()
        H.write(os.path.join(lis.dir, "token"), TOKEN)
        self.env["CC_NOTIFY_PORT"] = str(lis.port)
        self.assertEqual(self.run_script(os.path.join(mac, "cc_stop.sh"))[0], 0)
        self.assertEqual(H.CALLS[-1], dict(act="stop", session=None))
        self.assert_clean_argv(TOKEN)

    def test_the_telegram_push(self):
        mac = self.mac()
        bot, chat = "123456:ABC-def_ghi", "-100123"
        H.wrap(self.bin, "curl", answer='{"ok":true,"result":{}}', read_config=True)
        for name in ("afplay", "alerter", "terminal-notifier", "osascript", "shortcuts"):
            H.wrap(self.bin, name)
        self.env.update(CC_TELEGRAM_TOKEN=bot, CC_TELEGRAM_CHAT_ID=chat, CC_TITLE="Session T", CC_BRIEF=PRIVATE,
                        CC_ALARM_REPEATS="1", CC_ALARM_INTERVAL="0", CC_ALARM_TIMEOUT="1", CC_AGENT="Claude Code")
        # Without a message file: the short form, from _attention.sh itself. (The alarm
        # script's own exit status is not looked at by anyone; the push is what counts.)
        rc, out, err = self.run_script(os.path.join(mac, "cc_alarm.sh"))
        self.alarm_output = out + err
        tg = lambda: [r for r in H.argv_log(self.log) if os.path.basename(r["argv"][0]) == "curl"]
        self.assertTrue(H.wait_for(lambda: len(tg()) >= 1), H.argv_log(self.log))
        short = tg()[0]
        self.assertIn('url = "https://api.telegram.org/bot%s/sendMessage"' % bot, short["stdin"])
        self.assertIn(PRIVATE, short["text"])
        # With the whole message: cc_telegram.py.
        body = os.path.join(mac, "body.txt")
        H.write(body, PRIVATE + "\n\nThe whole message.")
        self.env["CC_BODY_FILE"] = body
        self.run_script(os.path.join(mac, "cc_alarm.sh"))
        self.assertTrue(H.wait_for(lambda: len(tg()) >= 2))
        whole = tg()[1]
        self.assertIn("bot%s/sendMessage" % bot, whole["stdin"])
        self.assertIn("The whole message.", whole["text"])
        self.assert_clean_argv(bot, chat)
        for rec in tg():            # the alert itself shows the summary on the Mac's screen; curl never carries it
            self.assertNotIn(PRIVATE, "\x1f".join(rec["argv"]))
            self.assertNotIn("The whole message", "\x1f".join(rec["argv"]))

    def fake_ssh(self, remote_home, squat=None):
        """ssh that runs the far end's command here, as if HOME were remote_home; -O calls are only logged."""
        script = os.path.join(self.bin, "ssh")
        with open(script, "w") as f:
            f.write('''#!%s
import fcntl, json, os, subprocess, sys
with open(os.environ["CC_ARGV_LOG"], "a") as f:
    fcntl.flock(f, fcntl.LOCK_EX); f.write(json.dumps({"argv": sys.argv}) + "\\n")
if "-O" in sys.argv:
    sys.exit(0)
env = dict(os.environ, HOME=%r)
env.pop("CC_NOTIFIER_DIR", None)
sys.exit(subprocess.call(["bash", "-c", sys.argv[-1]], env=env))
''' % (sys.executable, remote_home))
        os.chmod(script, 0o700)

    def test_the_tunnel_keeper(self):
        mac = self.mac()
        H.write(os.path.join(mac, "config"), "CC_TUNNEL_HOST=far\n")
        remote = H.private_dir("ccr-")
        self.closers.append(lambda: shutil.rmtree(remote, ignore_errors=True))
        self.fake_ssh(remote)
        self.env.pop("CC_NOTIFIER_DIR")
        lis = self.listener()                                   # the tunnel leads to this Mac's listener
        H.write(os.path.join(lis.dir, "token"), TOKEN)
        self.env["CC_NOTIFY_PORT"] = str(lis.port)
        self.env["CC_NOTIFIER_DIR"] = mac
        self.assertEqual(self.run_script(os.path.join(mac, "cc_tunnel_keep.sh"))[0], 0)
        forwards = lambda: [r for r in H.argv_log(self.log) if "forward" in r["argv"]]
        self.assertEqual(forwards(), [])                        # healthy: left alone
        sq = self.squatter("ok proto=6")                        # someone else holds the port there
        self.env["CC_NOTIFY_PORT"] = str(sq.port)
        self.run_script(os.path.join(mac, "cc_tunnel_keep.sh"))
        self.assertEqual(len(forwards()), 1)                    # not taken for our listener: renewed
        self.assert_clean_argv(TOKEN)

    def test_cc_token(self):
        tool = os.path.join(H.SENDER, "cc_token.sh")
        rc, _, err = self.run_script(tool, "set", TOKEN)
        self.assertEqual(rc, 2)
        self.assertIn("refusing", err)
        self.assertFalse(os.path.exists(os.path.join(self.kit, "token")))
        self.assertEqual(self.run_script(tool, "set", stdin=TOKEN + "\n")[0], 0)
        with open(os.path.join(self.kit, "token")) as f:
            self.assertEqual(f.read(), TOKEN)
        self.assertEqual(H.modes(self.kit)[os.path.join(self.kit, "token")], 0o600)
        self.assertNotEqual(self.run_script(tool, "set", stdin="not a token!\n")[0], 0)

        # push: the far end gets the token over ssh, on standard input
        remote = H.private_dir("ccr-")
        self.closers.append(lambda: shutil.rmtree(remote, ignore_errors=True))
        self.fake_ssh(remote)
        self.assertEqual(self.run_script(tool, "push", "far")[0], 0)
        far = os.path.join(remote, ".cc-notifier")
        with open(os.path.join(far, "token")) as f:
            self.assertEqual(f.read().strip(), TOKEN)
        self.assertEqual(H.modes(far)[far], 0o700)
        self.assertEqual(H.modes(far)[os.path.join(far, "token")], 0o600)
        self.assert_clean_argv(TOKEN)

    def test_rotate(self):
        mac = self.mac()
        tool = os.path.join(mac, "cc_token.sh")
        remote = H.private_dir("ccr-")
        self.closers.append(lambda: shutil.rmtree(remote, ignore_errors=True))
        far = os.path.join(remote, ".cc-notifier")
        os.mkdir(far, 0o700)
        H.write(os.path.join(far, "token"), TOKEN)
        self.fake_ssh(remote)
        self.env["CC_NOTIFIER_DIR"] = mac
        # No listener here that takes signed requests: refuse, change nothing.
        self.env["CC_NOTIFY_PORT"] = "9"
        rc, _, err = self.run_script(tool, "rotate", "far")
        self.assertEqual(rc, 1)
        self.assertIn("does not take signed requests", err)
        lis = self.listener()
        L.HERE = mac                                            # the listener reads the Mac kit's token
        self.env["CC_NOTIFY_PORT"] = str(lis.port)
        # The far end has an old sender: refuse, change nothing.
        rc, _, err = self.run_script(tool, "rotate", "far")
        self.assertEqual(rc, 1)
        self.assertIn("no protocol-6 sender", err)
        shutil.copy(os.path.join(H.SENDER, "cc_client.py"), far)
        rc, _, err = self.run_script(tool, "rotate", "far")
        self.assertEqual(rc, 0, err)
        with open(os.path.join(mac, "token")) as f:
            new = f.read().strip()
        self.assertNotEqual(new, TOKEN)
        self.assertRegex(new, r"\A[0-9a-f]{64}\Z")
        with open(os.path.join(far, "token")) as f:
            self.assertEqual(f.read().strip(), new)
        self.assertIn("far: the listener proves itself", err)
        self.assert_clean_argv(TOKEN, new)


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

    def test_fresh_and_upgraded_installs(self):
        home = H.private_dir("cch-")
        self.closers.append(lambda: shutil.rmtree(home, ignore_errors=True))
        kit = os.path.join(home, ".cc-notifier")
        out = self.install("sender", home)
        self.assertIn("no token here yet", out)
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

    def test_receiver_makes_a_token_and_keeps_the_config_private(self):
        home = H.private_dir("cch-")
        self.closers.append(lambda: shutil.rmtree(home, ignore_errors=True))
        kit = os.path.join(home, ".cc-notifier")
        out = self.install("receiver", home)
        with open(os.path.join(kit, "token")) as f:
            self.assertRegex(f.read().strip(), r"\A[0-9a-f]{64}\Z")
        self.assertTrue(os.path.exists(os.path.join(kit, "config")))
        self.assertIn("cc_token.sh push", out)
        self.assertNotIn("rotate", out)
        self.assert_private(kit)
        # An old Mac kit: told to rotate.
        os.unlink(os.path.join(kit, "cc_client.py"))
        os.chmod(os.path.join(kit, "config"), 0o644)
        out = self.install("receiver", home)
        self.assertIn("cc_token.sh rotate", out)
        self.assert_private(kit)


if __name__ == "__main__":
    unittest.main(verbosity=1)
