"""Shared fixtures and base TestCase for Tier 1-4 E2E wire tests."""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from typing import Any

from e2e.lib.config import FIXTURES_DIR, resolve_cli_bin, resolve_server_bin
from e2e.lib.harness import CliRunResult, RdpTestServerProcess, run_aer_rdp_cli
from e2e.lib.schema import validate_cli_report


class WireE2ETestCase(unittest.TestCase):
    """Base TestCase providing real rdp-test-server and aer-rdp-cli helpers."""

    tier: int = 0
    feature_area: str = ""

    @classmethod
    def server_bin(cls) -> Path | None:
        return resolve_server_bin()

    @classmethod
    def cli_bin(cls) -> Path | None:
        return resolve_cli_bin()

    def start_server(
        self,
        *,
        auth: str = "nla",
        user: str = "testuser",
        password: str = "testpass",
        domain: str = "",
        audio_hz: int = 440,
        rdpsnd_version: int = 8,
        extra_args: list[str] | None = None,
    ) -> RdpTestServerProcess:
        srv = RdpTestServerProcess(
            server_bin=self.server_bin(),
            auth=auth,
            user=user,
            password=password,
            domain=domain,
            audio_hz=audio_hz,
            rdpsnd_version=rdpsnd_version,
            extra_args=extra_args,
        )
        srv.start()
        self.addCleanup(srv.stop)
        return srv

    def run_cli(
        self,
        *,
        host: str = "127.0.0.1",
        port: int,
        actions: list[dict[str, Any]],
        auth: str = "auto",
        user: str = "testuser",
        password: str = "testpass",
        domain: str = "",
        width: int = 1280,
        height: int = 720,
        audio: str = "local",
        trust_cert: str = "any",
        timeout: float = 20.0,
        validate_report_schema: bool = True,
    ) -> CliRunResult:
        res = run_aer_rdp_cli(
            host=host,
            port=port,
            actions=actions,
            cli_bin=self.cli_bin(),
            auth=auth,
            user=user,
            password=password,
            domain=domain,
            width=width,
            height=height,
            audio=audio,
            trust_cert=trust_cert,
            timeout=timeout,
        )
        if validate_report_schema and res.report is not None:
            errs = validate_cli_report(res.report)
            self.assertEqual(errs, [], f"Invalid CLI report schema: {errs}\nReport: {res.report}")
        return res

    def assert_clean_disconnect_report(self, res: CliRunResult) -> dict[str, Any]:
        """Assert client did not crash/hang and wrote a valid Disconnected JSON report."""
        self.assertFalse(res.timed_out, f"Client timed out: {res.stderr}")
        self.assertGreaterEqual(
            res.returncode,
            0,
            f"Client terminated by signal {res.returncode}: {res.stderr}",
        )
        self.assertLess(
            res.returncode,
            128,
            f"Client crashed with signal-like exit code {res.returncode}: {res.stderr}",
        )
        self.assertIsNotNone(
            res.report,
            f"Client crashed without JSON report (rc={res.returncode}): {res.stderr}",
        )
        assert res.report is not None
        errs = validate_cli_report(res.report)
        self.assertEqual(errs, [], f"Invalid CLI report schema: {errs}\nReport: {res.report}")
        self.assertEqual(res.report["finalState"], "Disconnected")
        return res.report

    def load_fixture(self, name: str) -> Any:
        return json.loads((FIXTURES_DIR / name).read_text(encoding="utf-8"))
