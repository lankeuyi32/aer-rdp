"""SELF-01: Test discovery, unique IDs, tier alignment, and feature tags."""

from __future__ import annotations

import json
import re
import unittest

from e2e.lib.config import FEATURE_IDS, MANIFEST_PATH, TESTS_DIR
from e2e.lib.flutter_runner import audit_integration_test_sources

_ID_RE = re.compile(r"^(T[12]-FA(?:0[1-9]|1[01])-\d{2}|T[34]-\d{2})$")
_E2E_METHOD_ID_RE = re.compile(r"^test_(T[12]_FA\d{2}_\d{2}|T[34]_\d{2})_")


def _iter_unittest_methods(suite: unittest.TestSuite) -> list[tuple[str, unittest.TestCase]]:
    items: list[tuple[str, unittest.TestCase]] = []
    for child in suite:
        if isinstance(child, unittest.TestSuite):
            items.extend(_iter_unittest_methods(child))
        else:
            items.append((child.id(), child))
    return items


class TestSelf01DiscoveryAndIds(unittest.TestCase):
    def test_SELF_01_manifest_ids_unique_and_discoverable(self) -> None:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        entries = manifest.get("tests", [])
        self.assertEqual(len(entries), 135, f"Expected 135 manifest entries, got {len(entries)}")

        seen_ids: set[str] = set()
        for entry in entries:
            tid = entry["id"]
            self.assertRegex(tid, _ID_RE, f"Invalid test ID format: {tid!r}")
            self.assertNotIn(tid, seen_ids, f"Duplicate ID: {tid!r}")
            seen_ids.add(tid)

            tier = entry["tier"]
            self.assertIn(tier, (1, 2, 3, 4))
            self.assertTrue(tid.startswith(f"T{tier}-"), f"ID {tid} mismatches tier {tier}")

            feats = entry.get("features", [])
            self.assertGreater(len(feats), 0, f"{tid} has no feature tags")
            for f in feats:
                self.assertIn(f, FEATURE_IDS, f"{tid} references unknown feature {f!r}")

        # Discover all python unittest cases in e2e/tests/
        loader = unittest.TestLoader()
        suite = loader.discover(
            start_dir=str(TESTS_DIR),
            pattern="test_tier*.py",
            top_level_dir=str(TESTS_DIR.parent.parent),
        )
        discovered_e2e: dict[str, tuple[str, unittest.TestCase]] = {}
        for full_id, case in _iter_unittest_methods(suite):
            method_name = full_id.split(".")[-1]
            m = _E2E_METHOD_ID_RE.match(method_name)
            self.assertIsNotNone(m, f"E2E test method missing valid ID prefix: {full_id}")
            assert m is not None
            norm_id = m.group(1).replace("_", "-")
            self.assertNotIn(norm_id, discovered_e2e, f"Duplicate E2E test for {norm_id}")
            discovered_e2e[norm_id] = (full_id, case)

        # Discover all Flutter integration_test IDs
        flutter_audit = audit_integration_test_sources()
        flutter_ids: list[str] = flutter_audit["discovered_ids"]  # type: ignore[assignment]
        self.assertEqual(len(flutter_ids), len(set(flutter_ids)), "Duplicate Flutter test IDs found")
        discovered_flutter = set(flutter_ids)

        # Verify bi-directional parity with manifest
        expected_e2e = {e["id"]: e for e in entries if "e2e" in e["channels"]}
        expected_flutter = {e["id"]: e for e in entries if "integration_test" in e["channels"]}

        self.assertEqual(set(discovered_e2e.keys()), set(expected_e2e.keys()))
        self.assertEqual(discovered_flutter, set(expected_flutter.keys()))

        for tid, entry in expected_e2e.items():
            full_id, case = discovered_e2e[tid]
            self.assertEqual(getattr(case, "tier", None), entry["tier"], f"Tier attr mismatch on {full_id}")
            self.assertTrue(full_id.endswith(entry["e2e_symbol"]), f"{full_id} != {entry['e2e_symbol']}")
