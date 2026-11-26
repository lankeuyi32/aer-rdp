"""SELF-06: Verify runner non-zero exit codes on invalid args, missing live bins, and gate errors."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import unittest

from e2e.lib.config import DEFAULT_ARTIFACTS_DIR, E2E_DIR, REPO_ROOT


class TestSelf06RunnerErrorCodes(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = DEFAULT_ARTIFACTS_DIR / "tmp_self06"
        self.scratch.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        shutil.rmtree(self.scratch, ignore_errors=True)

    def test_SELF_06_invalid_tier_exits_2(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(E2E_DIR / "run_e2e.py"), "--tier", "5"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 2)

    def test_SELF_06_missing_live_binaries_exits_2(self) -> None:
        report_path = self.scratch / "missing_bins.json"
        env = dict(os.environ)
        env["AER_RDP_SERVER_BIN"] = str(self.scratch / "nonexistent_server")
        env["AER_RDP_CLI_BIN"] = str(self.scratch / "nonexistent_cli")
        proc = subprocess.run(
            [
                sys.executable,
                str(E2E_DIR / "run_e2e.py"),
                "--tier",
                "1",
                "--channel",
                "e2e",
                "--mode",
                "live",
                "--report",
                str(report_path),
            ],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr)

    def test_SELF_06_run_e2e_main_gate_error_exits_3(self) -> None:
        import e2e.run_e2e as runner

        orig = runner.load_manifest_and_check_thresholds
        report_path = self.scratch / "gate_fail.json"
        try:
            runner.load_manifest_and_check_thresholds = lambda: ({}, ["Simulated threshold gate failure"])
            code = runner.main(["--tier", "all", "--dry-run", "--report", str(report_path)])
            self.assertEqual(code, 3)
        finally:
            runner.load_manifest_and_check_thresholds = orig

    def test_SELF_06_flutter_timeout_returns_124_and_writes_report_and_junit(self) -> None:
        import json
        import xml.etree.ElementTree as ET
        import e2e.lib.flutter_runner as fl_runner
        import e2e.run_e2e as runner

        orig_sub = fl_runner.subprocess.run
        orig_exe = fl_runner.flutter_executable
        orig_run = runner.run_flutter_integration_tests
        report_path = self.scratch / "timeout_report.json"
        junit_path = self.scratch / "timeout_junit.xml"

        def _raise_timeout(*_args: object, **_kwargs: object) -> object:
            raise subprocess.TimeoutExpired(
                cmd=["flutter", "test"],
                timeout=1.5,
                output=b"00:05 +3 -1: partial output",
                stderr=b"hang stderr",
            )

        try:
            fl_runner.flutter_executable = lambda: "/fake/flutter"
            fl_runner.subprocess.run = _raise_timeout  # type: ignore[assignment]
            res = fl_runner.run_flutter_integration_tests(timeout=1.5)
            self.assertEqual(res.returncode, 124)
            self.assertIn("partial output", res.stdout)
            self.assertIn("hang stderr", res.stderr)
            self.assertIn("timed out after 1.5s", res.stderr)

            runner.run_flutter_integration_tests = lambda **_kw: res
            code = runner.main([
                "--tier",
                "2",
                "--channel",
                "flutter",
                "--mode",
                "mock",
                "--report",
                str(report_path),
                "--junit-xml",
                str(junit_path),
            ])
            self.assertEqual(code, 1)
            self.assertTrue(report_path.is_file())
            self.assertTrue(junit_path.is_file())
            data = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertFalse(data["ok"])
            self.assertEqual(data["exitCode"], 1)
            self.assertEqual(data["tiers"][0]["flutter"]["returncode"], 124)
            self.assertEqual(data["tiers"][0]["flutter"]["passed"], 3)
            self.assertEqual(data["tiers"][0]["flutter"]["failed"], 1)
            tree = ET.parse(junit_path)
            self.assertEqual(tree.getroot().find("testsuite").attrib["name"], "tier-2")  # type: ignore[union-attr]
        finally:
            fl_runner.subprocess.run = orig_sub
            fl_runner.flutter_executable = orig_exe
            runner.run_flutter_integration_tests = orig_run

    def test_SELF_06_flutter_summary_regex_parses_skipped_counts(self) -> None:
        import e2e.run_e2e as runner

        self.assertEqual(runner._FLUTTER_SUMMARY_RE.findall("00:10 +25: All tests passed!"), [("25", "", "")])
        self.assertEqual(runner._FLUTTER_SUMMARY_RE.findall("00:19 +4 -2: Some tests failed."), [("4", "", "2")])
        self.assertEqual(runner._FLUTTER_SUMMARY_RE.findall("00:12 +8 ~2: Some skipped."), [("8", "2", "")])
        self.assertEqual(runner._FLUTTER_SUMMARY_RE.findall("00:15 +7 ~1 -3: Mixed."), [("7", "1", "3")])
        self.assertEqual(runner._FLUTTER_SUMMARY_RE.findall("2026-11-26T18:00:00+00:00 log line"), [])
        self.assertEqual(runner._FLUTTER_SUMMARY_RE.findall("timestamp +08:00 note:"), [])

    def test_SELF_06_flutter_skip_with_stderr_tz_is_not_masked(self) -> None:
        import json
        import e2e.lib.flutter_runner as fl_runner
        import e2e.run_e2e as runner

        orig_run = runner.run_flutter_integration_tests
        report_path = self.scratch / "skip_with_stderr_tz.json"
        try:
            runner.run_flutter_integration_tests = lambda **_kw: fl_runner.FlutterRunResult(
                0,
                "00:03 +5 ~1: Some tests skipped.\n",
                "2026-11-26T18:00:00+00:00 log line\n",
                ["flutter", "test"],
            )
            code = runner.main([
                "--tier",
                "2",
                "--channel",
                "flutter",
                "--mode",
                "mock",
                "--report",
                str(report_path),
            ])
            self.assertEqual(code, 1)
            data = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertFalse(data["ok"])
            self.assertEqual(data["exitCode"], 1)
            tier = data["tiers"][0]
            self.assertFalse(tier["ok"])
            self.assertFalse(tier["flutter"]["ok"])
            self.assertEqual(tier["flutter"]["passed"], 5)
            self.assertEqual(tier["flutter"]["skipped"], 1)
            self.assertTrue(tier["failureDetails"])
        finally:
            runner.run_flutter_integration_tests = orig_run

    def test_SELF_06_flutter_zero_and_underrun_passed_zero_rc_fail(self) -> None:
        import json
        import e2e.lib.flutter_runner as fl_runner
        import e2e.run_e2e as runner

        orig_run = runner.run_flutter_integration_tests
        try:
            for name, stdout, expected_passed in [
                ("zero_passed_zero_rc", "00:00 +0: All tests passed!\n", 0),
                ("partial_passed_zero_rc", "00:05 +24: All tests passed!\n", 24),
                ("empty_stdout_zero_rc", "", 0),
            ]:
                report_path = self.scratch / f"{name}.json"
                runner.run_flutter_integration_tests = lambda *_a, _out=stdout, **_kw: fl_runner.FlutterRunResult(
                    0,
                    _out,
                    "",
                    ["flutter", "test"],
                )
                code = runner.main([
                    "--tier",
                    "2",
                    "--channel",
                    "flutter",
                    "--mode",
                    "mock",
                    "--report",
                    str(report_path),
                ])
                self.assertEqual(code, 1, name)
                data = json.loads(report_path.read_text(encoding="utf-8"))
                self.assertFalse(data["ok"], name)
                self.assertEqual(data["exitCode"], 1, name)
                tier = data["tiers"][0]
                self.assertFalse(tier["ok"], name)
                self.assertFalse(tier["flutter"]["ok"], name)
                self.assertEqual(tier["flutter"]["passed"], expected_passed, name)
                self.assertEqual(tier["flutter"]["expectedTests"], 25, name)
                self.assertIn(
                    f"passed {expected_passed} < expected 25",
                    tier["failureDetails"][0]["trace"],
                    name,
                )

            # Positive control: exact expected count passes even with ISO-8601 +00:00 in stderr
            ok_report = self.scratch / "full_passed_with_tz_stderr.json"
            runner.run_flutter_integration_tests = lambda **_kw: fl_runner.FlutterRunResult(
                0,
                "00:11 +25: All tests passed!\n",
                "2026-11-26T18:00:00+00:00 benign stderr\n",
                ["flutter", "test"],
            )
            ok_code = runner.main([
                "--tier",
                "2",
                "--channel",
                "flutter",
                "--mode",
                "mock",
                "--report",
                str(ok_report),
            ])
            self.assertEqual(ok_code, 0)
            ok_data = json.loads(ok_report.read_text(encoding="utf-8"))
            self.assertTrue(ok_data["ok"])
            self.assertEqual(ok_data["exitCode"], 0)
            self.assertTrue(ok_data["tiers"][0]["ok"])
            self.assertTrue(ok_data["tiers"][0]["flutter"]["ok"])
            self.assertEqual(ok_data["tiers"][0]["flutter"]["passed"], 25)
            self.assertEqual(ok_data["tiers"][0]["flutter"]["skipped"], 0)
        finally:
            runner.run_flutter_integration_tests = orig_run
