#!/usr/bin/env python3
"""Exercise the built stdio helper against disposable Unix socket endpoints."""

import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = str(Path(sys.argv.pop(1)).resolve())


class HelperTransportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="pmcp-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.path = str(Path(self.directory.name) / "agent.sock")
        self.process = None

    def launch(self):
        self.process = subprocess.Popen(
            [HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env={**os.environ, "POINT_MCP_SOCKET": self.path},
        )
        self.addCleanup(self.stop)

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()

    def request(self, request_id):
        payload = {"jsonrpc": "2.0", "id": request_id, "method": "tools/list"}
        self.process.stdin.write(json.dumps(payload).encode() + b"\n")
        self.process.stdin.flush()
        return payload

    def response(self):
        ready, _, _ = select.select([self.process.stdout], [], [], 3)
        self.assertTrue(ready, "Helper did not reply promptly while Point was unavailable")
        return json.loads(self.process.stdout.readline())

    def listen(self):
        Path(self.path).unlink(missing_ok=True)
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        listener.bind(self.path)
        listener.listen()
        listener.settimeout(3)
        return listener

    def assert_unavailable(self, request_id):
        self.request(request_id)
        response = self.response()
        self.assertEqual(response["id"], request_id)
        self.assertEqual(response["error"]["code"], -32001)
        self.assertIsNone(self.process.poll(), "Unavailable endpoint must not terminate the helper")

    def assert_forwarded(self, connection, request_id):
        connection.settimeout(3)
        reader = connection.makefile("rb")
        self.addCleanup(reader.close)
        payload = self.request(request_id)
        self.assertEqual(json.loads(reader.readline()), payload)
        reply = {"jsonrpc": "2.0", "id": request_id, "result": {"tools": []}}
        connection.sendall(json.dumps(reply).encode() + b"\n")
        self.assertEqual(self.response(), reply)
        # Do not let the buffered reader keep the socket alive after disconnect.
        reader.close()

    def test_missing_endpoint_returns_error_and_recovers_without_restart(self):
        self.launch()
        self.assert_unavailable(1)
        listener = self.listen()
        connection, _ = listener.accept()
        self.addCleanup(connection.close)
        self.assert_forwarded(connection, 2)

        connection.close()
        listener.close()
        Path(self.path).unlink()
        time.sleep(0.35)
        self.assert_unavailable(3)

        listener = self.listen()
        connection, _ = listener.accept()
        self.addCleanup(connection.close)
        self.assert_forwarded(connection, 4)

    def test_refused_endpoint_does_not_exit_or_wait_for_an_app_launch(self):
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(self.path)
        stale.close()
        self.launch()
        self.assert_unavailable(1)
        self.assert_unavailable(2)

    def test_closed_stdin_exits_cleanly_without_point(self):
        self.launch()
        self.process.stdin.close()
        self.assertEqual(self.process.wait(timeout=3), 0)


if __name__ == "__main__":
    unittest.main()
