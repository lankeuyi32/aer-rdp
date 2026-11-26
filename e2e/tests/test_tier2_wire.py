"""Tier 2: Boundary, Negative & Fault-Injection E2E wire, CLI, server, schema & static tests."""

from __future__ import annotations

import json
import plistlib
import socket
import subprocess
import threading
import time

from e2e.lib.config import REPO_ROOT
from e2e.lib.fault_proxy import FaultProxy
from e2e.lib.harness import find_free_port, probe_rdp_tls_cert_sha256
from e2e.lib.schema import validate_profiles_payload
from e2e.tests.conftest import WireE2ETestCase


class TestTier2FA01Schema(WireE2ETestCase):
    tier = 2
    feature_area = "FA01"

    def test_T2_FA01_02_reject_malformed_or_v2_json(self) -> None:
        with self.assertRaises(json.JSONDecodeError):
            json.loads("{bad")

        fixtures = self.load_fixture("profiles_invalid.json")["cases"]
        by_name = {c["name"]: c["payload"] for c in fixtures}
        errs_v2 = validate_profiles_payload(by_name["unsupported_version_2"])
        self.assertTrue(any("version" in e for e in errs_v2), errs_v2)

        errs_missing = validate_profiles_payload(by_name["missing_profiles_array"])
        self.assertTrue(any("profiles" in e for e in errs_missing), errs_missing)

    def test_T2_FA01_03_reject_invalid_enums_and_negative_port(self) -> None:
        fixtures = self.load_fixture("profiles_invalid.json")["cases"]
        for case in fixtures:
            errs = validate_profiles_payload(case["payload"])
            self.assertGreater(len(errs), 0, f"Case {case['name']} unexpectedly passed")
            substr = case["expected_error_substring"]
            self.assertTrue(any(substr in e for e in errs), f"Expected {substr!r} in {errs}")


class TestTier2FA02CertAuth(WireE2ETestCase):
    tier = 2
    feature_area = "FA02"

    def test_T2_FA02_01_cert_reject_aborts_connection(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            trust_cert="reject",
            actions=[{"action": "wait_active", "timeoutMs": 3000}, {"action": "disconnect"}],
            validate_report_schema=False,
        )
        self.assertNotEqual(res.returncode, 0)
        if res.report is not None:
            self.assertFalse(res.report.get("connected", False))
        self.assertEqual(srv.metrics()["activeSessions"], 0)

    def test_T2_FA02_02_cert_fingerprint_mismatch_blocked(self) -> None:
        srv = self.start_server(auth="nla")
        real_sha = srv.health()["certSha256"].lower()
        wrong_sha = ("0" if real_sha[0] != "0" else "1") + real_sha[1:]
        res = self.run_cli(
            port=srv.rdp_port,
            trust_cert=f"sha256:{wrong_sha}",
            actions=[{"action": "wait_active", "timeoutMs": 3000}, {"action": "disconnect"}],
            validate_report_schema=False,
        )
        self.assertNotEqual(res.returncode, 0)
        if res.report is not None:
            self.assertFalse(res.report.get("connected", False))
            self.assertGreater(len(res.report.get("errors", [])), 0)

    def test_T2_FA02_03_wrong_or_empty_nla_password_fails(self) -> None:
        srv = self.start_server(auth="nla", user="testuser", password="testpass")
        for bad_pw in ("wrongpass", ""):
            res = self.run_cli(
                port=srv.rdp_port,
                auth="nla",
                user="testuser",
                password=bad_pw,
                actions=[{"action": "wait_active", "timeoutMs": 3000}, {"action": "disconnect"}],
                validate_report_schema=False,
            )
            self.assertNotEqual(res.returncode, 0)
            if res.report is not None:
                self.assertFalse(res.report.get("connected", False))
                self.assertGreater(len(res.report.get("errors", [])), 0)


