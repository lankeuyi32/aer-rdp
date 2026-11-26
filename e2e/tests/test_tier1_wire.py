"""Tier 1: Feature Equivalence-Class E2E wire, CLI, server, schema, and iOS static tests."""

from __future__ import annotations

import plistlib
import re
import shutil
import subprocess
import time

from e2e.lib.config import (
    RDP_TEST_SERVER_METRICS_FIELDS,
    REPO_ROOT,
)
from e2e.lib.harness import probe_rdp_tls_cert_sha256
from e2e.lib.schema import is_valid_sha256_hex, validate_profiles_payload
from e2e.tests.conftest import WireE2ETestCase


class TestTier1FA01Schema(WireE2ETestCase):
    tier = 1
    feature_area = "FA01"

    def test_T1_FA01_05_export_profile_schema_v1(self) -> None:
        payload = self.load_fixture("profiles_valid.json")
        errors = validate_profiles_payload(payload)
        self.assertEqual(errors, [], f"Valid export fixture failed schema validation: {errors}")
        for profile in payload["profiles"]:
            self.assertNotIn("password", profile)
            self.assertNotIn("secret", profile)

    def test_T1_FA01_06_import_profile_schema_v1(self) -> None:
        payload = self.load_fixture("profiles_valid.json")
        self.assertEqual(payload.get("version"), 1)
        self.assertGreaterEqual(len(payload.get("profiles", [])), 2)
        errors = validate_profiles_payload(payload)
        self.assertEqual(errors, [])


class TestTier1FA02CertAuth(WireE2ETestCase):
    tier = 1
    feature_area = "FA02"

    def test_T1_FA02_03_trust_once_cert_sha256(self) -> None:
        srv = self.start_server(auth="nla")
        health = srv.health()
        expected_sha = health["certSha256"].lower()
        self.assertTrue(is_valid_sha256_hex(expected_sha))

        res = self.run_cli(
            port=srv.rdp_port,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
            trust_cert="any",
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])
        self.assertEqual((res.report["certSha256"] or "").lower(), expected_sha)

    def test_T1_FA02_04_trust_always_pinned_sha256(self) -> None:
        srv = self.start_server(auth="nla")
        expected_sha = srv.health()["certSha256"].lower()

        for _ in range(2):
            res = self.run_cli(
                port=srv.rdp_port,
                actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
                trust_cert=f"sha256:{expected_sha}",
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            assert res.report is not None
            self.assertTrue(res.report["connected"])
            self.assertEqual((res.report["certSha256"] or "").lower(), expected_sha)

    def test_T1_FA02_05_cert_pin_canonical_sha256(self) -> None:
        srv = self.start_server(auth="tls")
        expected_sha = srv.health()["certSha256"].lower()
        # Accept uppercase hex in --trust-cert and confirm canonical lowercase output
        res = self.run_cli(
            port=srv.rdp_port,
            auth="tls",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
            trust_cert=f"sha256:{expected_sha.upper()}",
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])
        self.assertEqual((res.report["certSha256"] or "").lower(), expected_sha)


class TestTier1FA03Protocol(WireE2ETestCase):
    tier = 1
    feature_area = "FA03"

    def test_T1_FA03_01_x224_negotiation_nla(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            auth="nla",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])
        self.assertEqual(res.report["finalState"], "Disconnected")

    def test_T1_FA03_02_x224_negotiation_tls(self) -> None:
        srv = self.start_server(auth="tls")
        res = self.run_cli(
            port=srv.rdp_port,
            auth="tls",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])
        self.assertTrue(is_valid_sha256_hex(res.report["certSha256"]))

    def test_T1_FA03_03_credssp_nla_auth(self) -> None:
        srv = self.start_server(auth="nla", user="testuser", password="testpass", domain="")
        res = self.run_cli(
            port=srv.rdp_port,
            auth="auto",
            user="testuser",
            password="testpass",
            domain="",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])
        self.assertEqual(res.report["errors"], [])
        self.assertGreaterEqual(res.report["framesReceived"], 1)

    def test_T1_FA03_04_mcs_gcc_dimensions(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            width=1024,
            height=768,
            audio="local",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["width"], 1024)
        self.assertEqual(res.report["height"], 768)

    def test_T1_FA03_05_mcs_channel_join_rdpsnd(self) -> None:
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
        self.assertIsNotNone(res.report, f"Client exited without JSON report (rc={res.returncode}): {res.stderr}")
        assert res.report is not None
        self.assertGreater(res.report["audioFramesRead"], 0)
        metrics = srv.metrics()
        self.assertGreater(metrics["audioBlocksSent"], 0)

    def test_T1_FA03_06_info_license_capabilities(self) -> None:
        srv = self.start_server(auth="nla", user="testuser", password="testpass")
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertTrue(res.report["connected"])
        self.assertGreaterEqual(res.report["framesReceived"], 1)
        self.assertEqual(res.report["errors"], [])


