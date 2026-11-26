"""Process, HTTP control, and TLS probe harness for rdp-test-server & aer-rdp-cli."""

from __future__ import annotations

import hashlib
import json
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import DEFAULT_ARTIFACTS_DIR, resolve_cli_bin, resolve_server_bin


class MissingBinaryError(RuntimeError):
    """Raised in live mode when rdp-test-server or aer-rdp-cli binary is unavailable."""


def find_free_port(host: str = "127.0.0.1") -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind((host, 0))
        return int(s.getsockname()[1])


def _scratch_dir() -> Path:
    d = DEFAULT_ARTIFACTS_DIR / "tmp"
    d.mkdir(parents=True, exist_ok=True)
    return d


@dataclass
class HttpResponse:
    status: int
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))


@dataclass
class CliRunResult:
    returncode: int
    stdout: str
    stderr: str
    report: dict[str, Any] | None
    timed_out: bool = False
    command: list[str] | None = None


class RdpTestServerProcess:
    """Manages an isolated rdp-test-server subprocess and its HTTP control API."""

    def __init__(
        self,
        *,
        server_bin: Path | None = None,
        auth: str = "nla",
        user: str = "testuser",
        password: str = "testpass",
        domain: str = "",
        audio_hz: int = 440,
        rdpsnd_version: int = 8,
        startup_timeout: float = 10.0,
        extra_args: list[str] | None = None,
    ) -> None:
        resolved = server_bin if server_bin is not None else resolve_server_bin()
        if resolved is None or not resolved.exists():
            raise MissingBinaryError(
                "rdp-test-server binary not found (set AER_RDP_SERVER_BIN or --rdp-server-bin)."
            )
        self.server_bin = resolved
        self.auth = auth
        self.user = user
        self.password = password
        self.domain = domain
        self.audio_hz = audio_hz
        self.rdpsnd_version = rdpsnd_version
        self.startup_timeout = startup_timeout
        self.extra_args = list(extra_args or [])

        self.rdp_port = find_free_port()
        self.http_port = find_free_port()
        while self.http_port == self.rdp_port:
            self.http_port = find_free_port()

        self.proc: subprocess.Popen[str] | None = None
        self.stdout_text = ""
        self.stderr_text = ""

    @property
    def http_base_url(self) -> str:
        return f"http://127.0.0.1:{self.http_port}"

    def __enter__(self) -> RdpTestServerProcess:
        self.start()
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.stop()

    def start(self) -> dict[str, Any]:
        cmd = [
            str(self.server_bin),
            "--bind",
            f"127.0.0.1:{self.rdp_port}",
            "--auth",
            self.auth,
            "--user",
            self.user,
            "--pass",
            self.password,
            "--domain",
            self.domain,
            "--audio-hz",
            str(self.audio_hz),
            "--rdpsnd-version",
            str(self.rdpsnd_version),
            "--control-http",
            f"127.0.0.1:{self.http_port}",
            *self.extra_args,
        ]
        self.proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        deadline = time.monotonic() + self.startup_timeout
        last_err: Exception | None = None
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                out, err = self.proc.communicate(timeout=2.0)
                self.stdout_text, self.stderr_text = out, err
                raise RuntimeError(
                    f"rdp-test-server exited prematurely ({self.proc.returncode}): {err.strip()}"
                )
            try:
                data = self.health()
                if data.get("ok") is True:
                    return data
            except Exception as exc:
                last_err = exc
            time.sleep(0.05)

        self.stop()
        raise TimeoutError(f"rdp-test-server failed health check within {self.startup_timeout}s: {last_err}")

    def stop(self) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                out, err = self.proc.communicate(timeout=3.0)
                self.stdout_text, self.stderr_text = out, err
            except subprocess.TimeoutExpired:
                if sys.platform.startswith("win"):
                    subprocess.run(
                        ["taskkill", "/PID", str(self.proc.pid), "/T", "/F"],
                        capture_output=True,
                        check=False,
                    )
                    try:
                        out, err = self.proc.communicate(timeout=2.0)
                        self.stdout_text, self.stderr_text = out, err
                    except subprocess.TimeoutExpired:
                        self.proc.kill()
                        out, err = self.proc.communicate(timeout=2.0)
                        self.stdout_text, self.stderr_text = out, err
                else:
                    self.proc.kill()
                    out, err = self.proc.communicate(timeout=2.0)
                    self.stdout_text, self.stderr_text = out, err
        else:
            try:
                out, err = self.proc.communicate(timeout=1.0)
                self.stdout_text, self.stderr_text = out, err
            except Exception:
                pass
        self.proc = None

    def raw_http(self, method: str, path: str, body: bytes | None = None, timeout: float = 5.0) -> HttpResponse:
        url = f"{self.http_base_url}{path}"
        req = urllib.request.Request(url, data=body, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return HttpResponse(status=int(resp.status), body=resp.read())
        except urllib.error.HTTPError as err:
            return HttpResponse(status=int(err.code), body=err.read())

    def health(self) -> dict[str, Any]:
        resp = self.raw_http("GET", "/health")
        if resp.status != 200:
            raise RuntimeError(f"GET /health failed: HTTP {resp.status}")
        return dict(resp.json())

    def metrics(self) -> dict[str, Any]:
        resp = self.raw_http("GET", "/metrics")
        if resp.status != 200:
            raise RuntimeError(f"GET /metrics failed: HTTP {resp.status}")
        return dict(resp.json())

    def inputs(self) -> dict[str, Any]:
        resp = self.raw_http("GET", "/inputs")
        if resp.status != 200:
            raise RuntimeError(f"GET /inputs failed: HTTP {resp.status}")
        return dict(resp.json())

    def trigger_deactivate(self) -> HttpResponse:
        return self.raw_http("POST", "/control/deactivate", body=b"{}")

    def trigger_disconnect(self) -> HttpResponse:
        return self.raw_http("POST", "/control/disconnect", body=b"{}")

    def trigger_frame(self) -> HttpResponse:
        return self.raw_http("POST", "/control/frame", body=b"{}")


def run_aer_rdp_cli(
    *,
    host: str,
    port: int,
    actions: list[dict[str, Any]],
    cli_bin: Path | None = None,
    auth: str = "auto",
    user: str = "testuser",
    password: str = "testpass",
    domain: str = "",
    width: int = 1280,
    height: int = 720,
    audio: str = "local",
    trust_cert: str = "any",
    timeout: float = 20.0,
) -> CliRunResult:
    resolved = cli_bin if cli_bin is not None else resolve_cli_bin()
    if resolved is None or not resolved.exists():
        raise MissingBinaryError(
            "aer-rdp-cli binary not found (set AER_RDP_CLI_BIN or --rdp-cli-bin)."
        )

    scratch = _scratch_dir()
    stamp = f"{int(time.time() * 1000)}_{find_free_port()}"
    run_dir = scratch / f"cli_{stamp}"
    run_dir.mkdir(parents=True, exist_ok=True)
    script_path = run_dir / "script.json"
    out_path = run_dir / "report.json"

    try:
        script_path.write_text(json.dumps(actions, indent=2), encoding="utf-8")
        cmd = [
            str(resolved),
            "--host",
            host,
            "--port",
            str(port),
            "--auth",
            auth,
            "--user",
            user,
            "--pass",
            password,
            "--domain",
            domain,
            "--width",
            str(width),
            "--height",
            str(height),
            "--audio",
            audio,
            "--trust-cert",
            trust_cert,
            "--script",
            str(script_path),
            "--out",
            str(out_path),
        ]
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                check=False,
            )
            report_data: dict[str, Any] | None = None
            if out_path.is_file():
                try:
                    report_data = json.loads(out_path.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    report_data = None
            return CliRunResult(
                returncode=proc.returncode,
                stdout=proc.stdout,
                stderr=proc.stderr,
                report=report_data,
                timed_out=False,
                command=cmd,
            )
        except subprocess.TimeoutExpired as exc:
            report_data = None
            if out_path.is_file():
                try:
                    report_data = json.loads(out_path.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    report_data = None
            return CliRunResult(
                returncode=124,
                stdout=(exc.stdout or "") if isinstance(exc.stdout, str) else "",
                stderr=(exc.stderr or "") if isinstance(exc.stderr, str) else "",
                report=report_data,
                timed_out=True,
                command=cmd,
            )
    finally:
        shutil.rmtree(run_dir, ignore_errors=True)


def probe_rdp_tls_cert_sha256(host: str, port: int, timeout: float = 5.0) -> str:
    """Perform TPKT+X.224 PROTOCOL_SSL handshake and return lowercase SHA-256 of TLS leaf cert."""
    # TPKT (len 19) + X.224 CR (len 14) + RDP_NEG_REQ (type=1, flags=0, len=8, protocols=PROTOCOL_SSL=1)
    x224_cr = bytes.fromhex("030000130ee000000000000100080001000000")
    with socket.create_connection((host, port), timeout=timeout) as raw_sock:
        raw_sock.settimeout(timeout)
        raw_sock.sendall(x224_cr)
        hdr = raw_sock.recv(4)
        if len(hdr) < 4 or hdr[0] != 0x03:
            raise RuntimeError(f"Invalid TPKT header from {host}:{port}: {hdr!r}")
        pkt_len = (hdr[2] << 8) | hdr[3]
        remaining = max(0, pkt_len - 4)
        payload = bytearray()
        while len(payload) < remaining:
            chunk = raw_sock.recv(remaining - len(payload))
            if not chunk:
                break
            payload.extend(chunk)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with ctx.wrap_socket(raw_sock, server_hostname=host) as tls_sock:
            der = tls_sock.getpeercert(binary_form=True)
            if not der:
                raise RuntimeError("Server did not present a TLS certificate")
            return hashlib.sha256(der).hexdigest().lower()