class TestTier2FA03ProtocolFaults(WireE2ETestCase):
    tier = 2
    feature_area = "FA03"

    def test_T2_FA03_01_closed_tcp_port_fails_promptly(self) -> None:
        unused_port = find_free_port()
        start = time.monotonic()
        res = self.run_cli(
            port=unused_port,
            actions=[{"action": "wait_active", "timeoutMs": 3000}],
            timeout=10.0,
            validate_report_schema=False,
        )
        elapsed = time.monotonic() - start
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(res.timed_out)
        self.assertLess(elapsed, 9.0)
        if res.report is not None:
            self.assertFalse(res.report.get("connected", False))

    def test_T2_FA03_02_nla_vs_tls_protocol_mismatch(self) -> None:
        srv = self.start_server(auth="tls")
        res = self.run_cli(
            port=srv.rdp_port,
            auth="nla",
            actions=[{"action": "wait_active", "timeoutMs": 3000}, {"action": "disconnect"}],
            validate_report_schema=False,
        )
        self.assertNotEqual(res.returncode, 0)
        if res.report is not None:
            self.assertFalse(res.report.get("connected", False))

    def test_T2_FA03_03_domain_long_pass_unicode_username(self) -> None:
        long_pass = "P@ssw0rd!" * 7 + "X"  # 64 chars
        unicode_user = "测试用户"
        srv = self.start_server(auth="nla", user=unicode_user, password=long_pass, domain="CORP")
        res = self.run_cli(
            port=srv.rdp_port,
            auth="nla",
            user=unicode_user,
            password=long_pass,
            domain="CORP",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])

    def test_T2_FA03_04_corrupt_tpkt_header_mid_handshake(self) -> None:
        srv = self.start_server(auth="nla")
        with FaultProxy("127.0.0.1", srv.rdp_port, mode="corrupt_tpkt", corrupt_offset=0) as proxy:
            res = self.run_cli(
                port=proxy.port,
                actions=[{"action": "wait_active", "timeoutMs": 4000}],
                timeout=10.0,
                validate_report_schema=False,
            )
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(res.timed_out)
        self.assertTrue(proxy.fault_triggered)

    def test_T2_FA03_05_tcp_tarpit_timeout(self) -> None:
        srv = self.start_server(auth="nla")
        with FaultProxy("127.0.0.1", srv.rdp_port, mode="tarpit") as proxy:
            res = self.run_cli(
                port=proxy.port,
                actions=[{"action": "wait_active", "timeoutMs": 2000}],
                timeout=12.0,
                validate_report_schema=False,
            )
        self.assertNotEqual(res.returncode, 0)
        self.assertFalse(res.timed_out, "Client hung instead of timing out internally")
        self.assertTrue(proxy.fault_triggered)

    def test_T2_FA03_06_session_active_when_rdpsnd_absent(self) -> None:
        srv = self.start_server(auth="nla", rdpsnd_version=0)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])
        self.assertEqual(res.report["audioFramesRead"], 0)


class TestTier2FA04LifecycleFaults(WireE2ETestCase):
    tier = 2
    feature_area = "FA04"

    def test_T2_FA04_01_sudden_tcp_rst_mid_session(self) -> None:
        srv = self.start_server(auth="nla")
        with FaultProxy("127.0.0.1", srv.rdp_port, mode="reset_after_secs", reset_after_secs=0.7) as proxy:
            res = self.run_cli(
                port=proxy.port,
                actions=[
                    {"action": "wait_active", "timeoutMs": 5000},
                    {"action": "drain_audio", "durationMs": 3000},
                ],
                timeout=12.0,
            )
        self.assertTrue(proxy.fault_triggered)
        self.assert_clean_disconnect_report(res)

    def test_T2_FA04_02_rapid_back_to_back_deactivate(self) -> None:
        srv = self.start_server(auth="nla")
        thread_errors: list[BaseException] = []

        def _double_deactivate() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.2)
                        r1 = srv.trigger_deactivate()
                        if r1.status != 200:
                            raise AssertionError(f"First /control/deactivate returned HTTP {r1.status}")
                        time.sleep(0.08)
                        r2 = srv.trigger_deactivate()
                        if r2.status != 200:
                            raise AssertionError(f"Second /control/deactivate returned HTTP {r2.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_double_deactivate, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 1200},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertGreaterEqual(srv.metrics()["reactivations"], 2)

    def test_T2_FA04_03_reactivation_capability_reset(self) -> None:
        srv = self.start_server(auth="nla")
        thread_errors: list[BaseException] = []

        def _reactivate() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.2)
                        r1 = srv.trigger_deactivate()
                        if r1.status != 200:
                            raise AssertionError(f"POST /control/deactivate returned HTTP {r1.status}")
                        time.sleep(0.3)
                        r2 = srv.trigger_frame()
                        if r2.status != 200:
                            raise AssertionError(f"POST /control/frame returned HTTP {r2.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_reactivate, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            width=1024,
            height=768,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 1200},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["width"], 1024)
        self.assertEqual(res.report["height"], 768)
        self.assertGreaterEqual(res.report["framesReceived"], 1)

    def test_T2_FA04_04_disconnect_during_delayed_handshake(self) -> None:
        srv = self.start_server(auth="nla")
        with FaultProxy("127.0.0.1", srv.rdp_port, mode="delayed_handshake", delay_ms=1200) as proxy:
            res = self.run_cli(
                port=proxy.port,
                actions=[{"action": "wait_active", "timeoutMs": 300}, {"action": "disconnect"}],
                timeout=8.0,
            )
        self.assertTrue(proxy.fault_triggered)
        self.assert_clean_disconnect_report(res)

    def test_T2_FA04_05_immediate_reconnect_after_dpum(self) -> None:
        srv = self.start_server(auth="nla")
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
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "drain_audio", "durationMs": 2500}],
            timeout=10.0,
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        r1_report = self.assert_clean_disconnect_report(res1)
        self.assertTrue(bool(r1_report["disconnectReason"]))

        res2 = self.run_cli(
            port=srv.rdp_port,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res2.returncode, 0, res2.stderr)
        assert res2.report is not None
        self.assertTrue(res2.report["connected"])
        self.assertGreaterEqual(res2.report["framesReceived"], 1)
        self.assertEqual(res2.report["errors"], [])


