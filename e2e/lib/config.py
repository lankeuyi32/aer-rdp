"""Canonical interface contract constants & environment resolution for aer-rdp E2E tests."""

from __future__ import annotations

import os
import sys
from pathlib import Path

E2E_DIR: Path = Path(__file__).resolve().parents[1]
REPO_ROOT: Path = E2E_DIR.parent
MANIFEST_PATH: Path = E2E_DIR / "manifest.json"
FIXTURES_DIR: Path = E2E_DIR / "fixtures"
TESTS_DIR: Path = E2E_DIR / "tests"
SELF_TESTS_DIR: Path = E2E_DIR / "tests_self"
INTEGRATION_TEST_DIR: Path = REPO_ROOT / "integration_test"
DEFAULT_ARTIFACTS_DIR: Path = REPO_ROOT / "artifacts" / "e2e"

# 11 Feature Areas & Coverage Thresholds (PROJECT.md + test_matrix.md)
FEATURE_AREAS: tuple[str, ...] = tuple(f"FA{i:02d}" for i in range(1, 12))
EXPECTED_FEATURE_AREA_COUNT: int = 11
FEATURE_IDS: tuple[str, ...] = tuple(f"F{i:02d}" for i in range(1, 33)) + ("F34",)

TIER_MINIMUMS: dict[int, int] = {
    1: 5 * EXPECTED_FEATURE_AREA_COUNT,  # 55
    2: 5 * EXPECTED_FEATURE_AREA_COUNT,  # 55
    3: EXPECTED_FEATURE_AREA_COUNT,      # 11
    4: 6,                                # max(5, ceil(11/2)) = 6
}
TOTAL_MINIMUM: int = 11 * EXPECTED_FEATURE_AREA_COUNT + 6  # 127

# Canonical 31 Flutter UI Semantic ValueKeys (PROJECT.md § Interface Contracts (d))
CANONICAL_FLUTTER_KEYS: tuple[str, ...] = (
    # Connection Center (6)
    "connection_center_page",
    "add_profile_button",
    "quick_connect_button",
    "profile_search_field",
    "import_profiles_button",
    "export_profiles_button",
    # Profile Form (10)
    "profile_form_name",
    "profile_form_host",
    "profile_form_port",
    "profile_form_user",
    "profile_form_domain",
    "profile_form_password",
    "profile_form_security",
    "profile_form_audio",
    "profile_form_input_mode",
    "profile_form_save",
    # Dialogs (6)
    "cert_trust_dialog",
    "cert_trust_once",
    "cert_trust_always",
    "cert_reject",
    "auth_prompt_dialog",
    "auth_prompt_submit",
    # Session UI (9)
    "session_page",
    "session_canvas",
    "command_bar_pill",
    "command_bar_disconnect",
    "command_bar_input_mode",
    "command_bar_keyboard",
    "command_bar_mute",
    "command_bar_zoom_reset",
    "special_key_bar",
)

# rdp-test-server CLI & HTTP Contracts (PROJECT.md § Interface Contracts (c))
RDP_TEST_SERVER_FLAGS: tuple[str, ...] = (
    "--bind",
    "--auth",
    "--user",
    "--pass",
    "--domain",
    "--audio-hz",
    "--rdpsnd-version",
    "--control-http",
)

RDP_TEST_SERVER_ENDPOINTS: tuple[tuple[str, str], ...] = (
    ("GET", "/health"),
    ("GET", "/metrics"),
    ("GET", "/inputs"),
    ("POST", "/control/deactivate"),
    ("POST", "/control/disconnect"),
    ("POST", "/control/frame"),
)

RDP_TEST_SERVER_METRICS_FIELDS: tuple[str, ...] = (
    "framesSent",
    "audioBlocksSent",
    "audioBlocksConfirmed",
    "lastConfirmLatencyMs",
    "inFlightWindow",
    "activeSessions",
    "reactivations",
    "lastDisconnectReason",
)

RDP_TEST_SERVER_INPUT_KINDS: frozenset[str] = frozenset({"pointer", "scancode", "unicode"})

