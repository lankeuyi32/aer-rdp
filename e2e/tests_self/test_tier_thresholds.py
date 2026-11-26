"""SELF-02: Tier minimum thresholds and 100% Feature Inventory coverage."""

from __future__ import annotations

import json
import unittest

from e2e.lib.config import (
    EXPECTED_FEATURE_AREA_COUNT,
    FEATURE_AREAS,
    FEATURE_IDS,
    MANIFEST_PATH,
    TIER_MINIMUMS,
    TOTAL_MINIMUM,
)


class TestSelf02TierThresholds(unittest.TestCase):
    def test_SELF_02_thresholds_and_feature_coverage(self) -> None:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        areas = manifest.get("feature_areas", [])
        self.assertEqual(tuple(areas), FEATURE_AREAS)
        self.assertGreaterEqual(len(areas), 8)
        self.assertLessEqual(len(areas), 12)
        self.assertEqual(len(areas), EXPECTED_FEATURE_AREA_COUNT)

        entries = manifest.get("tests", [])
        tier_counts = {1: 0, 2: 0, 3: 0, 4: 0}
        t1_by_fa = {fa: 0 for fa in FEATURE_AREAS}
        t2_by_fa = {fa: 0 for fa in FEATURE_AREAS}
        t1_features: set[str] = set()
        t2_features: set[str] = set()

        for entry in entries:
            tier = entry["tier"]
            fa = entry["feature_area"]
            tier_counts[tier] += 1
            if tier == 1:
                t1_by_fa[fa] += 1
                t1_features.update(entry["features"])
            elif tier == 2:
                t2_by_fa[fa] += 1
                t2_features.update(entry["features"])

        for tier, minimum in TIER_MINIMUMS.items():
            self.assertGreaterEqual(
                tier_counts[tier],
                minimum,
                f"Tier {tier} count {tier_counts[tier]} below threshold {minimum}",
            )
        self.assertGreaterEqual(sum(tier_counts.values()), TOTAL_MINIMUM)

        # Every Feature Area must have >= 5 tests in Tier 1 and >= 5 tests in Tier 2
        for fa in FEATURE_AREAS:
            self.assertGreaterEqual(t1_by_fa[fa], 5, f"Tier 1 {fa} count < 5")
            self.assertGreaterEqual(t2_by_fa[fa], 5, f"Tier 2 {fa} count < 5")

        # 100% of Features F01..F32 + F34 covered in both Tier 1 and Tier 2
        self.assertEqual(t1_features, set(FEATURE_IDS))
        self.assertEqual(t2_features, set(FEATURE_IDS))