class TestTier2FA05GraphicsBounds(WireE2ETestCase):
    tier = 2
    feature_area = "FA05"

    def test_T2_FA05_01_dirty_rect_edge_clamping(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            width=644,
            height=484,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 643, "y": 483, "buttonMask": 1, "down": True, "wheelDelta": 0},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])
        self.assertEqual(res.report["width"], 644)
        self.assertEqual(res.report["height"], 484)

    def test_T2_FA05_02_odd_non_multiple_of_16_dimensions(self) -> None:
        srv = self.start_server(auth="nla")
        for w, h in ((853, 480), (1366, 768)):
            res = self.run_cli(
                port=srv.rdp_port,
                width=w,
                height=h,
                audio="off",
                actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            assert res.report is not None
            self.assertEqual(res.report["width"], w)
            self.assertEqual(res.report["height"], h)
            self.assertGreaterEqual(res.report["framesReceived"], 1)

    def test_T2_FA05_03_full_hd_1080p_rle_decode(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            width=1920,
            height=1080,
            audio="off",
            actions=[{"action": "wait_active", "timeoutMs": 8000}, {"action": "disconnect"}],
            timeout=25.0,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreaterEqual(res.report["framesReceived"], 1)

    def test_T2_FA05_04_rapid_30_frame_burst(self) -> None:
        srv = self.start_server(auth="nla")
        thread_errors: list[BaseException] = []

        def _burst() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        for _ in range(30):
                            resp = srv.trigger_frame()
                            if resp.status != 200:
                                raise AssertionError(f"POST /control/frame returned HTTP {resp.status}")
                            time.sleep(0.025)
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_burst, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            audio="off",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 1200},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=3.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreaterEqual(res.report["framesReceived"], 10)

    def test_T2_FA05_05_hidden_and_boundary_cursor_updates(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 0, "y": 0, "buttonMask": 0, "down": False, "wheelDelta": 0},
                {"action": "pointer", "x": 1279, "y": 719, "buttonMask": 0, "down": False, "wheelDelta": 0},
                {"action": "drain_audio", "durationMs": 300},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])


