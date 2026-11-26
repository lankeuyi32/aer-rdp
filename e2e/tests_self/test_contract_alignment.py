"""SELF-08: Verify all 31 Flutter ValueKeys, CLI flags/actions, HTTP endpoints, and Dart import hygiene."""

from __future__ import annotations

import unittest

from e2e.lib.config import (
    AER_RDP_CLI_ACTIONS,
    AER_RDP_CLI_FLAGS,
    CANONICAL_FLUTTER_KEYS,
    RDP_TEST_SERVER_ENDPOINTS,
    RDP_TEST_SERVER_FLAGS,
    TESTS_DIR,
)
from e2e.lib.flutter_runner import audit_integration_test_sources
from e2e.lib.harness import RdpTestServerProcess, run_aer_rdp_cli
import inspect


class TestSelf08ContractAlignment(unittest.TestCase):
    def test_SELF_08_all_31_canonical_flutter_keys_covered_and_hygienic(self) -> None:
        self.assertEqual(len(CANONICAL_FLUTTER_KEYS), 31)
        audit = audit_integration_test_sources()
        self.assertEqual(audit["forbidden_imports"], [], f"Forbidden Dart imports: {audit['forbidden_imports']}")
        self.assertEqual(audit["unexpected_imports"], [], f"Unexpected Dart imports: {audit['unexpected_imports']}")

        referenced = set(audit["referenced_keys"])  # type: ignore[arg-type]
        missing = sorted(set(CANONICAL_FLUTTER_KEYS) - referenced)
        self.assertEqual(missing, [], f"integration_test/ missing canonical ValueKeys: {missing}")

        tier_referenced = set(audit["tier_referenced_keys"])  # type: ignore[arg-type]
        missing_in_tiers = sorted(set(CANONICAL_FLUTTER_KEYS) - tier_referenced)
        self.assertEqual(
            missing_in_tiers,
            [],
            f"integration_test/tier*.dart never exercises canonical ValueKeys: {missing_in_tiers}",
        )

        extra = sorted(referenced - set(CANONICAL_FLUTTER_KEYS))
        self.assertEqual(extra, [], f"integration_test/ uses non-canonical ValueKeys: {extra}")

    def test_SELF_08_harness_covers_all_cli_and_server_contracts(self) -> None:
        srv_src = inspect.getsource(RdpTestServerProcess)
        for flag in RDP_TEST_SERVER_FLAGS:
            self.assertIn(flag, srv_src, f"harness.RdpTestServerProcess missing flag {flag}")
        for _, path in RDP_TEST_SERVER_ENDPOINTS:
            self.assertIn(path, srv_src, f"harness.RdpTestServerProcess missing endpoint {path}")

        cli_src = inspect.getsource(run_aer_rdp_cli)
        for flag in AER_RDP_CLI_FLAGS:
            self.assertIn(flag, cli_src, f"harness.run_aer_rdp_cli missing flag {flag}")

        wire_sources = "\n".join(p.read_text(encoding="utf-8") for p in sorted(TESTS_DIR.glob("test_tier*.py")))
        for act in AER_RDP_CLI_ACTIONS:
            self.assertIn(f'"{act}"', wire_sources, f"Wire tests never exercise CLI action {act!r}")