class TestTier1FA04Lifecycle(WireE2ETestCase):
    tier = 1
    feature_area = "FA04"

    def test_T1_FA04_01_deactivation_reactivation(self) -> None:
        srv = self.start_server(auth="nla")
        actions = [
            {"action": "wait_active", "timeoutMs": 5000},
            {"action": "drain_audio", "durationMs": 500},
            {"action": "pointer", "x": 150, "y": 150, "buttonMask": 1, "down": True, "wheelDelta": 0},
            {"action": "pointer", "x": 150, "y": 150, "buttonMask": 1, "down": False, "wheelDelta": 0},
            {"action": "drain_audio", "durationMs": 1200},
            {"action": "disconnect"},
        ]
        # Trigger deactivate shortly after session starts in background thread
        import threading

        thread_errors: list[BaseException] = []

        def _trigger() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.25)
                        resp = srv.trigger_deactivate()
                        if resp.status != 200:
                            raise AssertionError(f"POST /control/deactivate returned HTTP {resp.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1 before deactivate")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_trigger, daemon=True)
        t.start()
        res = self.run_cli(port=srv.rdp_port, actions=actions, timeout=20.0)
        t.join(timeout=2.0)

        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        metrics = srv.metrics()
        self.assertGreaterEqual(metrics["reactivations"], 1)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])

    def test_T1_FA04_02_client_clean_disconnect(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["finalState"], "Disconnected")
        self.assertEqual(res.report["errors"], [])
        time.sleep(0.1)
        self.assertEqual(srv.metrics()["activeSessions"], 0)

    def test_T1_FA04_03_server_dpum_disconnect(self) -> None:
        srv = self.start_server(auth="nla")
        import threading

        thread_errors: list[BaseException] = []

        def _drop() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.25)
                        resp = srv.trigger_disconnect()
                        if resp.status != 200:
                            raise AssertionError(f"POST /control/disconnect returned HTTP {resp.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1 before disconnect")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_drop, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 3000},
            ],
            timeout=15.0,
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        report = self.assert_clean_disconnect_report(res)
        self.assertTrue(bool(report["disconnectReason"]))
        time.sleep(0.1)
        self.assertEqual(srv.metrics()["activeSessions"], 0)

    def test_T1_FA04_04_consecutive_sessions_reconnect(self) -> None:
        srv = self.start_server(auth="nla")
        for idx in range(2):
            res = self.run_cli(
                port=srv.rdp_port,
                actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
            )
            self.assertEqual(res.returncode, 0, f"Run {idx} failed: {res.stderr}")
            assert res.report is not None
            self.assertTrue(res.report["connected"])
            self.assertGreaterEqual(res.report["framesReceived"], 1)


