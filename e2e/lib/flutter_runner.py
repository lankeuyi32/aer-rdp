"""Flutter integration_test runner and static Dart semantic-key/import auditor."""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .config import (
    ALLOWED_FLUTTER_TEST_IMPORT_PREFIXES,
    FORBIDDEN_FLUTTER_TEST_IMPORTS,
    INTEGRATION_TEST_DIR,
    REPO_ROOT,
)

_IMPORT_RE = re.compile(r"""^\s*import\s+['"]([^'"]+)['"]\s*;""", re.MULTILINE)
_VALUE_KEY_RE = re.compile(r"""ValueKey(?:<String>)?\(\s*['"]([a-z0-9_]+)['"]\s*\)""")
_AER_KEY_DECL_RE = re.compile(
    r"""static\s+const\s+ValueKey<String>\s+([A-Za-z0-9_]+)\s*=\s*ValueKey<String>\(\s*['"]([a-z0-9_]+)['"]\s*\)\s*;""",
    re.MULTILINE,
)
_AER_KEY_REF_RE = re.compile(r"""\bAerKeys\.([A-Za-z0-9_]+)\b""")
_TEST_WIDGETS_RE = re.compile(r"""testWidgets\(\s*['"]([^'"]+)['"]""")
_TEST_ID_PREFIX_RE = re.compile(r"""^(T[12]-FA\d{2}-\d{2}|T[34]-\d{2})\b""")


@dataclass
class FlutterRunResult:
    returncode: int
    stdout: str
    stderr: str
    command: list[str]


def flutter_executable() -> str | None:
    return shutil.which("flutter")


def _decode_output(data: str | bytes | None) -> str:
    if data is None:
        return ""
    if isinstance(data, bytes):
        return data.decode("utf-8", errors="replace")
    return data


def _run_flutter_subprocess(cmd: list[str], *, timeout: float) -> FlutterRunResult:
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        out = _decode_output(exc.stdout)
        err = _decode_output(exc.stderr)
        timeout_msg = f"Command timed out after {timeout}s: {' '.join(cmd)}"
        combined_err = f"{err}\n{timeout_msg}".strip() if err else timeout_msg
        return FlutterRunResult(
            returncode=124,
            stdout=out,
            stderr=combined_err,
            command=cmd,
        )
    return FlutterRunResult(
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        command=cmd,
    )


def run_flutter_integration_tests(
    *,
    files: list[Path] | None = None,
    device: str | None = None,
    timeout: float = 180.0,
) -> FlutterRunResult:
    exe = flutter_executable()
    if exe is None:
        return FlutterRunResult(
            returncode=127,
            stdout="",
            stderr="flutter executable not found in PATH",
            command=["flutter"],
        )

    targets = [str(p.relative_to(REPO_ROOT)) for p in (files or sorted(INTEGRATION_TEST_DIR.glob("*_test.dart")))]
    target_device = device or "flutter-tester"
    cmd = [exe, "test", *targets, "-d", target_device]
    return _run_flutter_subprocess(cmd, timeout=timeout)


def run_flutter_analyze(timeout: float = 120.0) -> FlutterRunResult:
    exe = flutter_executable()
    if exe is None:
        return FlutterRunResult(
            returncode=127,
            stdout="",
            stderr="flutter executable not found in PATH",
            command=["flutter", "analyze"],
        )
    pkg_cfg = REPO_ROOT / ".dart_tool" / "package_config.json"
    if not pkg_cfg.is_file():
        pub_get = _run_flutter_subprocess([exe, "pub", "get"], timeout=timeout)
        if pub_get.returncode != 0:
            return pub_get
    cmd = [exe, "analyze"]
    return _run_flutter_subprocess(cmd, timeout=timeout)


def audit_integration_test_sources() -> dict[str, object]:
    """Statically parse integration_test/*.dart for IDs, ValueKeys, and import hygiene."""
    dart_files = sorted(INTEGRATION_TEST_DIR.glob("*.dart"))
    discovered_ids: list[str] = []
    id_locations: dict[str, str] = {}
    referenced_keys: set[str] = set()
    tier_referenced_keys: set[str] = set()
    aer_key_map: dict[str, str] = {}
    forbidden_imports: list[str] = []
    unexpected_imports: list[str] = []

    helpers_path = INTEGRATION_TEST_DIR / "ui_test_helpers.dart"
    if helpers_path.is_file():
        helpers_text = helpers_path.read_text(encoding="utf-8")
        for const_name, key_str in _AER_KEY_DECL_RE.findall(helpers_text):
            aer_key_map[const_name] = key_str

    for path in dart_files:
        text = path.read_text(encoding="utf-8")
        for imp in _IMPORT_RE.findall(text):
            if any(imp.startswith(bad) for bad in FORBIDDEN_FLUTTER_TEST_IMPORTS):
                forbidden_imports.append(f"{path.name}: {imp}")
            elif not any(imp.startswith(ok) for ok in ALLOWED_FLUTTER_TEST_IMPORT_PREFIXES):
                unexpected_imports.append(f"{path.name}: {imp}")

        for key in _VALUE_KEY_RE.findall(text):
            referenced_keys.add(key)
            if path.name.startswith("tier"):
                tier_referenced_keys.add(key)

        if path.name.startswith("tier"):
            for const_name in _AER_KEY_REF_RE.findall(text):
                if const_name in aer_key_map:
                    tier_referenced_keys.add(aer_key_map[const_name])

        for desc in _TEST_WIDGETS_RE.findall(text):
            m = _TEST_ID_PREFIX_RE.match(desc)
            if m:
                tid = m.group(1)
                discovered_ids.append(tid)
                id_locations[tid] = path.name

    return {
        "files": [p.name for p in dart_files],
        "discovered_ids": discovered_ids,
        "id_locations": id_locations,
        "referenced_keys": sorted(referenced_keys),
        "tier_referenced_keys": sorted(tier_referenced_keys),
        "forbidden_imports": forbidden_imports,
        "unexpected_imports": unexpected_imports,
    }
