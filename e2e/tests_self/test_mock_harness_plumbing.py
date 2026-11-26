"""SELF-07: In-process mock HTTP server, mock aer-rdp-cli subprocess, and FaultProxy loopback plumbing."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import socket
import sys
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from e2e.lib.config import DEFAULT_ARTIFACTS_DIR
from e2e.lib.fault_proxy import FaultProxy
from e2e.lib.harness import find_free_port, run_aer_rdp_cli
from e2e.lib.schema import validate_cli_report


class _MockState:
    def __init__(self) -> None:
        self.frames_sent = 1
        self.reactivations = 0
        self.disconnects = 0
        self.cert_sha = "0123456789abcdef" * 4


def _make_handler(state: _MockState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            return

        def _write_json(self, code: int, payload: dict[str, Any]) -> None:
            raw = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self) -> None:
            if self.path == "/health":
                self._write_json(200, {"ok": True, "rdpPort": 3389, "certSha256": state.cert_sha})
            elif self.path == "/metrics":
                self._write_json(
                    200,
                    {
                        "framesSent": state.frames_sent,
                        "audioBlocksSent": 4,
                        "audioBlocksConfirmed": 4,
                        "lastConfirmLatencyMs": 12,
                        "inFlightWindow": 1,
                        "activeSessions": 0,
                        "reactivations": state.reactivations,
                        "lastDisconnectReason": "client_requested",
                    },
                )
            elif self.path == "/inputs":
                self._write_json(
                    200,
                    {
                        "events": [
                            {"kind": "pointer", "x": 100, "y": 200, "buttonMask": 1, "down": True, "wheelDelta": 0},
                            {"kind": "scancode", "code": 30, "extended": False, "down": True},
                            {"kind": "unicode", "text": "A"},
                        ]
                    },
                )
            else:
                self._write_json(404, {"error": "not_found"})

        def do_POST(self) -> None:
            if self.path == "/control/frame":
                state.frames_sent += 1
                self._write_json(200, {"framesSent": state.frames_sent})
            elif self.path == "/control/deactivate":
                state.reactivations += 1
                self._write_json(200, {"reactivations": state.reactivations})
            elif self.path == "/control/disconnect":
                state.disconnects += 1
                self._write_json(200, {"disconnects": state.disconnects})
            else:
                self._write_json(404, {"error": "not_found"})

    return Handler


class TestSelf07MockHarnessPlumbing(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = DEFAULT_ARTIFACTS_DIR / "tmp_self07"
        self.scratch.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        shutil.rmtree(self.scratch, ignore_errors=True)

    def test_SELF_07_mock_http_and_cli_plumbing(self) -> None:
        state = _MockState()
        http_port = find_free_port()
        httpd = ThreadingHTTPServer(("127.0.0.1", http_port), _make_handler(state))
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/health", timeout=3.0) as r:
                self.assertEqual(r.status, 200)
                health = json.loads(r.read().decode("utf-8"))
                self.assertIs(health["ok"], True)

            for ep in ("/control/frame", "/control/deactivate", "/control/disconnect"):
                req = urllib.request.Request(f"http://127.0.0.1:{http_port}{ep}", data=b"{}", method="POST")
                with urllib.request.urlopen(req, timeout=3.0) as r:
                    self.assertEqual(r.status, 200)

            with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/metrics", timeout=3.0) as r:
                metrics = json.loads(r.read().decode("utf-8"))
                self.assertEqual(metrics["framesSent"], 2)
                self.assertEqual(metrics["reactivations"], 1)
        finally:
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=2.0)

        # Build a cross-platform mock aer-rdp-cli script
        mock_py = self.scratch / "mock_cli_impl.py"
        mock_py.write_text(
            "\n".join(
                [
                    "import argparse, json, pathlib",
                    "p = argparse.ArgumentParser()",
                    "for f in ('--host','--port','--auth','--user','--pass','--domain','--width','--height','--audio','--trust-cert','--script','--out'):",
                    "    p.add_argument(f, required=True)",
                    "a = p.parse_args()",
                    "actions = json.loads(pathlib.Path(a.script).read_text(encoding='utf-8'))",
                    "assert len(actions) >= 1",
                    "report = {",
                    "  'connected': True, 'finalState': 'Disconnected',",
                    "  'certSha256': 'a'*64, 'width': int(a.width), 'height': int(a.height),",
                    "  'framesReceived': 2, 'framebufferSha256': 'b'*64,",
                    "  'audioFramesRead': 22050, 'audioQueuedMs': 60.0, 'audioDriftMs': 1.2,",
                    "  'audioDrops': 0, 'waveConfirmsSent': 4, 'disconnectReason': 'client_requested', 'errors': []",
                    "}",
                    "pathlib.Path(a.out).write_text(json.dumps(report), encoding='utf-8')",
                ]
            ),
            encoding="utf-8",
        )
        if sys.platform.startswith("win"):
            cli_wrapper = self.scratch / "mock_aer_rdp_cli.cmd"
            cli_wrapper.write_text(f'@echo off\r\n"{sys.executable}" "{mock_py}" %*\r\n', encoding="utf-8")
        else:
            cli_wrapper = self.scratch / "mock_aer_rdp_cli.sh"
            cli_wrapper.write_text(f'#!/usr/bin/env bash\nexec "{sys.executable}" "{mock_py}" "$@"\n', encoding="utf-8")
            os.chmod(cli_wrapper, 0o755)

        res = run_aer_rdp_cli(
            host="127.0.0.1",
            port=3389,
            actions=[{"action": "wait_active", "timeoutMs": 1000}, {"action": "disconnect"}],
            cli_bin=cli_wrapper,
            width=1024,
            height=768,
            timeout=10.0,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIsNotNone(res.report)
        self.assertEqual(validate_cli_report(res.report), [])

    def test_SELF_07_fault_proxy_fragment_and_corrupt_loopback(self) -> None:
        # Echo server sending a 64-byte payload back to client
        srv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv_sock.bind(("127.0.0.1", 0))
        srv_sock.listen(4)
        srv_port = srv_sock.getsockname()[1]

        def _echo() -> None:
            for _ in range(2):
                try:
                    conn, _ = srv_sock.accept()
                except OSError:
                    return
                with conn:
                    data = conn.recv(1024)
                    if data:
                        conn.sendall(b"\x03\x00\x00\x40" + data * 4)

        t = threading.Thread(target=_echo, daemon=True)
        t.start()
        try:
            with FaultProxy("127.0.0.1", srv_port, mode="fragment", chunk_size=7) as proxy:
                with socket.create_connection(("127.0.0.1", proxy.port), timeout=3.0) as cli:
                    cli.sendall(b"HELLO_RDP_PAYLOAD")
                    received = bytearray()
                    cli.settimeout(2.0)
                    while len(received) < 4 + len(b"HELLO_RDP_PAYLOAD") * 4:
                        chunk = cli.recv(1024)
                        if not chunk:
                            break
                        received.extend(chunk)
                self.assertTrue(proxy.fault_triggered)
                self.assertEqual(bytes(received[:4]), b"\x03\x00\x00\x40")

            with FaultProxy("127.0.0.1", srv_port, mode="corrupt_tpkt", corrupt_offset=0) as proxy2:
                with socket.create_connection(("127.0.0.1", proxy2.port), timeout=3.0) as cli2:
                    cli2.sendall(b"HELLO_RDP_PAYLOAD")
                    cli2.settimeout(2.0)
                    first = cli2.recv(64)
                    self.assertEqual(first[0], 0xFF)
                self.assertTrue(proxy2.fault_triggered)
        finally:
            srv_sock.close()
            t.join(timeout=2.0)

    def test_SELF_07_fault_proxy_delayed_handshake_timing(self) -> None:
        srv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv_sock.bind(("127.0.0.1", 0))
        srv_sock.listen(2)
        srv_port = srv_sock.getsockname()[1]

        def _echo() -> None:
            try:
                conn, _ = srv_sock.accept()
            except OSError:
                return
            with conn:
                data = conn.recv(1024)
                if data:
                    conn.sendall(data)

        t = threading.Thread(target=_echo, daemon=True)
        t.start()
        try:
            with FaultProxy("127.0.0.1", srv_port, mode="delayed_handshake", delay_ms=250) as proxy:
                started = time.monotonic()
                with socket.create_connection(("127.0.0.1", proxy.port), timeout=3.0) as cli:
                    cli.sendall(b"HANDSHAKE_INIT")
                    cli.settimeout(2.0)
                    reply = cli.recv(64)
                elapsed = time.monotonic() - started
                self.assertEqual(reply, b"HANDSHAKE_INIT")
                self.assertTrue(proxy.fault_triggered)
                self.assertGreaterEqual(elapsed, 0.20)
        finally:
            srv_sock.close()
            t.join(timeout=2.0)

    def test_SELF_07_fault_proxy_jitter_stall_after_secs_timing(self) -> None:
        srv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv_sock.bind(("127.0.0.1", 0))
        srv_sock.listen(2)
        srv_port = srv_sock.getsockname()[1]

        def _stream() -> None:
            try:
                conn, _ = srv_sock.accept()
            except OSError:
                return
            with conn:
                _ = conn.recv(1024)
                conn.sendall(b"CHUNK1!!")
                time.sleep(0.05)
                conn.sendall(b"CHUNK2!!")
                time.sleep(0.30)
                conn.sendall(b"CHUNK3!!")

        t = threading.Thread(target=_stream, daemon=True)
        t.start()
        try:
            with FaultProxy(
                "127.0.0.1",
                srv_port,
                mode="jitter_stall",
                stall_after_bytes=0,
                stall_after_secs=0.25,
                stall_duration_ms=250,
            ) as proxy:
                started = time.monotonic()
                with socket.create_connection(("127.0.0.1", proxy.port), timeout=5.0) as cli:
                    cli.settimeout(3.0)
                    cli.sendall(b"GO")
                    got = bytearray()
                    t_early: float | None = None
                    while len(got) < 16:
                        chunk = cli.recv(16 - len(got))
                        if not chunk:
                            break
                        got.extend(chunk)
                    t_early = time.monotonic() - started
                    self.assertEqual(bytes(got), b"CHUNK1!!CHUNK2!!")
                    self.assertLess(t_early, 0.23, "jitter_stall fired prematurely before stall_after_secs")
                    self.assertFalse(proxy.fault_triggered)

                    while len(got) < 24:
                        chunk = cli.recv(24 - len(got))
                        if not chunk:
                            break
                        got.extend(chunk)
                    t_final = time.monotonic() - started
                self.assertEqual(bytes(got), b"CHUNK1!!CHUNK2!!CHUNK3!!")
                self.assertTrue(proxy.fault_triggered)
                self.assertGreaterEqual(t_final, 0.50)
        finally:
            srv_sock.close()
            t.join(timeout=2.0)

    def test_SELF_07_fault_proxy_fragment_large_payload_fast(self) -> None:
        payload = (b"RDP_FRAME_BLOCK_" * 4096)  # 64 KiB
        expected_sha = hashlib.sha256(payload).hexdigest()
        srv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv_sock.bind(("127.0.0.1", 0))
        srv_sock.listen(2)
        srv_port = srv_sock.getsockname()[1]

        def _send_big() -> None:
            try:
                conn, _ = srv_sock.accept()
            except OSError:
                return
            with conn:
                _ = conn.recv(64)
                conn.sendall(payload)

        t = threading.Thread(target=_send_big, daemon=True)
        t.start()
        try:
            with FaultProxy("127.0.0.1", srv_port, mode="fragment", chunk_size=17) as proxy:
                started = time.monotonic()
                with socket.create_connection(("127.0.0.1", proxy.port), timeout=5.0) as cli:
                    cli.settimeout(3.0)
                    cli.sendall(b"START")
                    got = bytearray()
                    while len(got) < len(payload):
                        chunk = cli.recv(4096)
                        if not chunk:
                            break
                        got.extend(chunk)
                elapsed = time.monotonic() - started
                self.assertEqual(len(got), len(payload))
                self.assertEqual(hashlib.sha256(got).hexdigest(), expected_sha)
                self.assertTrue(proxy.fault_triggered)
                self.assertLess(elapsed, 2.0, f"Fragment mode was too slow ({elapsed:.2f}s for 64 KiB)")
        finally:
            srv_sock.close()
            t.join(timeout=2.0)

    def test_SELF_07_crashing_client_fails_T2_FA04_01(self) -> None:
        from e2e.tests.test_tier2_wire import TestTier2FA04LifecycleFaults

        mock_srv_py = self.scratch / "mock_srv_impl.py"
        mock_srv_py.write_text(
            "\n".join(
                [
                    "import argparse, json, socket, threading",
                    "from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer",
                    "p = argparse.ArgumentParser()",
                    "for f in ('--bind','--auth','--user','--pass','--domain','--audio-hz','--rdpsnd-version','--control-http'):",
                    "    p.add_argument(f, required=True)",
                    "a = p.parse_args()",
                    "rhost, rport = a.bind.rsplit(':', 1)",
                    "rs = socket.socket(socket.AF_INET, socket.SOCK_STREAM)",
                    "rs.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
                    "rs.bind((rhost, int(rport)))",
                    "rs.listen(4)",
                    "def accept_loop():",
                    "    while True:",
                    "        try:",
                    "            c, _ = rs.accept()",
                    "            threading.Thread(target=lambda s=c: (s.recv(1024), s.close()), daemon=True).start()",
                    "        except OSError:",
                    "            break",
                    "threading.Thread(target=accept_loop, daemon=True).start()",
                    "hhost, hport = a.control_http.rsplit(':', 1)",
                    "class H(BaseHTTPRequestHandler):",
                    "    def log_message(self, fmt, *args): pass",
                    "    def do_GET(self):",
                    "        body = json.dumps({'ok': True, 'rdpPort': int(rport), 'certSha256': 'a'*64}).encode()",
                    "        self.send_response(200)",
                    "        self.send_header('Content-Type', 'application/json')",
                    "        self.send_header('Content-Length', str(len(body)))",
                    "        self.end_headers()",
                    "        self.wfile.write(body)",
                    "ThreadingHTTPServer((hhost, int(hport)), H).serve_forever()",
                ]
            ),
            encoding="utf-8",
        )
        mock_crash_py = self.scratch / "mock_crash_cli.py"
        mock_crash_py.write_text(
            "\n".join(
                [
                    "import argparse, socket, sys, time",
                    "p = argparse.ArgumentParser()",
                    "for f in ('--host','--port','--auth','--user','--pass','--domain','--width','--height','--audio','--trust-cert','--script','--out'):",
                    "    p.add_argument(f, required=True)",
                    "a = p.parse_args()",
                    "with socket.create_connection((a.host, int(a.port)), timeout=3.0) as s:",
                    "    time.sleep(0.9)",
                    "sys.stderr.write('simulated SIGSEGV\\n')",
                    "sys.exit(139)",
                ]
            ),
            encoding="utf-8",
        )

        if sys.platform.startswith("win"):
            srv_wrap = self.scratch / "mock_srv.cmd"
            srv_wrap.write_text(f'@echo off\r\n"{sys.executable}" "{mock_srv_py}" %*\r\n', encoding="utf-8")
            cli_wrap = self.scratch / "mock_crash.cmd"
            cli_wrap.write_text(f'@echo off\r\n"{sys.executable}" "{mock_crash_py}" %*\r\n', encoding="utf-8")
        else:
            srv_wrap = self.scratch / "mock_srv.sh"
            srv_wrap.write_text(f'#!/usr/bin/env bash\nexec "{sys.executable}" "{mock_srv_py}" "$@"\n', encoding="utf-8")
            os.chmod(srv_wrap, 0o755)
            cli_wrap = self.scratch / "mock_crash.sh"
            cli_wrap.write_text(f'#!/usr/bin/env bash\nexec "{sys.executable}" "{mock_crash_py}" "$@"\n', encoding="utf-8")
            os.chmod(cli_wrap, 0o755)

        prev_srv = os.environ.get("AER_RDP_SERVER_BIN")
        prev_cli = os.environ.get("AER_RDP_CLI_BIN")
        os.environ["AER_RDP_SERVER_BIN"] = str(srv_wrap)
        os.environ["AER_RDP_CLI_BIN"] = str(cli_wrap)
        try:
            suite = unittest.TestSuite([TestTier2FA04LifecycleFaults("test_T2_FA04_01_sudden_tcp_rst_mid_session")])
            with open(os.devnull, "w", encoding="utf-8") as devnull:
                result = unittest.TextTestRunner(stream=devnull, verbosity=0).run(suite)
            self.assertFalse(result.wasSuccessful(), "Crashing mock client (exit 139, no report) falsely passed T2-FA04-01")
            self.assertEqual(len(result.failures), 1)
        finally:
            if prev_srv is None:
                os.environ.pop("AER_RDP_SERVER_BIN", None)
            else:
                os.environ["AER_RDP_SERVER_BIN"] = prev_srv
            if prev_cli is None:
                os.environ.pop("AER_RDP_CLI_BIN", None)
            else:
                os.environ["AER_RDP_CLI_BIN"] = prev_cli
