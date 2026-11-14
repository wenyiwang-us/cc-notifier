#!/usr/bin/env python3
"""Exercise cc_notify.sh against the real listener on a spare port; never alert the real Mac."""
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _harness as H  # noqa: E402

SCRIPT = os.path.join(H.SENDER, "cc_notify.sh")
TOKEN = "test-secret-token-0123456789"


class NotifyTests(unittest.TestCase):
    def setUp(self):
        self.listener = H.Listener(TOKEN)
        self.directory = H.private_dir("ccn-")
        H.write(os.path.join(self.directory, "token"), TOKEN + "\n")
        H.write(os.path.join(self.directory, "key-name"), "m1\n")
        self.env = dict(os.environ, CC_NOTIFIER_DIR=self.directory,
                        CC_NOTIFY_PORT=str(self.listener.port), CC_NOTIFY_TIMEOUT="1",
                        CC_NOTIFY_LOG=os.path.join(self.directory, "hook.log"),
                        CC_NOTIFY_ARM_FLAG=os.path.join(self.directory, "armed"),
                        CODEX_THREAD_ID="test-thread", http_proxy="http://127.0.0.1:1",
                        HTTP_PROXY="http://127.0.0.1:1", ALL_PROXY="http://127.0.0.1:1")
        for name in ("CLAUDECODE", "CC_NOTIFY_AGENT"):
            self.env.pop(name, None)

    def tearDown(self):
        self.listener.close()
        subprocess.run(["rm", "-rf", self.directory])

    def run_sender(self, *args, stdin=""):
        return subprocess.run([H.BASH, SCRIPT] + list(args), env=self.env, input=stdin,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

    def test_armed_metadata_auth_and_literal_message(self):
        H.write(os.path.join(self.directory, "armed"), "")
        message = "Ready: café & figures\nLiteral $(echo hello) and `pwd`."
        result = self.run_sender("--title", "Nightly sweep: 40 runs & charts", "--session", "sweep-review",
                                 "--label", "host/project", "--message", message)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HTTP 200", result.stdout)
        call = H.CALLS[-1]
        self.assertEqual(call["act"], "cc_alarm.sh")
        self.assertEqual(call["session"], "sweep-review")
        f = call["fields"]
        self.assertEqual((f["CC_LABEL"], f["CC_AGENT"], f["CC_TITLE"]), ("host/project", "Codex", "Nightly sweep: 40 runs & charts"))
        self.assertEqual(f["CC_BRIEF"], H.L._text(message, 400))
        with open(self.env["CC_NOTIFY_LOG"]) as log:
            self.assertIn("auth=signed", log.read())
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assertNotIn(TOKEN, H.everything_sent(self.listener.raw))

    def test_disarmed_and_override(self):
        self.assertEqual(self.run_sender("Ready.").returncode, 0)
        self.assertEqual(H.CALLS[-1], dict(act="beep"))
        self.assertEqual(self.run_sender("--action", "ask", "Ready.").returncode, 0)
        self.assertEqual((H.CALLS[-1]["act"], H.CALLS[-1]["session"]), ("cc_ask.sh", "test-thread"))

    def test_agent_name(self):
        self.assertEqual(self.run_sender("--action", "alarm", "--agent", "Nightly job", "Ready.").returncode, 0)
        self.assertEqual(H.CALLS[-1]["fields"]["CC_AGENT"], "Nightly job")
        for name in ("CODEX_THREAD_ID", "CLAUDECODE", "CC_NOTIFY_AGENT"):
            self.env.pop(name, None)
        self.assertEqual(self.run_sender("--action", "alarm", "Ready.").returncode, 0)        # nobody to name
        self.assertEqual(H.CALLS[-1]["fields"]["CC_AGENT"], "")
        self.env["CLAUDECODE"] = "1"
        self.assertEqual(self.run_sender("--action", "alarm", "Ready.").returncode, 0)
        self.assertEqual(H.CALLS[-1]["fields"]["CC_AGENT"], "Claude Code")

    def test_body_from_a_file_or_standard_input(self):
        result = self.run_sender("--action", "alarm", "--body-file", "-", "Ready.", stdin="line one\nline two\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(H.CALLS[-1]["body"], "line one\nline two")
        path = os.path.join(self.directory, "body.txt")
        H.write(path, "from a file")
        self.assertEqual(self.run_sender("--action", "alarm", "--body-file", path, "Ready.").returncode, 0)
        self.assertEqual(H.CALLS[-1]["body"], "from a file")

    def test_a_listener_with_another_token_gets_nothing(self):
        H.write(os.path.join(self.directory, "token"), "some-other-token-0123456789")
        result = self.run_sender("Ready.")
        self.assertEqual(result.returncode, 1)
        self.assertIn("err=unverified", result.stderr)
        self.assertIn("different keys", result.stderr)
        self.assertEqual(H.CALLS, [])

    def test_connection_failure_returns_nonzero(self):
        self.listener.close()
        result = self.run_sender("Ready.")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL", result.stderr)
        self.assertNotIn("listener accepted", result.stdout)

    def test_bad_arguments_send_nothing(self):
        for args in [(), ("--title",), ("--action", "stop", "Ready."), ("--unknown", "Ready."),
                     ("--body-file", "/nonexistent/file", "Ready.")]:
            self.assertEqual(self.run_sender(*args).returncode, 2, args)
        self.assertEqual(H.CALLS, [])


if __name__ == "__main__":
    unittest.main()