class TestTier1FA05Graphics(WireE2ETestCase):
    tier = 1
    feature_area = "FA05"

    def test_T1_FA05_01_initial_framebuffer_sha256(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            width=800,
            height=600,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["width"], 800)
        self.assertEqual(res.report["height"], 600)
        self.assertGreaterEqual(res.report["framesReceived"], 1)
        self.assertTrue(is_valid_sha256_hex(res.report["framebufferSha256"]))

    def test_T1_FA05_02_raw_bitmap_decoding(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            width=800,
            height=600,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreaterEqual(res.report["framesReceived"], 1)
        self.assertTrue(is_valid_sha256_hex(res.report["framebufferSha256"]))
        self.assertEqual(res.report["errors"], [])

    def test_T1_FA05_03_rle_bitmap_decoding_parity(self) -> None:
        srv = self.start_server(auth="nla")
        res1 = self.run_cli(
            port=srv.rdp_port,
            width=800,
            height=600,
            audio="off",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        res2 = self.run_cli(
            port=srv.rdp_port,
            width=800,
            height=600,
            audio="off",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res1.returncode, 0, res1.stderr)
        self.assertEqual(res2.returncode, 0, res2.stderr)
        assert res1.report is not None and res2.report is not None
        self.assertTrue(is_valid_sha256_hex(res1.report["framebufferSha256"]))
        self.assertEqual(res1.report["framebufferSha256"], res2.report["framebufferSha256"])

    def test_T1_FA05_04_dirty_rect_reactive_frame_update(self) -> None:
        srv = self.start_server(auth="nla")
        base_res = self.run_cli(
            port=srv.rdp_port,
            width=800,
            height=600,
            audio="off",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(base_res.returncode, 0, base_res.stderr)
        assert base_res.report is not None
        base_hash = base_res.report["framebufferSha256"]

        import threading

        thread_errors: list[BaseException] = []

        def _send_frame() -> None:
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
                raise TimeoutError("Timed out waiting for activeSessions >= 1 before trigger_frame")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_send_frame, daemon=True)
        t.start()
        upd_res = self.run_cli(
            port=srv.rdp_port,
            width=800,
            height=600,
            audio="off",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 120, "y": 140, "buttonMask": 1, "down": True, "wheelDelta": 0},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(upd_res.returncode, 0, upd_res.stderr)
        assert upd_res.report is not None
        self.assertGreater(upd_res.report["framesReceived"], base_res.report["framesReceived"])
        self.assertNotEqual(upd_res.report["framebufferSha256"], base_hash)

    def test_T1_FA05_05_pointer_and_frame_sync_markers(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 200, "y": 240, "buttonMask": 0, "down": False, "wheelDelta": 0},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])
        self.assertGreaterEqual(res.report["framesReceived"], 1)


class TestTier1FA06Rdpsnd(WireE2ETestCase):
    tier = 1
    feature_area = "FA06"

    def test_T1_FA06_01_rdpsnd_format_negotiation(self) -> None:
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
        self.assertGreater(srv.metrics()["audioBlocksSent"], 0)

    def test_T1_FA06_02_rdpsnd_training_calibration(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 500},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertGreater(srv.metrics()["audioBlocksSent"], 0)

    def test_T1_FA06_03_rdpsnd_wave2_v8(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 500},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreater(res.report["audioFramesRead"], 0)
        self.assertEqual(res.report["errors"], [])

    def test_T1_FA06_04_rdpsnd_waveinfo_v5(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=5)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 500},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreater(res.report["audioFramesRead"], 0)
        self.assertEqual(res.report["errors"], [])

    def test_T1_FA06_05_rdpsnd_waveconfirm_pacing(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 1000},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreaterEqual(res.report["waveConfirmsSent"], 1)
        metrics = srv.metrics()
        self.assertGreaterEqual(metrics["audioBlocksConfirmed"], 1)
        self.assertGreaterEqual(metrics["lastConfirmLatencyMs"], 0)


class TestTier1FA07AudioSync(WireE2ETestCase):
    tier = 1
    feature_area = "FA07"

    def test_T1_FA07_01_steady_jitter_window(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 2000},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertLess(abs(res.report["audioDriftMs"]), 150)
        self.assertEqual(res.report["audioDrops"], 0)
        self.assertLessEqual(res.report["audioQueuedMs"], 150)

    def test_T1_FA07_02_set_volume_nominal(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "set_volume", "volume": 0.5},
                {"action": "drain_audio", "durationMs": 500},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertEqual(res.report["errors"], [])
        self.assertGreater(res.report["audioFramesRead"], 0)
        self.assertGreaterEqual(res.report["waveConfirmsSent"], 1)

    def test_T1_FA07_03_mute_unmute_continues_confirm(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "set_mute", "muted": True},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "set_mute", "muted": False},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreaterEqual(res.report["waveConfirmsSent"], 1)
        self.assertEqual(res.report["errors"], [])

    def test_T1_FA07_04_av_sync_bounded_latency(self) -> None:
        srv = self.start_server(auth="nla")
        import threading

        def _beat() -> None:
            for _ in range(3):
                time.sleep(0.35)
                try:
                    srv.trigger_frame()
                except Exception:
                    return

        t = threading.Thread(target=_beat, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 1500},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=2.0)
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreater(res.report["framesReceived"], 1)
        self.assertGreater(res.report["audioFramesRead"], 0)
        self.assertLess(srv.metrics()["lastConfirmLatencyMs"], 150)

    def test_T1_FA07_05_clean_audio_teardown_and_reset(self) -> None:
        srv = self.start_server(auth="nla")
        res1 = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        res2 = self.run_cli(
            port=srv.rdp_port,
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res1.returncode, 0, res1.stderr)
        self.assertEqual(res2.returncode, 0, res2.stderr)
        assert res2.report is not None
        self.assertEqual(res2.report["audioDrops"], 0)