# aer-rdp-cli Contract (PROJECT.md § Interface Contracts (d))
AER_RDP_CLI_FLAGS: tuple[str, ...] = (
    "--host",
    "--port",
    "--auth",
    "--user",
    "--pass",
    "--domain",
    "--width",
    "--height",
    "--audio",
    "--trust-cert",
    "--script",
    "--out",
)

AER_RDP_CLI_ACTIONS: frozenset[str] = frozenset({
    "wait_active",
    "pointer",
    "scancode",
    "unicode",
    "drain_audio",
    "set_mute",
    "set_volume",
    "disconnect",
})

AER_RDP_CLI_REPORT_FIELDS: tuple[str, ...] = (
    "connected",
    "finalState",
    "certSha256",
    "width",
    "height",
    "framesReceived",
    "framebufferSha256",
    "audioFramesRead",
    "audioQueuedMs",
    "audioDriftMs",
    "audioDrops",
    "waveConfirmsSent",
    "disconnectReason",
    "errors",
)

# Profile JSON Schema v1 Constants
PROFILE_SCHEMA_VERSION: int = 1
PROFILE_AUTH_MODES: frozenset[str] = frozenset({"saved", "prompt"})
PROFILE_SECURITY_MODES: frozenset[str] = frozenset({"auto", "nla", "tls"})
PROFILE_DISPLAY_MODES: frozenset[str] = frozenset({"matchDevice", "custom"})
PROFILE_ORIENTATION_LOCKS: frozenset[str] = frozenset({"auto", "landscape", "portrait"})
PROFILE_AUDIO_MODES: frozenset[str] = frozenset({"local", "remote", "off"})
PROFILE_INPUT_MODES: frozenset[str] = frozenset({"directTouch", "pointer"})
PROFILE_TEXT_INPUT_MODES: frozenset[str] = frozenset({"scancode", "unicode"})

# Flutter integration_test allowed/forbidden imports.
# Note: `flutter test integration_test/` runs headless and on-device using `package:flutter_test/flutter_test.dart`.
# While `pubspec.yaml` lacks `integration_test: sdk: flutter` (M1/M2), `package:integration_test/` stays forbidden so
# `flutter analyze` cannot break; if M3/M5 adds `integration_test: sdk: flutter` and `IntegrationTestWidgetsFlutterBinding`
# in `ui_test_helpers.dart`, move `"package:integration_test/"` from FORBIDDEN to ALLOWED here (keeping `tier*.dart` on `flutter_test`).
ALLOWED_FLUTTER_TEST_IMPORT_PREFIXES: tuple[str, ...] = (
    "package:flutter/",
    "package:flutter_test/",
    "package:material_ui/",
    "package:aer_rdp/main.dart",
    "ui_test_helpers.dart",
)
FORBIDDEN_FLUTTER_TEST_IMPORTS: tuple[str, ...] = (
    "package:integration_test/",
    "package:aer_rdp/ui/",
    "package:aer_rdp/models/",
    "package:aer_rdp/services/",
)


def _exe_suffix() -> str:
    return ".exe" if sys.platform.startswith("win") else ""


def resolve_e2e_mode(explicit: str | None = None) -> str:
    mode = (explicit or os.environ.get("AER_RDP_E2E_MODE") or "live").strip().lower()
    if mode not in ("mock", "live"):
        raise ValueError(f"Unsupported E2E mode: {mode!r} (expected 'mock' or 'live')")
    return mode


def resolve_server_bin(explicit: str | None = None) -> Path | None:
    raw = explicit or os.environ.get("AER_RDP_SERVER_BIN")
    if raw:
        return Path(raw).expanduser()
    name = f"rdp-test-server{_exe_suffix()}"
    for profile in ("release", "debug"):
        candidate = REPO_ROOT / "target" / profile / name
        if candidate.is_file():
            return candidate
    return None


def resolve_cli_bin(explicit: str | None = None) -> Path | None:
    raw = explicit or os.environ.get("AER_RDP_CLI_BIN")
    if raw:
        return Path(raw).expanduser()
    name = f"aer-rdp-cli{_exe_suffix()}"
    for profile in ("release", "debug"):
        candidate = REPO_ROOT / "target" / profile / name
        if candidate.is_file():
            return candidate
    return None
