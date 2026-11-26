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