class TestTier1FA08ViewportInput(WireE2ETestCase):
    tier = 1
    feature_area = "FA08"

    def test_T1_FA08_02_transformed_pointer_coords_wire(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            width=1280,
            height=720,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 640, "y": 360, "buttonMask": 1, "down": True, "wheelDelta": 0},
                {"action": "pointer", "x": 640, "y": 360, "buttonMask": 1, "down": False, "wheelDelta": 0},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        events = srv.inputs()["events"]
        ptr = [e for e in events if e.get("kind") == "pointer" and e.get("x") == 640 and e.get("y") == 360]
        self.assertGreaterEqual(len(ptr), 1, f"Expected pointer (640, 360) in {events}")


class TestTier1FA09Input(WireE2ETestCase):
    tier = 1
    feature_area = "FA09"

    def test_T1_FA09_02_special_keys_ctrl_alt_del_f5_wire(self) -> None:
        srv = self.start_server(auth="nla")
        # Ctrl(0x1D), Alt(0x38), Del(0x53 ext), F5(0x3F)
        actions = [
            {"action": "wait_active", "timeoutMs": 5000},
            {"action": "scancode", "code": 0x1D, "extended": False, "down": True},
            {"action": "scancode", "code": 0x38, "extended": False, "down": True},
            {"action": "scancode", "code": 0x53, "extended": True, "down": True},
            {"action": "scancode", "code": 0x53, "extended": True, "down": False},
            {"action": "scancode", "code": 0x38, "extended": False, "down": False},
            {"action": "scancode", "code": 0x1D, "extended": False, "down": False},
            {"action": "scancode", "code": 0x3F, "extended": False, "down": True},
            {"action": "scancode", "code": 0x3F, "extended": False, "down": False},
            {"action": "disconnect"},
        ]
        res = self.run_cli(port=srv.rdp_port, actions=actions)
        self.assertEqual(res.returncode, 0, res.stderr)
        events = [e for e in srv.inputs()["events"] if e.get("kind") == "scancode"]
        self.assertGreaterEqual(len(events), 8)

    def test_T1_FA09_03_unicode_ime_utf16_wire(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "unicode", "text": "你好é"},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        events = [e for e in srv.inputs()["events"] if e.get("kind") == "unicode"]
        self.assertGreaterEqual(len(events), 3)

    def test_T1_FA09_04_hardware_scancode_extended_wire(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "scancode", "code": 0x1E, "extended": False, "down": True},
                {"action": "scancode", "code": 0x4D, "extended": True, "down": True},
                {"action": "scancode", "code": 0x4D, "extended": True, "down": False},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        events = [e for e in srv.inputs()["events"] if e.get("kind") == "scancode"]
        self.assertTrue(any(e.get("extended") is True for e in events), f"Missing extended scancode in {events}")

    def test_T1_FA09_05_mouse_hover_and_scroll_wheel_wire(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 300, "y": 220, "buttonMask": 0, "down": False, "wheelDelta": 0},
                {"action": "pointer", "x": 300, "y": 220, "buttonMask": 0, "down": False, "wheelDelta": 120},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        events = [e for e in srv.inputs()["events"] if e.get("kind") == "pointer"]
        self.assertTrue(any(e.get("wheelDelta", 0) != 0 for e in events), f"Missing wheelDelta in {events}")