class TestTier2FA06RdpsndFaults(WireE2ETestCase):
    tier = 2
    feature_area = "FA06"

    def test_T2_FA06_01_audio_off_skips_sink_and_confirms(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="off",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 500},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["audioFramesRead"], 0)
        self.assertEqual(res.report["waveConfirmsSent"], 0)

    def test_T2_FA06_02_audio_remote_skips_local_playback(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="remote",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 500},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["audioFramesRead"], 0)
        self.assertTrue(res.report["connected"])

    def test_T2_FA06_03_svc_17byte_tcp_fragmentation(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        with FaultProxy("127.0.0.1", srv.rdp_port, mode="fragment", chunk_size=17) as proxy:
            res = self.run_cli(
                port=proxy.port,
                audio="local",
                actions=[
                    {"action": "wait_active", "timeoutMs": 8000},
                    {"action": "drain_audio", "durationMs": 800},
                    {"action": "disconnect"},
                ],
                timeout=30.0,
            )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue(proxy.fault_triggered)
        assert res.report is not None
        self.assertGreater(res.report["audioFramesRead"], 0)
        self.assertEqual(res.report["errors"], [])

    def test_T2_FA06_04_pcm_format_subset_selection(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 600},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreater(res.report["audioFramesRead"], 0)

    def test_T2_FA06_05_inflight_window_stays_bounded(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 3000},
                {"action": "disconnect"},
            ],
            timeout=25.0,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        metrics = srv.metrics()
        self.assertGreater(metrics["audioBlocksConfirmed"], 0)
        self.assertLessEqual(metrics["inFlightWindow"], 16)


class TestTier2FA07AudioFaults(WireE2ETestCase):
    tier = 2
    feature_area = "FA07"

    def test_T2_FA07_01_jitter_250ms_burst_drift_recovery(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
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
                    {"action": "drain_audio", "durationMs": 2500},
                    {"action": "disconnect"},
                ],
                timeout=25.0,
            )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue(proxy.fault_triggered)
        assert res.report is not None
        self.assertGreater(res.report["audioDrops"], 0)
        self.assertLess(abs(res.report["audioDriftMs"]), 150)

    def test_T2_FA07_02_audio_300ms_starvation_underrun(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        with FaultProxy(
            "127.0.0.1",
            srv.rdp_port,
            mode="starve",
            stall_after_bytes=4096,
            stall_after_secs=0.8,
            stall_duration_ms=300,
        ) as proxy:
            res = self.run_cli(
                port=proxy.port,
                audio="local",
                actions=[
                    {"action": "wait_active", "timeoutMs": 5000},
                    {"action": "drain_audio", "durationMs": 2000},
                    {"action": "disconnect"},
                ],
                timeout=25.0,
            )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue(proxy.fault_triggered)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])

    def test_T2_FA07_03_volume_out_of_range_clamping(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "set_volume", "volume": 0.0},
                {"action": "set_volume", "volume": 1.0},
                {"action": "set_volume", "volume": -0.5},
                {"action": "set_volume", "volume": 2.5},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])

    def test_T2_FA07_04_rapid_mute_toggle_ten_times(self) -> None:
        srv = self.start_server(auth="nla")
        actions: list[dict[str, object]] = [{"action": "wait_active", "timeoutMs": 5000}]
        for i in range(10):
            actions.append({"action": "set_mute", "muted": (i % 2 == 0)})
        actions.append({"action": "drain_audio", "durationMs": 400})
        actions.append({"action": "disconnect"})

        res = self.run_cli(port=srv.rdp_port, audio="local", actions=actions)
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])


class TestTier2FA09InputBounds(WireE2ETestCase):
    tier = 2
    feature_area = "FA09"

    def test_T2_FA09_03_unicode_emoji_surrogates_and_empty(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "unicode", "text": ""},
                {"action": "unicode", "text": "🚀👨‍👩‍👧"},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])
        uni = [e for e in srv.inputs()["events"] if e.get("kind") == "unicode"]
        self.assertGreaterEqual(len(uni), 2)

    def test_T2_FA09_05_extended_vs_non_extended_scancode_flag(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "scancode", "code": 0x1E, "extended": False, "down": True},
                {"action": "scancode", "code": 0x48, "extended": True, "down": True},
                {"action": "scancode", "code": 0x47, "extended": True, "down": True},
                {"action": "scancode", "code": 0x53, "extended": True, "down": True},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        events = [e for e in srv.inputs()["events"] if e.get("kind") == "scancode"]
        self.assertTrue(any(e.get("extended") is False for e in events))
        self.assertTrue(any(e.get("extended") is True for e in events))


