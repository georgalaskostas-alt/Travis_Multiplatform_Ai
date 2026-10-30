#!/usr/bin/env python3
"""TRAVIS local voice broker.

A tiny localhost-only broker that keeps the heavy S2 Pro server unloaded until
TRAVIS actually requests speech. It starts s2.cpp on demand, proxies one or
more synthesis requests, then terminates the heavy server after a short idle
period so the Mac does not stay under memory/GPU pressure.

This broker itself uses only the Python standard library and holds no plant,
PI, or user content beyond the lifetime of each local request.
"""

from __future__ import annotations

import http.client
import os
import signal
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BROKER_HOST = "127.0.0.1"
BROKER_PORT = 3031
S2_HOST = "127.0.0.1"
S2_PORT = 3030
IDLE_SECONDS = 20
STARTUP_TIMEOUT_SECONDS = 45

HOME = Path.home()
S2_ROOT = Path(os.environ.get("TRAVIS_S2_ROOT", HOME / "s2.cpp"))
S2_BINARY = Path(os.environ.get("TRAVIS_S2_BINARY", S2_ROOT / "build" / "s2"))
S2_MODEL = Path(os.environ.get("TRAVIS_S2_MODEL", S2_ROOT / "models" / "s2-pro-q4_k_m.gguf"))
S2_TOKENIZER = Path(os.environ.get("TRAVIS_S2_TOKENIZER", S2_ROOT / "models" / "tokenizer.json"))
S2_VOICE_DIR = Path(os.environ.get("TRAVIS_S2_VOICE_DIR", S2_ROOT / "voices"))

_lock = threading.RLock()
_s2_process: subprocess.Popen | None = None
_idle_timer: threading.Timer | None = None
_active_requests = 0


def _port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def _validate_paths() -> None:
    missing = [p for p in (S2_BINARY, S2_MODEL, S2_TOKENIZER) if not p.exists()]
    if missing:
        raise RuntimeError("Missing local S2 component(s): " + ", ".join(str(p) for p in missing))
    S2_VOICE_DIR.mkdir(parents=True, exist_ok=True)


def _cancel_idle_timer_locked() -> None:
    global _idle_timer
    if _idle_timer is not None:
        _idle_timer.cancel()
        _idle_timer = None


def _stop_s2() -> None:
    global _s2_process, _idle_timer
    with _lock:
        _idle_timer = None
        proc = _s2_process
        _s2_process = None
    if proc is None or proc.poll() is not None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _schedule_idle_stop_locked() -> None:
    global _idle_timer
    _cancel_idle_timer_locked()
    _idle_timer = threading.Timer(IDLE_SECONDS, _stop_s2)
    _idle_timer.daemon = True
    _idle_timer.start()


def _ensure_s2_started() -> None:
    global _s2_process
    with _lock:
        _cancel_idle_timer_locked()
        if _s2_process is not None and _s2_process.poll() is None and _port_open(S2_HOST, S2_PORT):
            return

        _validate_paths()
        cmd = [
            str(S2_BINARY),
            "--server",
            "--host", S2_HOST,
            "--port", str(S2_PORT),
            "--metal",
            "--gpu-layers", "-1",
            "--codec-cpu",
            "--model", str(S2_MODEL),
            "--tokenizer", str(S2_TOKENIZER),
            "--voice-dir", str(S2_VOICE_DIR),
            "--log-level", "warn",
        ]
        _s2_process = subprocess.Popen(
            cmd,
            cwd=str(S2_ROOT),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        proc = _s2_process

    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"S2 server exited during startup with code {proc.returncode}")
        if _port_open(S2_HOST, S2_PORT):
            return
        time.sleep(0.25)

    _stop_s2()
    raise RuntimeError("Timed out waiting for local S2 server to start")


class BrokerHandler(BaseHTTPRequestHandler):
    server_version = "TRAVISVoiceBroker/1.0"

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        if self.path == "/health":
            payload = b'{"status":"ok","mode":"on-demand"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404)

    def do_POST(self) -> None:
        global _active_requests
        if self.path != "/generate":
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)
        content_type = self.headers.get("Content-Type", "application/octet-stream")

        with _lock:
            _active_requests += 1
            _cancel_idle_timer_locked()

        try:
            _ensure_s2_started()
            conn = http.client.HTTPConnection(S2_HOST, S2_PORT, timeout=300)
            conn.request(
                "POST",
                "/generate",
                body=body,
                headers={
                    "Content-Type": content_type,
                    "Content-Length": str(len(body)),
                    "Connection": "close",
                },
            )
            response = conn.getresponse()
            data = response.read()
            response_type = response.getheader("Content-Type", "application/octet-stream")
            conn.close()

            self.send_response(response.status)
            self.send_header("Content-Type", response_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("X-TRAVIS-Voice-Mode", "on-demand-s2")
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:
            payload = (f'{{"error":"{str(exc).replace(chr(34), chr(39))}"}}').encode("utf-8")
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        finally:
            with _lock:
                _active_requests = max(0, _active_requests - 1)
                if _active_requests == 0:
                    _schedule_idle_stop_locked()


def _shutdown(signum=None, frame=None) -> None:
    _stop_s2()
    raise SystemExit(0)


def main() -> None:
    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)
    server = ThreadingHTTPServer((BROKER_HOST, BROKER_PORT), BrokerHandler)
    print(f"TRAVIS voice broker listening on http://{BROKER_HOST}:{BROKER_PORT}")
    print(f"Heavy S2 server starts on demand and stops after {IDLE_SECONDS}s idle.")
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        _stop_s2()
        server.server_close()


if __name__ == "__main__":
    main()
