"""SELF-05: Verify e2e/run_e2e.py --tier 1|2|3|4|all --dry-run & JSON/JUnit reporting."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET

from e2e.lib.config import DEFAULT_ARTIFACTS_DIR, E2E_DIR, REPO_ROOT


class TestSelf05RunnerCliTiers(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = DEFAULT_ARTIFACTS_DIR / "tmp_self05"
        self.scratch.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        shutil.rmtree(self.scratch, ignore_errors=True)

    def _run_runner(self, *extra_args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(E2E_DIR / "run_e2e.py"), *extra_args],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )

    def test_SELF_05_individual_tiers_filter_strictly(self) -> None:
        for tier in (1, 2, 3, 4):
            report_path = self.scratch / f"tier{tier}.json"
            proc = self._run_runner("--tier", str(tier), "--dry-run", "--report", str(report_path))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertTrue(data["ok"])
            self.assertTrue(data["dryRun"])
            self.assertEqual([t["tier"] for t in data["tiers"]], [tier])

    def test_SELF_05_tier_all_runs_sequential_1_to_4_and_writes_junit(self) -> None:
        report_path = self.scratch / "all.json"
        junit_path = self.scratch / "junit.xml"
        proc = self._run_runner(
            "--tier",
            "all",
            "--dry-run",
            "--report",
            str(report_path),
            "--junit-xml",
            str(junit_path),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual([t["tier"] for t in data["tiers"]], [1, 2, 3, 4])
        total_manifest = sum(t["manifestTierCount"] for t in data["tiers"])
        self.assertEqual(total_manifest, 135)

        tree = ET.parse(junit_path)
        suites = tree.getroot().findall("testsuite")
        self.assertEqual([s.attrib["name"] for s in suites], ["tier-1", "tier-2", "tier-3", "tier-4"])