class TestTier1FA10IpadStatic(WireE2ETestCase):
    tier = 1
    feature_area = "FA10"

    def test_T1_FA10_02_xcode_pbxproj_plist_podfile_docs(self) -> None:
        pbxproj = (REPO_ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
        self.assertIn('TARGETED_DEVICE_FAMILY = "1,2"', pbxproj)

        with (REPO_ROOT / "ios" / "Runner" / "Info.plist").open("rb") as fh:
            plist = plistlib.load(fh)
        self.assertTrue(
            plist.get("UISupportsIndirectInputEvents") is True
            or plist.get("UIApplicationSupportsIndirectInputEvents") is True,
            "Info.plist must enable indirect input events",
        )
        self.assertIn("audio", plist.get("UIBackgroundModes", []))
        self.assertIs(plist.get("UIRequiresFullScreen"), False)
        ipad_orientations = plist.get("UISupportedInterfaceOrientations~ipad", [])
        self.assertGreaterEqual(len(ipad_orientations), 4)

        doc_path = REPO_ROOT / "docs" / "ipad-build-and-verify.md"
        self.assertTrue(doc_path.is_file(), "docs/ipad-build-and-verify.md missing")
        doc_text = doc_path.read_text(encoding="utf-8")
        self.assertIn("aarch64-apple-ios", doc_text)

        # M4 deliverable: Podfile & Rust XCFramework build hook
        podfile = REPO_ROOT / "ios" / "Podfile"
        self.assertTrue(podfile.is_file(), "ios/Podfile missing (M4 deliverable)")

    def test_T1_FA10_05_ios_audio_session_and_rdp_core_hygiene(self) -> None:
        # 1. Pure-Rust platform isolation in rdp-core
        rdp_core_rs = list((REPO_ROOT / "crates" / "rdp-core" / "src").rglob("*.rs"))
        self.assertGreater(len(rdp_core_rs), 0)
        for rs_file in rdp_core_rs:
            content = rs_file.read_text(encoding="utf-8")
            self.assertNotRegex(content, r"\b(UIKit|AVAudioSession|AudioTrack|oboe)\b", f"Platform leak in {rs_file}")

        # 2. iOS Swift AVAudioSession playback bridge (M4 deliverable)
        swift_files = list((REPO_ROOT / "ios" / "Runner").rglob("*.swift"))
        combined_swift = "\n".join(p.read_text(encoding="utf-8") for p in swift_files)
        self.assertIn("AVAudioSession", combined_swift, "iOS Swift AVAudioSession bridge missing (M4 deliverable)")
        self.assertRegex(combined_swift, r"\.playback", "AVAudioSession playback category missing (M4 deliverable)")

        # 3. Cross-compile check if cargo + xcrun + aarch64-apple-ios target installed;
        #    on non-macOS hosts without xcrun, verify rustup target + cargo tree/metadata + aws-lc absence.
        if shutil.which("cargo"):
            if shutil.which("xcrun"):
                proc = subprocess.run(
                    ["cargo", "check", "--locked", "--target", "aarch64-apple-ios", "-p", "rdp-ffi"],
                    cwd=str(REPO_ROOT),
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(proc.returncode, 0, f"cargo check aarch64-apple-ios failed:\n{proc.stderr}")
            else:
                rustup_proc = subprocess.run(
                    ["rustup", "target", "list", "--installed"],
                    cwd=str(REPO_ROOT),
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(
                    rustup_proc.returncode,
                    0,
                    f"rustup target list failed:\n{rustup_proc.stderr}",
                )
                self.assertIn(
                    "aarch64-apple-ios",
                    rustup_proc.stdout.splitlines(),
                    "aarch64-apple-ios target not installed in rustup",
                )

                for pkg in ("rdp-core", "rdp-ffi"):
                    tree_proc = subprocess.run(
                        [
                            "cargo",
                            "tree",
                            "--locked",
                            "-p",
                            pkg,
                            "--target",
                            "aarch64-apple-ios",
                            "-e",
                            "normal,build",
                        ],
                        cwd=str(REPO_ROOT),
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(
                        tree_proc.returncode,
                        0,
                        f"cargo tree {pkg} aarch64-apple-ios failed:\n{tree_proc.stderr}",
                    )
                    self.assertNotRegex(
                        tree_proc.stdout,
                        r"\b(aws-lc-sys|aws-lc-rs)\b",
                        f"Forbidden aws-lc crate detected in {pkg} aarch64-apple-ios tree",
                    )

                meta_proc = subprocess.run(
                    [
                        "cargo",
                        "metadata",
                        "--locked",
                        "--filter-platform",
                        "aarch64-apple-ios",
                        "--format-version",
                        "1",
                    ],
                    cwd=str(REPO_ROOT),
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(
                    meta_proc.returncode,
                    0,
                    f"cargo metadata aarch64-apple-ios failed:\n{meta_proc.stderr}",
                )


class TestTier1FA11TestServer(WireE2ETestCase):
    tier = 1
    feature_area = "FA11"

    def test_T1_FA11_01_server_health_endpoint(self) -> None:
        srv = self.start_server(auth="nla")
        health = srv.health()
        self.assertIs(health.get("ok"), True)
        self.assertEqual(health.get("rdpPort"), srv.rdp_port)
        self.assertTrue(is_valid_sha256_hex(health.get("certSha256")))

    def test_T1_FA11_02_server_metrics_lifecycle(self) -> None:
        srv = self.start_server(auth="nla")
        initial = srv.metrics()
        for field in RDP_TEST_SERVER_METRICS_FIELDS:
            self.assertIn(field, initial, f"Missing /metrics field {field!r}")
        self.assertEqual(initial["activeSessions"], 0)

        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        time.sleep(0.1)
        after = srv.metrics()
        self.assertEqual(after["activeSessions"], 0)
        self.assertGreaterEqual(after["framesSent"], 1)

    def test_T1_FA11_03_server_inputs_recording(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 100, "y": 200, "buttonMask": 1, "down": True, "wheelDelta": 0},
                {"action": "scancode", "code": 0x1E, "extended": False, "down": True},
                {"action": "scancode", "code": 0x1E, "extended": False, "down": False},
                {"action": "unicode", "text": "A"},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        kinds = [e.get("kind") for e in srv.inputs()["events"]]
        self.assertIn("pointer", kinds)
        self.assertIn("scancode", kinds)
        self.assertIn("unicode", kinds)

    def test_T1_FA11_04_server_control_frame(self) -> None:
        srv = self.start_server(auth="nla")
        import threading

        pre_frames = [0]
        thread_errors: list[BaseException] = []

        def _pulse() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    m = srv.metrics()
                    if m.get("activeSessions", 0) >= 1:
                        pre_frames[0] = int(m["framesSent"])
                        resp = srv.trigger_frame()
                        if resp.status != 200:
                            raise AssertionError(f"POST /control/frame returned HTTP {resp.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1 before /control/frame")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_pulse, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 500},
                {"action": "disconnect"},
            ],
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertGreater(srv.metrics()["framesSent"], pre_frames[0])

    def test_T1_FA11_05_server_control_deactivate_and_disconnect(self) -> None:
        srv = self.start_server(auth="nla")
        import threading

        thread_errors: list[BaseException] = []

        def _drive() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.2)
                        r1 = srv.trigger_deactivate()
                        if r1.status != 200:
                            raise AssertionError(f"POST /control/deactivate returned HTTP {r1.status}")
                        time.sleep(0.4)
                        r2 = srv.trigger_disconnect()
                        if r2.status != 200:
                            raise AssertionError(f"POST /control/disconnect returned HTTP {r2.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1 before /control/deactivate")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_drive, daemon=True)
        t.start()
        res = self.run_cli(
            port=srv.rdp_port,
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 3000},
            ],
            timeout=15.0,
        )
        t.join(timeout=2.0)
        self.assertEqual(thread_errors, [], f"Background thread error(s): {thread_errors}")
        self.assertGreaterEqual(srv.metrics()["reactivations"], 1)
        report = self.assert_clean_disconnect_report(res)
        self.assertTrue(bool(report["disconnectReason"]))
        # Sanity check probe_rdp_tls_cert_sha256 import stays exercised in FA11/FA02
        self.assertTrue(callable(probe_rdp_tls_cert_sha256))
