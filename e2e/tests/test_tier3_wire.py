"""Tier 3: Pairwise & Cross-Feature Combination E2E wire tests."""

from __future__ import annotations

import plistlib
import threading
import time

from e2e.lib.config import REPO_ROOT
from e2e.lib.fault_proxy import FaultProxy
from e2e.tests.conftest import WireE2ETestCase


class TestTier3Combinations(WireE2ETestCase):
    tier = 3
    feature_area = "CROSS"

    def test_T3_01_nla_rle_wave2_inputs_concurrent(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        thread_errors: list[BaseException] = []

        def _pulse() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.2)
                        resp = srv.trigger_frame()
                        if resp.status != 200:
                            raise AssertionError(f"POST /control/frame returned HTTP {resp.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_pulse, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            auth="nla",
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 320, "y": 240, "buttonMask": 1, "down": True, "wheelDelta": 0},
                {"action": "pointer", "x": 320, "y": 240, "buttonMask": 1, "down": False, "wheelDelta": 0},
                {"action": "scancode", "code": 0x1E, "extended": False, "down": True},
                {"action": "scancode", "code": 0x1E, "extended": False, "down": False},
                {"action": "drain_audio", "durationMs": 700},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])
        self.assertGreaterEqual(res.report["framesReceived"], 2)
        self.assertGreater(res.report["audioFramesRead"], 0)
        self.assertGreaterEqual(res.report["waveConfirmsSent"], 1)
        kinds = {e.get("kind") for e in srv.inputs()["events"]}
        self.assertTrue({"pointer", "scancode"}.issubset(kinds))

    def test_T3_02_tls_trust_once_wave5_unicode_mute(self) -> None:
        srv = self.start_server(auth="tls", audio_hz=440, rdpsnd_version=5)
        res = self.run_cli(
            port=srv.rdp_port,
            auth="tls",
            trust_cert="any",
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "unicode", "text": "测试"},
                {"action": "set_mute", "muted": True},
                {"action": "drain_audio", "durationMs": 300},
                {"action": "set_mute", "muted": False},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])
        self.assertGreater(res.report["audioFramesRead"], 0)

    def test_T3_03_pinned_cert_reactivation_pointer_wire(self) -> None:
        srv = self.start_server(auth="nla")
        sha = srv.health()["certSha256"].lower()
        thread_errors: list[BaseException] = []

        def _deact() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.2)
                        resp = srv.trigger_deactivate()
                        if resp.status != 200:
                            raise AssertionError(f"POST /control/deactivate returned HTTP {resp.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_deact, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            trust_cert=f"sha256:{sha}",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 600},
                {"action": "pointer", "x": 500, "y": 300, "buttonMask": 1, "down": True, "wheelDelta": 0},
                {"action": "pointer", "x": 500, "y": 300, "buttonMask": 1, "down": False, "wheelDelta": 0},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertGreaterEqual(srv.metrics()["reactivations"], 1)

    def test_T3_06_jitter_burst_frames_volume_sync_markers(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        thread_errors: list[BaseException] = []

        def _frames() -> None:
            try:
                for _ in range(4):
                    time.sleep(0.35)
                    try:
                        srv.trigger_frame()
                    except Exception:
                        return
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_frames, daemon=True)
        t.start()
        with FaultProxy(
            "127.0.0.1",
            srv.rdp_port,
            mode="jitter_stall",
            stall_after_bytes=4096,
            stall_after_secs=0.8,
            stall_duration_ms=250,
        ) as proxy:
            res = self.run_cli(
                port=proxy.port,
                audio="local",
                actions=[
                    {"action": "wait_active", "timeoutMs": 5000},
                    {"action": "set_volume", "volume": 0.6},
                    {"action": "drain_audio", "durationMs": 2200},
                    {"action": "disconnect"},
                ],
                timeout=25.0,
            )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue(proxy.fault_triggered)
        assert res.report is not None
        self.assertGreater(res.report["framesReceived"], 1)
        self.assertGreater(res.report["audioDrops"], 0)
        self.assertGreaterEqual(res.report["waveConfirmsSent"], 1)

    def test_T3_08_pinned_cert_dpum_and_immediate_reconnect(self) -> None:
        srv = self.start_server(auth="nla")
        sha = srv.health()["certSha256"].lower()
        thread_errors: list[BaseException] = []

        def _dpum() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.2)
                        resp = srv.trigger_disconnect()
                        if resp.status != 200:
                            raise AssertionError(f"POST /control/disconnect returned HTTP {resp.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_dpum, daemon=True)
        t.start()
        res1 = self.run_cli(
            port=srv.rdp_port,
            trust_cert=f"sha256:{sha}",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "drain_audio", "durationMs": 2000}],
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        r1_report = self.assert_clean_disconnect_report(res1)
        self.assertTrue(bool(r1_report["disconnectReason"]))

        res2 = self.run_cli(
            port=srv.rdp_port,
            trust_cert=f"sha256:{sha}",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res2.returncode, 0, res2.stderr)
        assert res2.report is not None
        self.assertTrue(res2.report["connected"])

    def test_T3_10_ipad_audio_session_and_scancode_compatibility(self) -> None:
        with (REPO_ROOT / "ios" / "Runner" / "Info.plist").open("rb") as fh:
            plist = plistlib.load(fh)
        self.assertIn("audio", plist.get("UIBackgroundModes", []))
        swift_files = list((REPO_ROOT / "ios" / "Runner").rglob("*.swift"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in swift_files)
        self.assertIn("AVAudioSession", combined)

    def test_T3_11_audio_off_rapid_frames_and_cursor(self) -> None:
        srv = self.start_server(auth="nla")

        def _frames() -> None:
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                if srv.metrics().get("activeSessions", 0) >= 1:
                    for _ in range(20):
                        srv.trigger_frame()
                        time.sleep(0.03)
                    return
                time.sleep(0.05)

        t = threading.Thread(target=_frames, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            audio="off",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 400, "y": 300, "buttonMask": 0, "down": False, "wheelDelta": 0},
                {"action": "drain_audio", "durationMs": 800},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=2.0)
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["audioFramesRead"], 0)
        self.assertGreaterEqual(res.report["framesReceived"], 5)

    def test_T3_14_ntlmv2_domain_fragmented_rdpsnd_reactivation(self) -> None:
        srv = self.start_server(auth="nla", user="workuser", password="workpass", domain="WORK")
        thread_errors: list[BaseException] = []

        def _deact() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.3)
                        resp = srv.trigger_deactivate()
                        if resp.status != 200:
                            raise AssertionError(f"POST /control/deactivate returned HTTP {resp.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_deact, daemon=True)
        t.start()
        with FaultProxy("127.0.0.1", srv.rdp_port, mode="fragment", chunk_size=17) as proxy:
            res = self.run_cli(
                port=proxy.port,
                auth="nla",
                user="workuser",
                password="workpass",
                domain="WORK",
                audio="local",
                actions=[
                    {"action": "wait_active", "timeoutMs": 8000},
                    {"action": "drain_audio", "durationMs": 1200},
                    {"action": "disconnect"},
                ],
                timeout=30.0,
            )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreater(res.report["audioFramesRead"], 0)
        self.assertGreaterEqual(srv.metrics()["reactivations"], 1)
