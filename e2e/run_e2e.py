#!/usr/bin/env python3
"""Sequential 4-Tier E2E Test Runner & Report Generator for aer-rdp."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from e2e.lib.config import (  # noqa: E402
    DEFAULT_ARTIFACTS_DIR,
    EXPECTED_FEATURE_AREA_COUNT,
    FEATURE_IDS,
    INTEGRATION_TEST_DIR,
    MANIFEST_PATH,
    SELF_TESTS_DIR,
    TESTS_DIR,
    TIER_MINIMUMS,
    TOTAL_MINIMUM,
    resolve_cli_bin,
    resolve_server_bin,
)
from e2e.lib.flutter_runner import (  # noqa: E402
    audit_integration_test_sources,
    flutter_executable,
    run_flutter_analyze,
    run_flutter_integration_tests,
)

_FLUTTER_SUMMARY_RE = re.compile(r"\+(\d+)(?:\s+-(\d+))?\s*:")

TIER_E2E_MODULES: dict[int, str] = {
    1: "e2e.tests.test_tier1_wire",
    2: "e2e.tests.test_tier2_wire",
    3: "e2e.tests.test_tier3_wire",
    4: "e2e.tests.test_tier4_wire",
}

TIER_FLUTTER_FILES: dict[int, Path] = {
    1: INTEGRATION_TEST_DIR / "tier1_ui_test.dart",
    2: INTEGRATION_TEST_DIR / "tier2_ui_test.dart",
    3: INTEGRATION_TEST_DIR / "tier3_ui_test.dart",
    4: INTEGRATION_TEST_DIR / "tier4_scenarios_test.dart",
}


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_manifest_and_check_thresholds() -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    if not MANIFEST_PATH.is_file():
        return {}, [f"Manifest not found: {MANIFEST_PATH}"]
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    tests = manifest.get("tests", [])
    areas = manifest.get("feature_areas", [])
    if len(areas) != EXPECTED_FEATURE_AREA_COUNT:
        errors.append(f"Expected {EXPECTED_FEATURE_AREA_COUNT} feature areas, got {len(areas)}")

    tier_counts = {1: 0, 2: 0, 3: 0, 4: 0}
    seen_ids: set[str] = set()
    t1_features: set[str] = set()
    t2_features: set[str] = set()

    for entry in tests:
        tid = entry.get("id")
        tier = entry.get("tier")
        if not tid or tid in seen_ids:
            errors.append(f"Duplicate or missing test ID: {tid!r}")
        else:
            seen_ids.add(tid)
        if tier not in tier_counts:
            errors.append(f"Invalid tier {tier!r} on {tid!r}")
            continue
        tier_counts[tier] += 1
        for feat in entry.get("features", []):
            if tier == 1:
                t1_features.add(feat)
            elif tier == 2:
                t2_features.add(feat)

    for tier, minimum in TIER_MINIMUMS.items():
        if tier_counts[tier] < minimum:
            errors.append(f"Tier {tier} count {tier_counts[tier]} < minimum {minimum}")
    total = sum(tier_counts.values())
    if total < TOTAL_MINIMUM:
        errors.append(f"Total test count {total} < minimum {TOTAL_MINIMUM}")

    missing_t1 = sorted(set(FEATURE_IDS) - t1_features)
    missing_t2 = sorted(set(FEATURE_IDS) - t2_features)
    if missing_t1:
        errors.append(f"Tier 1 missing feature coverage: {missing_t1}")
    if missing_t2:
        errors.append(f"Tier 2 missing feature coverage: {missing_t2}")

    return manifest, errors


def _run_unittest_suite(loader: unittest.TestLoader, suite: unittest.TestSuite) -> dict[str, Any]:
    started = time.monotonic()
    runner = unittest.TextTestRunner(verbosity=2, stream=sys.stdout)
    result = runner.run(suite)
    duration = round(time.monotonic() - started, 3)

    failures = [{"test": str(t), "trace": msg} for t, msg in result.failures]
    errors = [{"test": str(t), "trace": msg} for t, msg in result.errors]
    skipped = [{"test": str(t), "reason": msg} for t, msg in result.skipped]
    return {
        "testsRun": result.testsRun,
        "passed": result.testsRun - len(failures) - len(errors) - len(skipped),
        "failed": len(failures),
        "errors": len(errors),
        "skipped": len(skipped),
        "durationSec": duration,
        "ok": result.wasSuccessful(),
        "failureDetails": failures + errors,
    }


def _write_junit_xml(report: dict[str, Any], xml_path: Path) -> None:
    xml_path.parent.mkdir(parents=True, exist_ok=True)
    root = ET.Element("testsuites")
    for tier_entry in report.get("tiers", []):
        ts = ET.SubElement(
            root,
            "testsuite",
            name=f"tier-{tier_entry['tier']}",
            tests=str(tier_entry.get("testsRun", 0)),
            failures=str(tier_entry.get("failed", 0)),
            errors=str(tier_entry.get("errors", 0)),
            time=str(tier_entry.get("durationSec", 0.0)),
        )
        for detail in tier_entry.get("failureDetails", []):
            tc = ET.SubElement(ts, "testcase", name=detail["test"])
            fail_el = ET.SubElement(tc, "failure", message="Test failed")
            fail_el.text = detail["trace"]
    tree = ET.ElementTree(root)
    tree.write(xml_path, encoding="utf-8", xml_declaration=True)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="run_e2e.py",
        description="aer-rdp sequential 4-tier opaque-box E2E test runner",
    )
    parser.add_argument("--tier", choices=("1", "2", "3", "4", "all"), default="all")
    parser.add_argument("--channel", choices=("self", "e2e", "flutter", "all"), default="e2e")
    parser.add_argument("--mode", choices=("mock", "live"), default="live")
    parser.add_argument("--self-test", action="store_true", help="Run self-tests (SELF-01..SELF-08) in mock mode")
    parser.add_argument("--dry-run", action="store_true", help="Validate manifest, thresholds, and plan without binaries")
    parser.add_argument("--stop-on-tier-failure", action="store_true", help="Halt sequential --tier all on first failure")
    parser.add_argument("--rdp-server-bin", default=None, help="Path to rdp-test-server binary")
    parser.add_argument("--rdp-cli-bin", default=None, help="Path to aer-rdp-cli binary")
    parser.add_argument("--flutter-device", default=None, help="Optional Flutter target device ID")
    parser.add_argument("--report", default=str(DEFAULT_ARTIFACTS_DIR / "report.json"), help="JSON output report path")
    parser.add_argument("--junit-xml", default=None, help="Optional JUnit XML output path")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    channel = "self" if args.self_test else args.channel
    mode = "mock" if (args.self_test or args.dry_run) else args.mode
    tiers = [1, 2, 3, 4] if args.tier == "all" else [int(args.tier)]

    if args.rdp_server_bin:
        os.environ["AER_RDP_SERVER_BIN"] = args.rdp_server_bin
    if args.rdp_cli_bin:
        os.environ["AER_RDP_CLI_BIN"] = args.rdp_cli_bin
    os.environ["AER_RDP_E2E_MODE"] = mode

    manifest, gate_errors = load_manifest_and_check_thresholds()
    report: dict[str, Any] = {
        "startedAt": _utc_now(),
        "tierArg": args.tier,
        "tiersSelected": tiers,
        "channel": channel,
        "mode": mode,
        "dryRun": args.dry_run,
        "stopOnTierFailure": args.stop_on_tier_failure,
        "gateErrors": gate_errors,
        "selfTest": None,
        "tiers": [],
        "ok": False,
        "exitCode": 0,
    }

    def _finalize(code: int) -> int:
        report["finishedAt"] = _utc_now()
        report["exitCode"] = code
        report["ok"] = code == 0
        report_path = Path(args.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        if args.junit_xml:
            _write_junit_xml(report, Path(args.junit_xml))
        return code

    if gate_errors:
        print("THRESHOLD / MANIFEST GATE FAILED:", file=sys.stderr)
        for err in gate_errors:
            print(f"  - {err}", file=sys.stderr)
        return _finalize(3)

    # Dry-run verifies discovery, threshold gates, and sequential plan without executing binaries
    if args.dry_run:
        loader = unittest.TestLoader()
        flutter_audit = audit_integration_test_sources()
        id_locations: dict[str, str] = flutter_audit["id_locations"]  # type: ignore[assignment]
        for tier in tiers:
            mod_name = TIER_E2E_MODULES[tier]
            suite = loader.loadTestsFromName(mod_name)
            manifest_tier = [t for t in manifest["tests"] if t["tier"] == tier]
            dart_name = TIER_FLUTTER_FILES[tier].name
            flutter_count = sum(1 for fname in id_locations.values() if fname == dart_name)
            tier_plan = {
                "tier": tier,
                "e2eModule": mod_name,
                "e2eDiscoveredCount": suite.countTestCases(),
                "flutterDiscoveredCount": flutter_count,
                "manifestTierCount": len(manifest_tier),
                "flutterFile": str(TIER_FLUTTER_FILES[tier].relative_to(REPO_ROOT)),
                "testsRun": len(manifest_tier),
                "passed": len(manifest_tier),
                "failed": 0,
                "errors": 0,
                "durationSec": 0.0,
                "ok": True,
                "dryRun": True,
            }
            report["tiers"].append(tier_plan)
            print(
                f"[DRY-RUN] Tier {tier}: {len(manifest_tier)} manifest cases | "
                f"{suite.countTestCases()} wire/static unittest methods | "
                f"{flutter_count} Flutter cases ({tier_plan['flutterFile']})"
            )
        return _finalize(0)

    # Self-test execution
    if channel == "self":
        print("=== Running E2E Self-Tests (e2e/tests_self/) ===")
        loader = unittest.TestLoader()
        suite = loader.discover(start_dir=str(SELF_TESTS_DIR), pattern="test_*.py", top_level_dir=str(REPO_ROOT))
        self_res = _run_unittest_suite(loader, suite)

        # Also verify flutter analyze if flutter SDK is present on this host
        if flutter_executable() is not None:
            print("=== Running `flutter analyze` static check ===")
            fa = run_flutter_analyze()
            self_res["flutterAnalyzeExitCode"] = fa.returncode
            if fa.returncode != 0:
                self_res["ok"] = False
                self_res["failureDetails"].append({
                    "test": "flutter analyze",
                    "trace": f"{fa.stdout}\n{fa.stderr}".strip(),
                })
        report["selfTest"] = self_res
        if not self_res["ok"] or self_res["testsRun"] == 0:
            return _finalize(3)
        return _finalize(0)

    # Live binary availability gate when running e2e wire channel
    if channel in ("e2e", "all") and mode == "live":
        srv_bin = resolve_server_bin(args.rdp_server_bin)
        cli_bin = resolve_cli_bin(args.rdp_cli_bin)
        missing = []
        if srv_bin is None or not srv_bin.is_file():
            missing.append("rdp-test-server (AER_RDP_SERVER_BIN / --rdp-server-bin)")
        if cli_bin is None or not cli_bin.is_file():
            missing.append("aer-rdp-cli (AER_RDP_CLI_BIN / --rdp-cli-bin)")
        if missing:
            msg = f"Missing required live binary/binaries: {', '.join(missing)}"
            print(msg, file=sys.stderr)
            report["gateErrors"].append(msg)
            return _finalize(2)

    overall_failed = False
    loader = unittest.TestLoader()

    # Strictly sequential execution: Tier 1 -> Tier 2 -> Tier 3 -> Tier 4
    for tier in tiers:
        print(f"\n=== Tier {tier} Execution ===")
        tier_started = time.monotonic()
        tier_entry: dict[str, Any] = {
            "tier": tier,
            "startedAt": _utc_now(),
            "testsRun": 0,
            "passed": 0,
            "failed": 0,
            "errors": 0,
            "durationSec": 0.0,
            "ok": True,
            "failureDetails": [],
        }

        if channel in ("e2e", "all"):
            mod_name = TIER_E2E_MODULES[tier]
            suite = loader.loadTestsFromName(mod_name)
            e2e_res = _run_unittest_suite(loader, suite)
            tier_entry["e2e"] = e2e_res
            tier_entry["testsRun"] += e2e_res["testsRun"]
            tier_entry["passed"] += e2e_res["passed"]
            tier_entry["failed"] += e2e_res["failed"]
            tier_entry["errors"] += e2e_res["errors"]
            tier_entry["failureDetails"].extend(e2e_res["failureDetails"])
            if not e2e_res["ok"]:
                tier_entry["ok"] = False

        if channel in ("flutter", "all"):
            dart_file = TIER_FLUTTER_FILES[tier]
            flutter_audit = audit_integration_test_sources()
            id_locs: dict[str, str] = flutter_audit["id_locations"]  # type: ignore[assignment]
            fl_expected = sum(1 for fname in id_locs.values() if fname == dart_file.name)
            fl_res = run_flutter_integration_tests(files=[dart_file], device=args.flutter_device)
            fl_passed = fl_expected if fl_res.returncode == 0 else 0
            fl_failed = 0 if fl_res.returncode == 0 else max(1, fl_expected)
            matches = _FLUTTER_SUMMARY_RE.findall(f"{fl_res.stdout}\n{fl_res.stderr}")
            if matches:
                last_p, last_f = matches[-1]
                fl_passed = int(last_p)
                fl_failed = int(last_f) if last_f else (0 if fl_res.returncode == 0 else 1)
            fl_total = max(fl_expected, fl_passed + fl_failed) if fl_res.returncode == 0 else (fl_passed + fl_failed)
            tier_entry["testsRun"] += fl_total
            tier_entry["passed"] += fl_passed
            tier_entry["failed"] += fl_failed
            tier_entry["flutter"] = {
                "file": str(dart_file.relative_to(REPO_ROOT)),
                "testsRun": fl_total,
                "passed": fl_passed,
                "failed": fl_failed,
                "returncode": fl_res.returncode,
                "command": fl_res.command,
                "ok": fl_res.returncode == 0,
            }
            if fl_res.returncode != 0:
                tier_entry["ok"] = False
                tier_entry["failureDetails"].append({
                    "test": str(dart_file.relative_to(REPO_ROOT)),
                    "trace": f"{fl_res.stdout}\n{fl_res.stderr}".strip(),
                })

        tier_entry["durationSec"] = round(time.monotonic() - tier_started, 3)
        tier_entry["finishedAt"] = _utc_now()
        report["tiers"].append(tier_entry)

        if not tier_entry["ok"]:
            overall_failed = True
            if args.stop_on_tier_failure:
                print(f"Stopping early after Tier {tier} failure (--stop-on-tier-failure).", file=sys.stderr)
                break

    return _finalize(1 if overall_failed else 0)


if __name__ == "__main__":
    sys.exit(main())
