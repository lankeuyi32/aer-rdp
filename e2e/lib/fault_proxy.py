"""Deterministic opaque-box TCP fault-injection proxy for aer-rdp E2E tests."""

from __future__ import annotations

import select
import socket
import struct
import threading
import time
from typing import Literal

FaultMode = Literal[
    "passthrough",
    "jitter_stall",
    "starve",
    "fragment",
    "reset_after_bytes",
    "reset_after_secs",
    "tarpit",
    "corrupt_tpkt",
    "delayed_handshake",
]


class FaultProxy:
    """Thread-based localhost TCP proxy injecting deterministic wire faults."""

    def __init__(
        self,
        target_host: str,
        target_port: int,
        mode: FaultMode = "passthrough",
        *,
        chunk_size: int = 17,
        fragment_delay_ms: float = 0.0,
        stall_after_bytes: int = 4096,
        stall_after_secs: float | None = None,
        stall_duration_ms: int = 250,
        reset_after_bytes: int = 8192,
        reset_after_secs: float = 0.8,
        corrupt_offset: int = 0,
        delay_ms: int = 200,
    ) -> None:
        self.target_host = target_host
        self.target_port = target_port
        self.mode: FaultMode = mode
        self.chunk_size = max(1, chunk_size)
        self.fragment_delay_ms = max(0.0, fragment_delay_ms)
        self.stall_after_bytes = max(0, stall_after_bytes)
        self.stall_after_secs = max(0.0, stall_after_secs) if stall_after_secs is not None else None
        self.stall_duration_ms = max(0, stall_duration_ms)
        self.reset_after_bytes = max(0, reset_after_bytes)
        self.reset_after_secs = max(0.05, reset_after_secs)
        self.corrupt_offset = max(0, corrupt_offset)
        self.delay_ms = max(0, delay_ms)

        self._listen_sock: socket.socket | None = None
        self._stop_event = threading.Event()
        self._accept_thread: threading.Thread | None = None
        self._worker_threads: list[threading.Thread] = []
        self._active_sockets: list[socket.socket] = []
        self._lock = threading.Lock()

        self.host = "127.0.0.1"
        self.port = 0
        self.connections_accepted = 0
        self.bytes_client_to_server = 0
        self.bytes_server_to_client = 0
        self.fault_triggered = False

    def __enter__(self) -> FaultProxy:
        self.start()
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.stop()

    def start(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.host, 0))
        sock.listen(16)
        sock.settimeout(0.2)
        self._listen_sock = sock
        self.port = int(sock.getsockname()[1])
        self._stop_event.clear()
        self._accept_thread = threading.Thread(
            target=self._accept_loop, name=f"fault-proxy-{self.port}", daemon=True
        )
        self._accept_thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._listen_sock is not None:
            try:
                self._listen_sock.close()
            except OSError:
                pass
            self._listen_sock = None
        with self._lock:
            socks = list(self._active_sockets)
            self._active_sockets.clear()
        for s in socks:
            try:
                s.close()
            except OSError:
                pass
        if self._accept_thread is not None:
            self._accept_thread.join(timeout=2.0)
            self._accept_thread = None
        with self._lock:
            workers = list(self._worker_threads)
            self._worker_threads.clear()
        for t in workers:
            t.join(timeout=2.0)

    def _track_sock(self, sock: socket.socket) -> None:
        with self._lock:
            self._active_sockets.append(sock)

    def _accept_loop(self) -> None:
        assert self._listen_sock is not None
        while not self._stop_event.is_set():
            try:
                client_sock, _ = self._listen_sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connections_accepted += 1
            self._track_sock(client_sock)
            t = threading.Thread(
                target=self._handle_client,
                args=(client_sock,),
                name=f"fault-proxy-conn-{self.connections_accepted}",
                daemon=True,
            )
            with self._lock:
                self._worker_threads.append(t)
            t.start()

    def _force_rst(self, sock: socket.socket) -> None:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass

    def _handle_client(self, client_sock: socket.socket) -> None:
        if self.mode == "tarpit":
            self.fault_triggered = True
            while not self._stop_event.is_set():
                time.sleep(0.05)
            try:
                client_sock.close()
            except OSError:
                pass
            return

        upstream_sock: socket.socket | None = None
        try:
            upstream_sock = socket.create_connection((self.target_host, self.target_port), timeout=5.0)
            self._track_sock(upstream_sock)
            client_sock.setblocking(False)
            upstream_sock.setblocking(False)
            client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            upstream_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

            started_at = time.monotonic()
            s2c_bytes = 0
            stalled_once = False
            corrupted_once = False
            delayed_once = False

            while not self._stop_event.is_set():
                if self.mode == "reset_after_secs" and (time.monotonic() - started_at) >= self.reset_after_secs:
                    self.fault_triggered = True
                    self._force_rst(client_sock)
                    self._force_rst(upstream_sock)
                    return

                readable, _, exceptional = select.select(
                    [client_sock, upstream_sock], [], [client_sock, upstream_sock], 0.05
                )
                if exceptional:
                    return

                for sock in readable:
                    try:
                        data = sock.recv(16384)
                    except BlockingIOError:
                        continue
                    except OSError:
                        return
                    if not data:
                        return

                    if sock is client_sock:
                        self.bytes_client_to_server += len(data)
                        if self.mode == "delayed_handshake" and not delayed_once:
                            delayed_once = True
                            self.fault_triggered = True
                            time.sleep(self.delay_ms / 1000.0)
                        self._send_all(upstream_sock, data)
                    else:
                        s2c_bytes += len(data)
                        self.bytes_server_to_client += len(data)

                        if self.mode == "corrupt_tpkt" and not corrupted_once and s2c_bytes >= self.corrupt_offset:
                            corrupted_once = True
                            self.fault_triggered = True
                            mutated = bytearray(data)
                            if len(mutated) >= 4:
                                # Invalid TPKT version 0xFF and bogus length 0xFFFF
                                mutated[0] = 0xFF
                                mutated[2] = 0xFF
                                mutated[3] = 0xFF
                            elif mutated:
                                mutated[0] ^= 0xFF
                            self._send_all(client_sock, bytes(mutated))
                            continue

                        if self.mode == "reset_after_bytes" and s2c_bytes >= self.reset_after_bytes:
                            self.fault_triggered = True
                            self._force_rst(client_sock)
                            self._force_rst(upstream_sock)
                            return

                        if self.mode in ("jitter_stall", "starve") and not stalled_once:
                            elapsed_ok = (
                                self.stall_after_secs is None
                                or (time.monotonic() - started_at) >= self.stall_after_secs
                            )
                            if elapsed_ok and s2c_bytes >= self.stall_after_bytes:
                                stalled_once = True
                                self.fault_triggered = True
                                time.sleep(self.stall_duration_ms / 1000.0)

                        if self.mode == "fragment":
                            self.fault_triggered = True
                            for i in range(0, len(data), self.chunk_size):
                                self._send_all(client_sock, data[i : i + self.chunk_size])
                                if self.fragment_delay_ms > 0.0:
                                    time.sleep(self.fragment_delay_ms / 1000.0)
                        else:
                            self._send_all(client_sock, data)
        except OSError:
            pass
        finally:
            for s in (client_sock, upstream_sock):
                if s is not None:
                    try:
                        s.close()
                    except OSError:
                        pass

    def _send_all(self, sock: socket.socket, data: bytes) -> None:
        view = memoryview(data)
        sent = 0
        while sent < len(view) and not self._stop_event.is_set():
            try:
                n = sock.send(view[sent:])
                if n <= 0:
                    raise OSError("socket send returned 0")
                sent += n
            except BlockingIOError:
                select.select([], [sock], [], 0.05)
