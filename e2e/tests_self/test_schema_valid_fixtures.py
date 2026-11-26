"""SELF-03: Valid Profile JSON Schema v1 & aer-rdp-cli script fixtures pass validation."""

from __future__ import annotations

import json
import unittest

from e2e.lib.config import FIXTURES_DIR
from e2e.lib.schema import validate_cli_report, validate_cli_script, validate_profiles_payload


class TestSelf03SchemaValidFixtures(unittest.TestCase):
    def test_SELF_03_valid_profiles_fixture(self) -> None:
        payload = json.loads((FIXTURES_DIR / "profiles_valid.json").read_text(encoding="utf-8"))
        errors = validate_profiles_payload(payload)
        self.assertEqual(errors, [], f"Expected valid profile fixture, got errors: {errors}")

    def test_SELF_03_valid_cli_script_fixtures(self) -> None:
        script_files = sorted(FIXTURES_DIR.glob("scripts_*.json"))
        self.assertGreaterEqual(len(script_files), 3)
        for sf in script_files:
            data = json.loads(sf.read_text(encoding="utf-8"))
            errors = validate_cli_script(data)
            self.assertEqual(errors, [], f"{sf.name} failed script validation: {errors}")

    def test_SELF_03_valid_cli_report_shape(self) -> None:
        sample = {
            "connected": True,
            "finalState": "Disconnected",
            "certSha256": "a" * 64,
            "width": 1280,
            "height": 720,
            "framesReceived": 4,
            "framebufferSha256": "b" * 64,
            "audioFramesRead": 44100,
            "audioQueuedMs": 60.0,
            "audioDriftMs": 2.5,
            "audioDrops": 0,
            "waveConfirmsSent": 8,
            "disconnectReason": "client_requested",
            "errors": [],
        }
        self.assertEqual(validate_cli_report(sample), [])
