#!/usr/bin/env python3
"""Hold the initial Navidrome media body for the simulator startup regression."""

import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import itertools
import json
from pathlib import Path
import ssl
import threading
import time


STREAM_PATHS = {"/rest/stream", "/rest/stream.view"}
RESPONSE_HEADERS = (
    "Accept-Ranges", "Cache-Control", "Content-Encoding", "Content-Length",
    "Content-Range", "Content-Type", "ETag", "Last-Modified",
)


class DelayProxy(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, upstream_port, upstream_tls, delay, evidence):
        self.upstream_port = upstream_port
        self.upstream_tls = upstream_tls
        self.delay = delay
        self.evidence = evidence
        self.lock = threading.Lock()
        self.first_stream = None
        self.request_ids = itertools.count(1)
        super().__init__(("127.0.0.1", 0), DelayHandler)

    def begin_stream(self):
        with self.lock:
            if self.first_stream is None:
                self.first_stream = time.monotonic()
            return next(self.request_ids), self.first_stream + self.delay

    def record(self, event, **fields):
        with self.lock:
            elapsed = None if self.first_stream is None else round((time.monotonic() - self.first_stream) * 1000)
            print(json.dumps({"event": event, "epochMs": round(time.time() * 1000), "elapsedMs": elapsed, **fields}),
                  file=self.evidence, flush=True)

    def handle_error(self, _request, _address):
        self.record("handler-error")


class DelayHandler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        # Navidrome requests carry credentials in the query. Evidence only contains timings and byte counts.
        pass

    def do_GET(self):
        self.forward()

    def do_HEAD(self):
        self.forward()

    def forward(self):
        if not self.path.startswith("/rest/"):
            self.send_error(404)
            return
        stream = self.command == "GET" and self.path.partition("?")[0] in STREAM_PATHS
        if stream:
            request_id, release = self.server.begin_stream()
            self.server.record("stream-request", id=request_id)
        headers = {name: self.headers[name] for name in ("Range", "User-Agent") if name in self.headers}
        connection = http.client.HTTPSConnection("localhost", self.server.upstream_port,
                                                 context=self.server.upstream_tls, timeout=20)
        responded = False
        try:
            connection.request(self.command, self.path, headers=headers)
            response = connection.getresponse()
            if self.path == "/rest/ping":
                self.server.record("proxy-preflight", status=response.status)
            self.send_response(response.status)
            for name in RESPONSE_HEADERS:
                if (value := response.getheader(name)) is not None:
                    self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            responded = True
            if self.command != "HEAD":
                if stream and response.status in (200, 206):
                    self.send_stream(response, request_id, release)
                else:
                    self.copy_body(response)
        except (OSError, http.client.HTTPException) as error:
            if stream:
                self.server.record("stream-error", id=request_id, kind=type(error).__name__)
            if not responded:
                try:
                    self.send_error(502)
                except OSError:
                    pass
        finally:
            connection.close()

    def send_stream(self, response, request_id, release):
        content_range = response.getheader("Content-Range", "")
        from_start = response.status == 200 or content_range.startswith("bytes 0-")
        prefix = response.read(2) if from_start else b""
        self.wfile.write(prefix)
        length_header = response.getheader("Content-Length", "")
        length = int(length_header) if length_header.isdecimal() else None
        self.server.record("stream-prefix", id=request_id, status=response.status, bodyBytes=len(prefix),
                           contentLength=length, fromStart=from_start)
        if length == len(prefix):
            return
        if (remaining := release - time.monotonic()) > 0:
            self.server.record("stream-gated", id=request_id)
            time.sleep(remaining)
        self.server.record("stream-released", id=request_id)
        transferred = self.copy_body(response)
        self.server.record("stream-body", id=request_id, bodyBytes=transferred)

    def copy_body(self, response):
        transferred = 0
        while chunk := response.read(64 * 1024):
            self.wfile.write(chunk)
            transferred += len(chunk)
        return transferred


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-port", required=True, type=int)
    parser.add_argument("--ca", required=True, type=Path)
    parser.add_argument("--chain", required=True, type=Path)
    parser.add_argument("--key", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--ready-file", required=True, type=Path)
    args = parser.parse_args()
    if not 0 < args.upstream_port < 65536 or args.ready_file.exists():
        parser.error("Use a valid upstream port and a new readiness file.")

    upstream_tls = ssl.create_default_context(cafile=str(args.ca))
    downstream_tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    downstream_tls.load_cert_chain(args.chain, args.key)
    with args.log.open("x", encoding="utf-8") as evidence, \
            DelayProxy(args.upstream_port, upstream_tls, delay=12, evidence=evidence) as server:
        server.socket = downstream_tls.wrap_socket(server.socket, server_side=True)
        server.record("proxy-ready", delayMs=12000)
        staging = args.ready_file.with_suffix(".tmp")
        staging.write_text(f"https://localhost:{server.server_port}\n", encoding="utf-8")
        staging.replace(args.ready_file)
        server.serve_forever()


if __name__ == "__main__":
    main()
