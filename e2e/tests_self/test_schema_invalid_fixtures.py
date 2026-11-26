"""SELF-04: Malformed & boundary Profile JSON / CLI fixtures are cleanly rejected."""

from __future__ import annotations

import json
import unittest

from e2e.lib.config import FIXTURES_DIR
from e2e.lib.schema import validate_cli_report, validate_cli_script, validate_profiles_payload


class TestSelf04SchemaInvalidFixtures(unittest.TestCase):
    def test_SELF_04_invalid_profile_fixtures_rejected(self) -> None:
        data = json.loads((FIXTURES_DIR / "profiles_invalid.json").read_text(encoding="utf-8"))
        cases = data["cases"]
        self.assertGreaterEqual(len(cases), 6)
        for case in cases:
            errors = validate_profiles_payload(case["payload"])
            self.assertGreater(len(errors), 0, f"Invalid case {case['name']} unexpectedly passed")
            expected = case["expected_error_substring"]
            self.assertTrue(
                any(expected in err for err in errors),
                f"Case {case['name']} errors {errors} missing {expected!r}",
            )

    def test_SELF_04_invalid_cli_scripts_rejected(self) -> None:
        self.assertGreater(len(validate_cli_script([])), 0)
        self.assertGreater(len(validate_cli_script([{"action": "bogus_op"}])), 0)
        self.assertGreater(len(validate_cli_script([{"action": "pointer", "x": "1"}])), 0)
        self.assertGreater(len(validate_cli_script([{"action": "drain_audio", "durationMs": -5}])), 0)

    def test_SELF_04_invalid_cli_report_rejected(self) -> None:
        errs = validate_cli_report({"connected": "yes"})
        self.assertGreater(len(errs), 2)

    def test_SELF_04_extra_secret_fields_and_bad_timestamp_rejected(self) -> None:
        base = json.loads((FIXTURES_DIR / "profiles_valid.json").read_text(encoding="utf-8"))
        for secret_field in ("token", "passwd", "privateKey"):
            mutated = json.loads(json.dumps(base))
            mutated["profiles"][0][secret_field] = "leaked-value"
            errs = validate_profiles_payload(mutated)
            self.assertTrue(
                any("plaintext secret" in e for e in errs),
                f"Expected secret rejection for {secret_field!r}, got {errs}",
            )

        bad_ts = json.loads(json.dumps(base))
        bad_ts["profiles"][0]["lastConnectedAt"] = "not-a-timestamp"
        ts_errs = validate_profiles_payload(bad_ts)
        self.assertTrue(
            any("lastConnectedAt" in e for e in ts_errs),
            f"Expected ISO-8601 rejection for lastConnectedAt, got {ts_errs}",
        )
