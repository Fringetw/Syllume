"""Exercise the AVPlayer fixture's HTTP contract on loopback."""

from concurrent.futures import ThreadPoolExecutor
from http.client import HTTPConnection
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib.parse import urlsplit

from range_audio_server import AudioServer


MEDIA = b"0123456789abcdef"


class RangeAudioServerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def start_server(self, **options):
        self.log = io.StringIO()
        self.server = AudioServer(MEDIA, self.log, **options)
        self.worker = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02})
        self.worker.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.stopping.set()
        self.server.shutdown()
        self.worker.join(timeout=2)
        self.server.server_close()
        self.assertFalse(self.worker.is_alive())

    def request(self, method="GET", headers=None):
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            client.request(method, "/audio", headers=headers or {})
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def records(self, count):
        deadline = time.monotonic() + 2
        while True:
            with self.server.log_lock:
                rows = [json.loads(line) for line in self.log.getvalue().splitlines()]
            if len(rows) >= count:
                return rows
            if time.monotonic() >= deadline:
                self.fail(f"Expected {count} log records, got {rows!r}")
            time.sleep(0.01)

    def test_head_full_get_and_partial_gets_log_actual_body_bytes(self):
        self.start_server()
        status, headers, data = self.request("HEAD", {"Range": "bytes=2-5"})
        self.assertEqual((status, headers["Content-Length"], data), (200, "16", b""))
        self.assertEqual(headers["Accept-Ranges"], "bytes")
        self.assertEqual(headers["Content-Type"], "audio/mp4")
        self.assertEqual(headers["Cache-Control"], "no-store")

        status, headers, data = self.request()
        self.assertEqual((status, headers["Content-Length"], data), (200, "16", MEDIA))

        for value, content_range, expected in [
            ("bytes=2-5", "bytes 2-5/16", b"2345"),
            ("bytes=14-", "bytes 14-15/16", b"ef"),
            ("bytes=-3", "bytes 13-15/16", b"def"),
            ("bytes=13-30", "bytes 13-15/16", b"def"),
        ]:
            with self.subTest(value=value):
                status, headers, data = self.request(headers={"Range": value})
                self.assertEqual((status, headers["Content-Range"], data), (206, content_range, expected))
                self.assertEqual(int(headers["Content-Length"]), len(expected))

        for value in ("bytes=16-", "bytes=7-2", "bytes=0-1,9-10", "bytes=-0"):
            with self.subTest(value=value):
                status, headers, data = self.request(headers={"Range": value})
                self.assertEqual((status, headers["Content-Range"], data), (416, "bytes */16", b""))

        rows = self.records(20)
        requests = [row for row in rows if row["event"] == "request"]
        responses = {row["id"]: row for row in rows if row["event"] == "response"}
        self.assertEqual(len(responses), len(requests))
        self.assertEqual([row["status"] for row in requests], [200, 200, 206, 206, 206, 206, 416, 416, 416, 416])
        self.assertEqual([responses[row["id"]]["bodyBytes"] for row in requests], [0, 16, 4, 2, 3, 3, 0, 0, 0, 0])

    def test_stalled_bodies_resume_and_respect_the_configured_rate(self):
        gate = self.root / "stall"
        gate.touch()
        self.start_server(bytes_per_second=160, stall_file=gate)
        with ThreadPoolExecutor(max_workers=1) as reader:
            pending = reader.submit(self.request)
            try:
                self.assertEqual(self.records(1)[0]["event"], "request")
                with self.assertRaises(TimeoutError):
                    pending.result(timeout=0.15)
            finally:
                gate.unlink(missing_ok=True)
            self.assertEqual(pending.result(timeout=2)[::2], (200, MEDIA))
        self.assertGreaterEqual(self.records(2)[1]["elapsedMs"], 140)
        self.assertEqual(self.request()[::2], (200, MEDIA))
        self.assertGreaterEqual(self.records(4)[3]["elapsedMs"], 95)

    def test_shutdown_releases_a_stalled_response(self):
        gate = self.root / "stall"
        gate.touch()
        self.start_server(stall_file=gate)
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        self.addCleanup(client.close)
        client.request("GET", "/audio")
        self.assertEqual(client.getresponse().status, 200)
        self.server.stopping.set()
        response = self.records(2)[1]
        self.assertEqual(response["bodyBytes"], 0)
        self.assertTrue(gate.exists())

    def test_cli_publishes_loopback_url_after_listening(self):
        media = self.root / "tide.m4a"
        media.write_bytes(MEDIA)
        ready = self.root / "ready.json"
        log = self.root / "requests.jsonl"
        script = Path(__file__).with_name("range_audio_server.py")
        with subprocess.Popen([sys.executable, str(script), "--media", str(media),
                               "--ready-file", str(ready), "--log", str(log)],
                              stderr=subprocess.PIPE, text=True) as server:
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and server.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists(), "The fixture did not create its readiness file")
                url = urlsplit(json.loads(ready.read_text(encoding="utf-8"))["url"])
                self.assertEqual((url.scheme, url.hostname, url.path), ("http", "127.0.0.1", "/audio"))
                client = HTTPConnection(url.hostname, url.port, timeout=3)
                try:
                    client.request("GET", url.path, headers={"Range": "bytes=0-2"})
                    response = client.getresponse()
                    self.assertEqual((response.status, response.read()), (206, b"012"))
                finally:
                    client.close()
            finally:
                server.terminate()
                try:
                    errors = server.communicate(timeout=3)[1]
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.communicate()
                    self.fail("The range fixture did not shut down after termination")

        if sys.platform != "win32":
            # Windows terminates this process directly instead of delivering SIGTERM.
            self.assertEqual(server.returncode, 0, errors)
            self.assertFalse(ready.exists())
        rows = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(rows[0]["range"], [0, 2])
