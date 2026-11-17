"""Serve an M4A fixture on loopback for AVPlayer integration tests."""

import argparse
import itertools
import json
import re
import signal
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer


class AudioServer(ThreadingHTTPServer):
    timeout = 0.1
    daemon_threads = False

    def __init__(self, media, log, port=0, bytes_per_second=0, stall_file=None):
        if not media:
            raise ValueError("The fixture audio must not be empty")
        self.media = memoryview(media)
        self.log = log
        self.rate = bytes_per_second
        self.stall_file = stall_file
        self.stopping = threading.Event()
        self.sequence = itertools.count(1)
        self.log_lock = threading.Lock()
        super().__init__(("127.0.0.1", port), AudioHandler)

    def server_bind(self):
        # HTTPServer's default bind also does a reverse lookup, which this IPv4-only fixture does not need.
        TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]

    def record(self, **event):
        with self.log_lock:
            self.log.write(json.dumps(event) + "\n")
            self.log.flush()


class AudioHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        self.request.settimeout(2)
        super().setup()

    def log_message(self, _format, *_args):
        pass  # Keep diagnostics in the structured log.

    def do_GET(self):
        self.respond(send_body=True)

    def do_HEAD(self):
        self.respond(send_body=False)

    def respond(self, send_body):
        if self.path != "/audio":
            self.send_error(404)
            return
        self.close_connection = True
        media_size = len(self.server.media)
        request_range = self.headers.get("Range") if send_body else None
        bounds = parse_range(request_range, media_size)
        status = 416 if bounds is None else 200 if request_range is None else 206
        length = 0 if bounds is None else bounds[1] - bounds[0] + 1
        started = time.monotonic()
        number = next(self.server.sequence)
        sent = 0
        self.server.record(event="request", id=number, method=self.command, status=status, range=bounds)
        try:
            self.send_response(status)
            self.send_header("Content-Type", "audio/mp4")
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            if status == 416:
                self.send_header("Content-Range", f"bytes */{media_size}")
            elif status == 206:
                self.send_header("Content-Range", f"bytes {bounds[0]}-{bounds[1]}/{media_size}")
            self.end_headers()
            if send_body and bounds is not None:
                sent = self.send_audio(bounds)
        except OSError:
            # AVPlayer may close a request as soon as it has probed enough metadata.
            pass
        finally:
            self.server.record(event="response", id=number, bodyBytes=sent,
                               elapsedMs=round((time.monotonic() - started) * 1000))

    def send_audio(self, bounds):
        server = self.server
        offset, end = bounds
        chunk_size = min(64 * 1024, max(1, server.rate // 10)) if server.rate else 64 * 1024
        cursor = offset
        try:
            while cursor <= end and not server.stopping.is_set():
                chunk = server.media[cursor:min(cursor + chunk_size, end + 1)]
                if server.rate:
                    deadline = time.monotonic() + len(chunk) / server.rate
                    while (remaining := deadline - time.monotonic()) > 0:
                        if server.stopping.wait(remaining):
                            return cursor - offset
                while server.stall_file is not None and server.stall_file.exists():
                    if server.stopping.wait(0.025):
                        return cursor - offset
                self.wfile.write(chunk)
                cursor += len(chunk)
        except OSError:
            pass
        return cursor - offset


def parse_range(value, size):
    if value is None:
        return 0, size - 1
    # The fixture accepts the single byte ranges used by AVPlayer.
    match = re.fullmatch(r"bytes=([0-9]{0,20})-([0-9]{0,20})", value.strip(), re.IGNORECASE)
    if not match:
        return None
    first, last = match.groups()
    if not first:
        if not last or int(last) == 0:
            return None
        return max(0, size - int(last)), size - 1
    start = int(first)
    end = min(int(last), size - 1) if last else size - 1
    return (start, end) if start <= end else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media", type=Path, required=True, help="M4A audio file")
    parser.add_argument("--ready-file", type=Path, required=True, help="Unique file to receive the bound URL as JSON")
    parser.add_argument("--log", type=Path, required=True, help="Request and response records as JSON lines")
    parser.add_argument("--port", type=int, default=0, help="Loopback port (default: choose an available port)")
    parser.add_argument("--bytes-per-second", type=int, default=0, help="Per-response body rate; zero is unlimited")
    parser.add_argument("--stall-file", type=Path, help="Block response bodies while this path exists")
    args = parser.parse_args()
    if args.bytes_per_second < 0 or not 0 <= args.port <= 65535:
        parser.error("A valid port and nonnegative body rate are required")
    paths = [args.media, args.log, args.ready_file] + ([args.stall_file] if args.stall_file is not None else [])
    if len({path.resolve() for path in paths}) != len(paths):
        parser.error("Media, log, readiness and stall paths must be distinct")
    if args.ready_file.exists():
        parser.error("Choose an unused readiness path")

    media = args.media.read_bytes()
    with args.log.open("w", encoding="utf-8") as log, AudioServer(
            media, log, args.port, args.bytes_per_second, args.stall_file) as server:
        def stop(_signal, _frame):
            server.stopping.set()

        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.ready_file.parent, delete=False) as ready:
            json.dump({"url": f"http://127.0.0.1:{server.server_port}/audio"}, ready)
        staging = Path(ready.name)
        try:
            staging.replace(args.ready_file)
            while not server.stopping.is_set():
                server.handle_request()
        finally:
            server.stopping.set()
            staging.unlink(missing_ok=True)
            args.ready_file.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
