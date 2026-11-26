"""Tier 4: Real-World Application Scenarios E2E wire & static tests."""

from __future__ import annotations

import plistlib
import threading
import time

from e2e.lib.config import REPO_ROOT
from e2e.lib.fault_proxy import FaultProxy
from e2e.lib.schema import validate_profiles_payload
from e2e.tests.conftest import WireE2ETestCase


class TestTier4Scenarios(WireE2ETestCase):
    tier = 4
    feature_area = "SCENARIO"

    def test_T4_01_daily_windows_work_session_wire(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        sha = srv.health()["certSha256"].lower()
        res = self.run_cli(
            port=srv.rdp_port,
            auth="nla",
            trust_cert=f"sha256:{sha}",
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "pointer", "x": 200, "y": 150, "buttonMask": 1, "down": True, "wheelDelta": 0},
                {"action": "pointer", "x": 200, "y": 150, "buttonMask": 1, "down": False, "wheelDelta": 0},
                {"action": "scancode", "code": 0x1E, "extended": False, "down": True},
                {"action": "scancode", "code": 0x1E, "extended": False, "down": False},
                {"action": "unicode", "text": "工作"},
                {"action": "drain_audio", "durationMs": 3000},
                {"action": "disconnect"},
            ],
            timeout=25.0,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        self.assertGreaterEqual(res.report["framesReceived"], 1)
        self.assertGreater(res.report["audioFramesRead"], 0)
        self.assertGreaterEqual(res.report["waveConfirmsSent"], 2)
        self.assertLess(abs(res.report["audioDriftMs"]), 150)
        kinds = {e.get("kind") for e in srv.inputs()["events"]}
        self.assertTrue({"pointer", "scancode", "unicode"}.issubset(kinds))
        time.sleep(0.1)
        self.assertEqual(srv.metrics()["activeSessions"], 0)

    def test_T4_02_onboarding_cert_and_export_schema(self) -> None:
        srv = self.start_server(auth="nla")
        res = self.run_cli(
            port=srv.rdp_port,
            trust_cert="any",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        assert res.report is not None
        sha = res.report["certSha256"]
        self.assertIsNotNone(sha)

        # Verify exported profile JSON conforms strictly to Profile JSON Schema v1
        valid_profiles = self.load_fixture("profiles_valid.json")
        self.assertEqual(validate_profiles_payload(valid_profiles), [])

    def test_T4_03_wifi_jitter_burst_drop_and_reconnect(self) -> None:
        srv = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)
        sha = srv.health()["certSha256"].lower()

        with FaultProxy(
            "127.0.0.1",
            srv.rdp_port,
            mode="jitter_stall",
            stall_after_bytes=4096,
            stall_after_secs=0.8,
            stall_duration_ms=250,
        ) as jitter_proxy:
            r1 = self.run_cli(
                port=jitter_proxy.port,
                trust_cert=f"sha256:{sha}",
                audio="local",
                actions=[
                    {"action": "wait_active", "timeoutMs": 5000},
                    {"action": "drain_audio", "durationMs": 2500},
                    {"action": "disconnect"},
                ],
                timeout=20.0,
            )
        self.assertEqual(r1.returncode, 0, r1.stderr)
        self.assertTrue(jitter_proxy.fault_triggered)
        assert r1.report is not None
        self.assertGreater(r1.report["audioDrops"], 0)

        with FaultProxy("127.0.0.1", srv.rdp_port, mode="reset_after_secs", reset_after_secs=0.7) as drop_proxy:
            r2 = self.run_cli(
                port=drop_proxy.port,
                trust_cert=f"sha256:{sha}",
                audio="local",
                actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "drain_audio", "durationMs": 2500}],
                timeout=15.0,
            )
        self.assertTrue(drop_proxy.fault_triggered)
        self.assert_clean_disconnect_report(r2)

        r3 = self.run_cli(
            port=srv.rdp_port,
            trust_cert=f"sha256:{sha}",
            audio="local",
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(r3.returncode, 0, r3.stderr)

    def test_T4_05_multi_workstation_switching_wire(self) -> None:
        srv_tls = self.start_server(auth="tls", audio_hz=440, rdpsnd_version=8)
        srv_nla = self.start_server(auth="nla", audio_hz=440, rdpsnd_version=8)

        r_lab = self.run_cli(
            port=srv_tls.rdp_port,
            auth="tls",
            audio="off",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 400},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(r_lab.returncode, 0, r_lab.stderr)
        assert r_lab.report is not None
        self.assertEqual(r_lab.report["audioFramesRead"], 0)

        r_home = self.run_cli(
            port=srv_nla.rdp_port,
            auth="nla",
            audio="local",
            actions=[
                {"action": "wait_active", "timeoutMs": 5000},
                {"action": "drain_audio", "durationMs": 600},
                {"action": "disconnect"},
            ],
        )
        self.assertEqual(r_home.returncode, 0, r_home.stderr)
        assert r_home.report is not None
        self.assertGreater(r_home.report["audioFramesRead"], 0)

    def test_T4_06_remote_display_reset_and_dpum_shutdown(self) -> None:
        srv = self.start_server(auth="nla")
        thread_errors: list[BaseException] = []

        def _flow() -> None:
            try:
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    if srv.metrics().get("activeSessions", 0) >= 1:
                        time.sleep(0.2)
                        r_deact = srv.trigger_deactivate()
                        if r_deact.status != 200:
                            raise AssertionError(f"POST /control/deactivate returned HTTP {r_deact.status}")
                        time.sleep(0.4)
                        r_frame = srv.trigger_frame()
                        if r_frame.status != 200:
                            raise AssertionError(f"POST /control/frame returned HTTP {r_frame.status}")
                        time.sleep(0.3)
                        r_disc = srv.trigger_disconnect()
                        if r_disc.status != 200:
                            raise AssertionError(f"POST /control/disconnect returned HTTP {r_disc.status}")
                        return
                    time.sleep(0.05)
                raise TimeoutError("Timed out waiting for activeSessions >= 1")
            except BaseException as exc:
                thread_errors.append(exc)

        t = threading.Thread(target=_flow, daemon=True)
        t.start()
        r1 = self.run_cli(
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
        r1_report = self.assert_clean_disconnect_report(r1)
        self.assertTrue(bool(r1_report["disconnectReason"]))

        r2 = self.run_cli(
            port=srv.rdp_port,
            actions=[{"action": "wait_active", "timeoutMs": 5000}, {"action": "disconnect"}],
        )
        self.assertEqual(r2.returncode, 0, r2.stderr)

    def test_T4_07_ipad_productivity_static_and_wire(self) -> None:
        pbxproj = (REPO_ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
        self.assertIn('TARGETED_DEVICE_FAMILY = "1,2"', pbxproj)
        with (REPO_ROOT / "ios" / "Runner" / "Info.plist").open("rb") as fh:
            plist = plistlib.load(fh)
        self.assertIn("audio", plist.get("UIBackgroundModes", []))
        swift_files = list((REPO_ROOT / "ios" / "Runner").rglob("*.swift"))
        combined = "\n".join(p.read_text(encoding="utf-8") for p in swift_files)
        self.assertIn("AVAudioSession", combined)