class TestTier2FA10IpadStaticNegative(WireE2ETestCase):
    tier = 2
    feature_area = "FA10"

    def test_T2_FA10_04_ios_swift_audio_interruption_route_handlers(self) -> None:
        swift_files = list((REPO_ROOT / "ios" / "Runner").rglob("*.swift"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in swift_files)
        self.assertIn("interruptionNotification", combined, "Missing AVAudioSession.interruptionNotification (M4)")
        self.assertIn("routeChangeNotification", combined, "Missing AVAudioSession.routeChangeNotification (M4)")

    def test_T2_FA10_05_rdp_core_platform_isolation_and_plist_hygiene(self) -> None:
        cargo_toml = (REPO_ROOT / "crates" / "rdp-core" / "Cargo.toml").read_text(encoding="utf-8")
        self.assertNotIn("jni", cargo_toml.lower())
        self.assertNotIn("objc", cargo_toml.lower())
        for rs_file in (REPO_ROOT / "crates" / "rdp-core" / "src").rglob("*.rs"):
            text = rs_file.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"\b(android|jni|UIKit|AVAudioSession|AudioTrack|oboe)\b")

        with (REPO_ROOT / "ios" / "Runner" / "Info.plist").open("rb") as fh:
            plist = plistlib.load(fh)
        serialized = str(plist)
        self.assertNotIn("minSdk", serialized)
        self.assertNotIn("APPLICATION_ID", serialized)


class TestTier2FA11ServerNegative(WireE2ETestCase):
    tier = 2
    feature_area = "FA11"

    def test_T2_FA11_01_invalid_http_route_and_method(self) -> None:
        srv = self.start_server(auth="nla")
        r404 = srv.raw_http("GET", "/unknown")
        self.assertIn(r404.status, (404, 405))
        r405 = srv.raw_http("GET", "/control/deactivate")
        self.assertIn(r405.status, (404, 405))
        self.assertIs(srv.health().get("ok"), True)

    def test_T2_FA11_02_control_endpoints_with_zero_sessions(self) -> None:
        srv = self.start_server(auth="nla")
        r1 = srv.trigger_deactivate()
        r2 = srv.trigger_disconnect()
        self.assertIn(r1.status, (200, 409))
        self.assertIn(r2.status, (200, 409))
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_T2_FA11_03_invalid_cli_flags_and_bound_port(self) -> None:
        srv = self.start_server(auth="nla")
        bad_auth = subprocess.run(
            [str(srv.server_bin), "--auth", "bogus"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(bad_auth.returncode, 0)

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen(1)
            port = occupied.getsockname()[1]
            http_p = find_free_port()
            bound_proc = subprocess.run(
                [
                    str(srv.server_bin),
                    "--bind",
                    f"127.0.0.1:{port}",
                    "--control-http",
                    f"127.0.0.1:{http_p}",
                ],
                capture_output=True,
                text=True,
                timeout=5.0,
                check=False,
            )
            self.assertNotEqual(bound_proc.returncode, 0)

    def test_T2_FA11_04_three_mixed_sequential_sessions(self) -> None:
        srv = self.start_server(auth="nla", user="testuser", password="testpass")
        # 1. Clean disconnect
        r1 = self.run_cli(
            port=srv.rdp_port,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(r1.returncode, 0, r1.stderr)
        # 2. DPUM disconnect
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
        r2 = self.run_cli(
            port=srv.rdp_port,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "drain_audio", "durationMs": 2000}],
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assert_clean_disconnect_report(r2)
        # 3. Auth failure
        r3 = self.run_cli(
            port=srv.rdp_port,
            password="wrong",
            actions=[{"action": "wait_active", "timeoutMs": 3000}],
            validate_report_schema=False,
        )
        self.assertNotEqual(r3.returncode, 0)
        time.sleep(0.1)
        self.assertEqual(srv.metrics()["activeSessions"], 0)

    def test_T2_FA11_05_cert_sha256_invariant_matches_tls_wire(self) -> None:
        srv = self.start_server(auth="tls")
        sha_before = srv.health()["certSha256"].lower()
        wire_sha = probe_rdp_tls_cert_sha256("127.0.0.1", srv.rdp_port)
        self.assertEqual(sha_before, wire_sha)
        res = self.run_cli(
            port=srv.rdp_port,
            auth="tls",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        sha_after = srv.health()["certSha256"].lower()
        self.assertEqual(sha_before, sha_after)
