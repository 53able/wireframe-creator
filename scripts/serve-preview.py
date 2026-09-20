#!/usr/bin/env python3
"""Serve one wireframe HTML file with same-origin SSE change notifications."""

from __future__ import annotations

import argparse
import hashlib
import re
import signal
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


ALLOWED_HOST = "127.0.0.1"
POLL_SECONDS = 0.35
KEEPALIVE_SECONDS = 10.0


def fingerprint(path: Path) -> str:
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return "missing"
    return hashlib.sha256(data).hexdigest()


def build_handler(target: Path) -> type[BaseHTTPRequestHandler]:
    class PreviewHandler(BaseHTTPRequestHandler):
        server_version = "WireframePreview/1"

        def log_message(self, format: str, *args: object) -> None:
            print(f"PREVIEW: {self.address_string()} - {format % args}", file=sys.stderr)

        def send_bytes(self, status: HTTPStatus, content_type: str, payload: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(payload)

        def valid_host(self) -> bool:
            values = self.headers.get_all("Host", [])
            if len(values) != 1:
                return False
            match = re.fullmatch(r"(127\.0\.0\.1|localhost)(?::([0-9]{1,5}))?", values[0])
            if not match:
                return False
            port = match.group(2)
            if port is None:
                return True
            numeric_port = int(port)
            return 0 < numeric_port <= 65535 and numeric_port == self.server.server_address[1]

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            if not self.valid_host():
                self.send_bytes(
                    HTTPStatus.BAD_REQUEST,
                    "text/plain; charset=utf-8",
                    b"Invalid Host header\n",
                )
                return
            path = urlsplit(self.path).path
            if path in {"/", "/__wireframe/document"}:
                try:
                    payload = target.read_bytes()
                except FileNotFoundError:
                    self.send_bytes(
                        HTTPStatus.NOT_FOUND,
                        "text/plain; charset=utf-8",
                        f"Wireframe file does not exist: {target}\n".encode(),
                    )
                    return
                self.send_bytes(HTTPStatus.OK, "text/html; charset=utf-8", payload)
                return
            if path == "/__wireframe/events":
                self.stream_events()
                return
            self.send_bytes(
                HTTPStatus.NOT_FOUND,
                "text/plain; charset=utf-8",
                b"Not found\n",
            )

        def stream_events(self) -> None:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()

            previous = ""
            last_keepalive = 0.0
            try:
                while not self.server.shutdown_requested.is_set():  # type: ignore[attr-defined]
                    current = fingerprint(target)
                    now = time.monotonic()
                    if current != previous:
                        payload = f"event: revision\ndata: {current}\n\n".encode()
                        self.wfile.write(payload)
                        self.wfile.flush()
                        previous = current
                        last_keepalive = now
                    elif now - last_keepalive >= KEEPALIVE_SECONDS:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                        last_keepalive = now
                    time.sleep(POLL_SECONDS)
            except (BrokenPipeError, ConnectionResetError):
                return

    return PreviewHandler


class PreviewServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], handler: type[BaseHTTPRequestHandler]):
        super().__init__(address, handler)
        self.shutdown_requested = threading.Event()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Serve one wireframe HTML file with localhost-only hot reload."
    )
    parser.add_argument("html", type=Path, help="Wireframe HTML file to serve")
    parser.add_argument("--host", default=ALLOWED_HOST)
    parser.add_argument("--port", type=int, default=0)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    target = args.html.resolve()
    if args.host != ALLOWED_HOST:
        print(f"ERROR: --host must be {ALLOWED_HOST}; refusing external bind.", file=sys.stderr)
        return 2
    if not 0 <= args.port <= 65535:
        print("ERROR: --port must be between 0 and 65535.", file=sys.stderr)
        return 2
    if not target.is_file():
        print(f"ERROR: Wireframe HTML does not exist: {target}", file=sys.stderr)
        return 2

    try:
        server = PreviewServer((args.host, args.port), build_handler(target))
    except OSError as exc:
        print(f"ERROR: Could not start preview server: {exc}", file=sys.stderr)
        return 1

    host, port = server.server_address[:2]
    url = f"http://{host}:{port}/"

    def request_shutdown(_signum: int, _frame: object) -> None:
        server.shutdown_requested.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)
    print(f"PREVIEW_URL={url}", flush=True)
    print(f"SUCCESS: Serving {target} with hot reload.", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.shutdown_requested.set()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
