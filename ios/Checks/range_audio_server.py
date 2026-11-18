"""Serve a controlled audio fixture on loopback for AVPlayer integration tests."""

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

    def __init__(self, media, log, port=0, bytes_per_second=0, stall_file=None,
                 allow_control=False, stall_after_byte=None, content_type="audio/mp4"):
        if not media:
            raise ValueError("The fixture audio must not be empty")
        if stall_after_byte is not None and stall_after_byte < 0:
            raise ValueError("The stall offset must be nonnegative")
        self.media = memoryview(media)
        self.log = log
        self.rate = bytes_per_second
        self.stall_file = stall_file
        self.allow_control = allow_control
        self.stall_after_byte = stall_after_byte
        self.content_type = content_type
        self.control_stalled = False
        self.prefix_released = False
        self.control_lock = threading.Lock()
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

    def allowed_end(self, cursor, end):
        # Called under control_lock, including immediately before a socket write.
        if self.control_stalled or (self.stall_file is not None and self.stall_file.exists()):
            return cursor
        if not self.prefix_released and self.stall_after_byte is not None:
            return max(cursor, min(end, self.stall_after_byte))
        return end


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

    def do_POST(self):
        self.close_connection = True
        if not self.server.allow_control or self.path not in ("/control/stall", "/control/resume"):
            self.send_error(404)
            return
        action = self.path.rsplit("/", 1)[1]
        with self.server.control_lock:
            self.server.control_stalled = action == "stall"
            if action == "resume":
                self.server.prefix_released = True
            self.server.record(event="control", action=action)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

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
            self.send_header("Content-Type", self.server.content_type)
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
                sent = self.send_audio(bounds, number)
        except OSError:
            # AVPlayer may close a request as soon as it has probed enough metadata.
            pass
        finally:
            self.server.record(event="response", id=number, bodyBytes=sent,
                               elapsedMs=round((time.monotonic() - started) * 1000))

    def send_audio(self, bounds, number):
        server = self.server
        offset, end = bounds
        chunk_size = min(64 * 1024, max(1, server.rate // 10)) if server.rate else 64 * 1024
        cursor = offset
        logged_stall = False
        try:
            while cursor <= end and not server.stopping.is_set():
                with server.control_lock:
                    chunk_end = server.allowed_end(cursor, min(cursor + chunk_size, end + 1))
                if chunk_end == cursor:
                    if not logged_stall:
                        server.record(event="stall", id=number, offset=cursor, bodyBytes=cursor - offset)
                        logged_stall = True
                    if server.stopping.wait(0.025):
                        break
                    continue
                chunk = server.media[cursor:chunk_end]
                if server.rate:
                    deadline = time.monotonic() + len(chunk) / server.rate
                    while (remaining := deadline - time.monotonic()) > 0:
                        if server.stopping.wait(remaining):
                            return cursor - offset
                with server.control_lock:
                    # A control request can arrive while this response waits for its rate budget.
                    if server.allowed_end(cursor, chunk_end) != chunk_end:
                        continue
                    self.wfile.write(chunk)
                    cursor = chunk_end
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
    parser.add_argument("--media", type=Path, required=True, help="M4A or WAV audio file")
    parser.add_argument("--ready-file", type=Path, required=True, help="Unique file to receive the bound URL as JSON")
    parser.add_argument("--log", type=Path, required=True, help="Request and response records as JSON lines")
    parser.add_argument("--port", type=int, default=0, help="Loopback port (default: choose an available port)")
    parser.add_argument("--bytes-per-second", type=int, default=0, help="Per-response body rate; zero is unlimited")
    parser.add_argument("--stall-file", type=Path, help="Block response bodies while this path exists")
    parser.add_argument("--allow-control", action="store_true", help="Enable loopback POST /control/stall and /control/resume")
    parser.add_argument("--stall-after-byte", type=int, help="Serve this prefix, then wait until /control/resume")
    args = parser.parse_args()
    if args.bytes_per_second < 0 or not 0 <= args.port <= 65535:
        parser.error("A valid port and nonnegative body rate are required")
    if args.stall_after_byte is not None and (args.stall_after_byte < 0 or not args.allow_control):
        parser.error("A nonnegative stall offset requires --allow-control")
    paths = [args.media, args.log, args.ready_file] + ([args.stall_file] if args.stall_file is not None else [])
    if len({path.resolve() for path in paths}) != len(paths):
        parser.error("Media, log, readiness and stall paths must be distinct")
    if args.ready_file.exists():
        parser.error("Choose an unused readiness path")

    media = args.media.read_bytes()
    content_type = "audio/wav" if args.media.suffix.lower() == ".wav" else "audio/mp4"
    with args.log.open("w", encoding="utf-8") as log, AudioServer(
            media, log, args.port, args.bytes_per_second, args.stall_file,
            args.allow_control, args.stall_after_byte, content_type) as server:
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
