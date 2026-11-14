#!/usr/bin/env python3
"""Exercise the sender against a local HTTP server; never alert the real Mac."""
import http.server
import os
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "sender", "cc_notify.sh")


class Handler(http.server.BaseHTTPRequestHandler):
    requests = []
    status = 200

    def do_GET(self):
        Handler.requests.append((urlsplit(self.path), dict(self.headers)))
        self.send_response(Handler.status)
        self.end_headers()

    def log_message(self, *args):
        pass


class NotifyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()
        Handler.requests = []
        Handler.status = 200
        self.env = dict(os.environ, CC_NOTIFIER_DIR=self.directory.name,
                        CC_NOTIFY_PORT=str(self.server.server_port), CC_NOTIFY_TIMEOUT="1",
                        CC_NOTIFY_LOG=os.path.join(self.directory.name, "hook.log"),
                        CC_NOTIFY_ARM_FLAG=os.path.join(self.directory.name, "armed"),
                        CODEX_THREAD_ID="test-thread", http_proxy="http://127.0.0.1:1",
                        HTTP_PROXY="http://127.0.0.1:1", ALL_PROXY="http://127.0.0.1:1")

    def tearDown(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()
        self.directory.cleanup()

    def run_sender(self, *args):
        return subprocess.run(["bash", SCRIPT] + list(args), env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

    def test_armed_metadata_auth_and_literal_message(self):
        with open(os.path.join(self.directory.name, "armed"), "w"):
            pass
        with open(os.path.join(self.directory.name, "token"), "w") as f:
            f.write("test-secret-token\n")
        message = "Ready: café & figures\nLiteral $(echo hello) and `pwd`."
        result = self.run_sender("--title", "Nightly sweep: 40 runs & charts", "--session", "sweep-review",
                                 "--label", "host/project", "--message", message)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HTTP 200", result.stdout)
        path, headers = Handler.requests[-1]
        self.assertEqual(path.path, "/alarm")
        self.assertEqual(parse_qs(path.query), dict(label=["host/project"], session=["sweep-review"],
                         agent=["Codex"], title=["Nightly sweep: 40 runs & charts"], brief=[message]))
        self.assertEqual(headers.get("X-CC-Token"), "test-secret-token")
        self.assertNotIn("test-secret-token", result.stdout + result.stderr)

    def test_disarmed_and_override(self):
        self.assertEqual(self.run_sender("Ready.").returncode, 0)
        self.assertEqual(Handler.requests[-1][0].path, "/beep")
        self.assertEqual(parse_qs(Handler.requests[-1][0].query)["session"], ["test-thread"])
        self.assertEqual(self.run_sender("--action", "ask", "Ready.").returncode, 0)
        self.assertEqual(Handler.requests[-1][0].path, "/ask")

    def test_agent_name(self):
        self.assertEqual(self.run_sender("--agent", "Nightly job", "Ready.").returncode, 0)
        self.assertEqual(parse_qs(Handler.requests[-1][0].query)["agent"], ["Nightly job"])
        for name in ("CODEX_THREAD_ID", "CLAUDECODE", "CC_NOTIFY_AGENT"):
            self.env.pop(name, None)
        self.assertEqual(self.run_sender("Ready.").returncode, 0)        # nobody to name
        self.assertNotIn("agent", parse_qs(Handler.requests[-1][0].query))
        self.env["CLAUDECODE"] = "1"
        self.assertEqual(self.run_sender("Ready.").returncode, 0)
        self.assertEqual(parse_qs(Handler.requests[-1][0].query)["agent"], ["Claude Code"])

    def test_auth_failure_returns_nonzero(self):
        Handler.status = 403
        result = self.run_sender("Ready.")
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP=403", result.stderr)
        self.assertIn("Auth token mismatch", result.stderr)

    def test_connection_failure_returns_nonzero(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()
        result = self.run_sender("Ready.")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL", result.stderr)
        self.assertNotIn("listener accepted", result.stdout)

    def test_bad_arguments_send_nothing(self):
        for args in [(), ("--title",), ("--action", "stop", "Ready."), ("--unknown", "Ready.")]:
            self.assertEqual(self.run_sender(*args).returncode, 2)
        self.assertEqual(Handler.requests, [])


if __name__ == "__main__":
    unittest.main()
