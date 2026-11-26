"""Strict opaque-box schema validators (Python 3.12 stdlib only) for aer-rdp E2E."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from .config import (
    AER_RDP_CLI_ACTIONS,
    AER_RDP_CLI_REPORT_FIELDS,
    PROFILE_AUDIO_MODES,
    PROFILE_AUTH_MODES,
    PROFILE_DISPLAY_MODES,
    PROFILE_INPUT_MODES,
    PROFILE_ORIENTATION_LOCKS,
    PROFILE_SCHEMA_VERSION,
    PROFILE_SECURITY_MODES,
    PROFILE_TEXT_INPUT_MODES,
)

_SHA256_HEX_RE = re.compile(r"^[0-9a-fA-F]{64}$")
_FORBIDDEN_SECRET_FIELDS = frozenset(
    {"password", "secret", "pass", "plaintextPassword", "token", "passwd", "privateKey"}
)
_REQUIRED_PROFILE_FIELDS = (
    "id",
    "name",
    "host",
    "port",
    "username",
    "domain",
    "authMode",
    "securityMode",
    "displayConfig",
    "audioConfig",
    "inputConfig",
    "favorite",
    "lastConnectedAt",
)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_valid_sha256_hex(value: Any) -> bool:
    return isinstance(value, str) and bool(_SHA256_HEX_RE.match(value))


def validate_profiles_payload(payload: Any) -> list[str]:
    """Validate a Profile JSON Schema v1 payload. Returns list of error messages."""
    errors: list[str] = []
    if not isinstance(payload, dict):
        return ["Top-level payload must be a JSON object."]

    version = payload.get("version")
    if not _is_int(version) or version != PROFILE_SCHEMA_VERSION:
        errors.append(f"Unsupported or missing schema version: {version!r} (expected {PROFILE_SCHEMA_VERSION}).")

    profiles = payload.get("profiles")
    if not isinstance(profiles, list):
        errors.append("Missing or non-list 'profiles' field.")
        return errors

    seen_ids: set[str] = set()
    for idx, profile in enumerate(profiles):
        prefix = f"profiles[{idx}]"
        if not isinstance(profile, dict):
            errors.append(f"{prefix}: must be a JSON object.")
            continue

        for secret_key in _FORBIDDEN_SECRET_FIELDS:
            if secret_key in profile and profile[secret_key] not in (None, ""):
                errors.append(f"{prefix}: plaintext secret field {secret_key!r} must not be exported.")

        for req in _REQUIRED_PROFILE_FIELDS:
            if req not in profile:
                errors.append(f"{prefix}: missing required field {req!r}.")

        pid = profile.get("id")
        if not isinstance(pid, str) or not pid.strip():
            errors.append(f"{prefix}.id: must be a non-empty string.")
        elif pid in seen_ids:
            errors.append(f"{prefix}.id: duplicate profile id {pid!r}.")
        else:
            seen_ids.add(pid)

        name = profile.get("name")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{prefix}.name: must be a non-empty string.")

        host = profile.get("host")
        if not isinstance(host, str) or not host.strip():
            errors.append(f"{prefix}.host: must be a non-empty string.")

        port = profile.get("port")
        if not _is_int(port) or not (1 <= port <= 65535):
            errors.append(f"{prefix}.port: must be an integer in [1, 65535], got {port!r}.")

        for str_field in ("username", "domain"):
            if str_field in profile and not isinstance(profile[str_field], str):
                errors.append(f"{prefix}.{str_field}: must be a string.")

        auth_mode = profile.get("authMode")
        if auth_mode not in PROFILE_AUTH_MODES:
            errors.append(f"{prefix}.authMode: invalid {auth_mode!r}, expected {sorted(PROFILE_AUTH_MODES)}.")

        sec_mode = profile.get("securityMode")
        if sec_mode not in PROFILE_SECURITY_MODES:
            errors.append(f"{prefix}.securityMode: invalid {sec_mode!r}, expected {sorted(PROFILE_SECURITY_MODES)}.")

        display = profile.get("displayConfig")
        if not isinstance(display, dict):
            errors.append(f"{prefix}.displayConfig: must be an object.")
        else:
            if display.get("mode") not in PROFILE_DISPLAY_MODES:
                errors.append(f"{prefix}.displayConfig.mode: invalid {display.get('mode')!r}.")
            width = display.get("width")
            height = display.get("height")
            if not _is_int(width) or not (1 <= width <= 16384):
                errors.append(f"{prefix}.displayConfig.width: must be integer in [1, 16384], got {width!r}.")
            if not _is_int(height) or not (1 <= height <= 16384):
                errors.append(f"{prefix}.displayConfig.height: must be integer in [1, 16384], got {height!r}.")
            scale = display.get("scale")
            if not _is_number(scale) or not (0.25 <= float(scale) <= 8.0):
                errors.append(f"{prefix}.displayConfig.scale: must be number in [0.25, 8.0], got {scale!r}.")
            if display.get("orientationLock") not in PROFILE_ORIENTATION_LOCKS:
                errors.append(f"{prefix}.displayConfig.orientationLock: invalid {display.get('orientationLock')!r}.")

        audio = profile.get("audioConfig")
        if not isinstance(audio, dict):
            errors.append(f"{prefix}.audioConfig: must be an object.")
        elif audio.get("mode") not in PROFILE_AUDIO_MODES:
            errors.append(f"{prefix}.audioConfig.mode: invalid {audio.get('mode')!r}.")

        inp = profile.get("inputConfig")
        if not isinstance(inp, dict):
            errors.append(f"{prefix}.inputConfig: must be an object.")
        else:
            if inp.get("defaultMode") not in PROFILE_INPUT_MODES:
                errors.append(f"{prefix}.inputConfig.defaultMode: invalid {inp.get('defaultMode')!r}.")
            if not isinstance(inp.get("swapButtons"), bool):
                errors.append(f"{prefix}.inputConfig.swapButtons: must be a boolean.")
            if inp.get("textInputMode") not in PROFILE_TEXT_INPUT_MODES:
                errors.append(f"{prefix}.inputConfig.textInputMode: invalid {inp.get('textInputMode')!r}.")

        if "favorite" in profile and not isinstance(profile["favorite"], bool):
            errors.append(f"{prefix}.favorite: must be a boolean.")

        last_conn = profile.get("lastConnectedAt")
        if last_conn is not None:
            if not isinstance(last_conn, str) or not last_conn.strip():
                errors.append(f"{prefix}.lastConnectedAt: must be null or non-empty ISO-8601 timestamp string.")
            elif "T" not in last_conn and ":" not in last_conn:
                errors.append(f"{prefix}.lastConnectedAt: invalid ISO-8601 timestamp {last_conn!r}.")
            else:
                try:
                    datetime.fromisoformat(last_conn)
                except ValueError:
                    errors.append(f"{prefix}.lastConnectedAt: invalid ISO-8601 timestamp {last_conn!r}.")

    return errors


def validate_cli_script(script: Any) -> list[str]:
    """Validate an aer-rdp-cli scripted action list."""
    errors: list[str] = []
    if isinstance(script, dict) and "actions" in script:
        actions = script["actions"]
    elif isinstance(script, list):
        actions = script
    else:
        return ["CLI script must be a JSON array of action objects (or {'actions': [...]})"]

    if not isinstance(actions, list) or not actions:
        return ["CLI script actions list must be non-empty."]

    for idx, step in enumerate(actions):
        prefix = f"actions[{idx}]"
        if not isinstance(step, dict):
            errors.append(f"{prefix}: must be an object.")
            continue
        act = step.get("action")
        if act not in AER_RDP_CLI_ACTIONS:
            errors.append(f"{prefix}.action: unknown action {act!r}.")
            continue
        if act == "pointer":
            if not _is_int(step.get("x")) or not _is_int(step.get("y")):
                errors.append(f"{prefix}: pointer requires integer 'x' and 'y'.")
            if "buttonMask" in step and not _is_int(step["buttonMask"]):
                errors.append(f"{prefix}.buttonMask: must be integer.")
            if "down" in step and not isinstance(step["down"], bool):
                errors.append(f"{prefix}.down: must be boolean.")
            if "wheelDelta" in step and not _is_int(step["wheelDelta"]):
                errors.append(f"{prefix}.wheelDelta: must be integer.")
        elif act == "scancode":
            if not _is_int(step.get("code")):
                errors.append(f"{prefix}: scancode requires integer 'code'.")
            if not isinstance(step.get("extended"), bool):
                errors.append(f"{prefix}: scancode requires boolean 'extended'.")
            if not isinstance(step.get("down"), bool):
                errors.append(f"{prefix}: scancode requires boolean 'down'.")
        elif act == "unicode":
            has_text = isinstance(step.get("text"), str)
            has_unit = _is_int(step.get("codeUnit"))
            if not (has_text or has_unit):
                errors.append(f"{prefix}: unicode requires string 'text' or integer 'codeUnit'.")
        elif act == "drain_audio":
            dur = step.get("durationMs")
            if not _is_int(dur) or dur < 0:
                errors.append(f"{prefix}: drain_audio requires non-negative integer 'durationMs'.")
        elif act == "set_mute":
            if not isinstance(step.get("muted"), bool):
                errors.append(f"{prefix}: set_mute requires boolean 'muted'.")
        elif act == "set_volume":
            vol = step.get("volume")
            if not _is_number(vol):
                errors.append(f"{prefix}: set_volume requires numeric 'volume'.")

    return errors


def validate_cli_report(report: Any) -> list[str]:
    """Validate aer-rdp-cli JSON output report against PROJECT.md § Interface Contracts (d)."""
    errors: list[str] = []
    if not isinstance(report, dict):
        return ["CLI report must be a JSON object."]

    for field in AER_RDP_CLI_REPORT_FIELDS:
        if field not in report:
            errors.append(f"Missing required report field {field!r}.")

    if "connected" in report and not isinstance(report["connected"], bool):
        errors.append("'connected' must be boolean.")
    if "finalState" in report and not isinstance(report["finalState"], str):
        errors.append("'finalState' must be string.")
    if "certSha256" in report and report["certSha256"] is not None:
        if not is_valid_sha256_hex(report["certSha256"]):
            errors.append(f"'certSha256' must be null or 64-hex string, got {report['certSha256']!r}.")
    for int_field in ("width", "height", "framesReceived", "audioFramesRead", "audioDrops", "waveConfirmsSent"):
        if int_field in report and (not _is_int(report[int_field]) or report[int_field] < 0):
            errors.append(f"{int_field!r} must be a non-negative integer.")
    for num_field in ("audioQueuedMs", "audioDriftMs"):
        if num_field in report and not _is_number(report[num_field]):
            errors.append(f"{num_field!r} must be numeric.")
    if "framebufferSha256" in report and report["framebufferSha256"] is not None:
        if not is_valid_sha256_hex(report["framebufferSha256"]):
            errors.append("'framebufferSha256' must be null or 64-hex string.")
    if "disconnectReason" in report and report["disconnectReason"] is not None:
        if not isinstance(report["disconnectReason"], str):
            errors.append("'disconnectReason' must be null or string.")
    if "errors" in report:
        errs = report["errors"]
        if not isinstance(errs, list) or not all(isinstance(item, str) for item in errs):
            errors.append("'errors' must be a list of strings.")

    return errors
