"""Exercise the AVPlayer fixture's HTTP contract on loopback."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
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
from unittest.mock import patch
from urllib.parse import urlsplit

from range_audio_server import AudioServer


MEDIA = b"0123456789abcdef"


class RangeAudioServerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def start_server(self, media=MEDIA, **options):
        self.log = io.StringIO()
        self.server = AudioServer(media, self.log, **options)
        self.worker = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02})
        self.worker.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.stopping.set()
        self.server.shutdown()
        self.worker.join(timeout=2)
        self.server.server_close()
        self.assertFalse(self.worker.is_alive())

    def request(self, method="GET", headers=None, path="/audio"):
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            client.request(method, path, headers=headers or {})
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def records(self, count, event=None):
        deadline = time.monotonic() + 2
        while True:
            with self.server.log_lock:
                rows = [json.loads(line) for line in self.log.getvalue().splitlines()]
            if event is not None:
                rows = [row for row in rows if row["event"] == event]
            if len(rows) >= count:
                return rows
            if time.monotonic() >= deadline:
                self.fail(f"Expected {count} log records, got {rows!r}")
            time.sleep(0.01)

    def test_loopback_binding_does_not_resolve_hostnames(self):
        with patch("socket.getfqdn", side_effect=AssertionError("Unexpected DNS lookup")):
            self.start_server()
        self.assertEqual(self.request()[::2], (200, MEDIA))

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
        self.assertGreaterEqual(self.records(1, event="response")[0]["elapsedMs"], 140)
        self.assertEqual(self.request()[::2], (200, MEDIA))
        self.assertGreaterEqual(self.records(2, event="response")[1]["elapsedMs"], 95)

    def test_shutdown_releases_a_stalled_response(self):
        gate = self.root / "stall"
        gate.touch()
        self.start_server(stall_file=gate)
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        self.addCleanup(client.close)
        client.request("GET", "/audio")
        self.assertEqual(client.getresponse().status, 200)
        self.server.stopping.set()
        response = self.records(1, event="response")[0]
        self.assertEqual(response["bodyBytes"], 0)
        self.assertTrue(gate.exists())

    def test_control_routes_require_opt_in(self):
        self.start_server()
        for path in ("/control/stall", "/control/resume"):
            self.assertEqual(self.request("POST", path=path)[0], 404)
        self.assertEqual(self.request()[::2], (200, MEDIA))

    def test_prefix_resumes_after_the_first_blocked_range(self):
        self.start_server(stall_after_byte=2, resume_after_stall=0.15)
        self.assertEqual(self.request(headers={"Range": "bytes=0-1"})[::2], (206, b"01"))
        self.assertIsNone(self.server.stalled_since)
        self.assertEqual(self.request(headers={"Range": "bytes=2-15"})[::2], (206, MEDIA[2:]))
        self.assertEqual(self.records(1, event="stall")[0]["offset"], 2)
        self.assertGreaterEqual(self.records(1, event="timed-resume")[0]["elapsedMs"], 150)

    def test_prefix_limit_applies_across_ranges_until_resume(self):
        self.start_server(allow_control=True, stall_after_byte=5)
        self.assertEqual(self.request(headers={"Range": "bytes=0-4"})[::2], (206, b"01234"))
        with ThreadPoolExecutor(max_workers=2) as readers:
            full = readers.submit(self.request)
            suffix = readers.submit(self.request, headers={"Range": "bytes=10-15"})
            try:
                stalled = self.records(2, event="stall")
                self.assertEqual(sorted((row["offset"], row["bodyBytes"]) for row in stalled), [(5, 5), (10, 0)])
                for pending in (full, suffix):
                    with self.assertRaises(TimeoutError):
                        pending.result(timeout=0.05)
            finally:
                status, headers, body = self.request("POST", path="/control/resume")
                self.assertEqual((status, headers["Connection"], body), (204, "close", b""))
            self.assertEqual(full.result(timeout=2)[::2], (200, MEDIA))
            self.assertEqual(suffix.result(timeout=2)[::2], (206, b"abcdef"))
        self.assertEqual(self.records(1, event="control")[0]["action"], "resume")

    def test_control_stall_holds_ongoing_and_new_bodies(self):
        media = MEDIA * 4
        self.start_server(media, allow_control=True, bytes_per_second=128)
        with closing(HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)) as client:
            client.request("GET", "/audio")
            response = client.getresponse()
            prefix = response.read(12)
            self.assertEqual(prefix, media[:12])
            for _ in range(2):
                self.assertEqual(self.request("POST", path="/control/stall")[0], 204)
            with ThreadPoolExecutor(max_workers=2) as readers:
                remainder = readers.submit(response.read)
                suffix = readers.submit(self.request, headers={"Range": "bytes=40-63"})
                try:
                    stalled = self.records(2, event="stall")
                    offsets = {row["id"]: row for row in stalled}
                    self.assertGreaterEqual(offsets[1]["offset"], 12)
                    self.assertLess(offsets[1]["offset"], len(media))
                    self.assertEqual((offsets[2]["offset"], offsets[2]["bodyBytes"]), (40, 0))
                    for pending in (remainder, suffix):
                        with self.assertRaises(TimeoutError):
                            pending.result(timeout=0.05)
                finally:
                    for _ in range(2):
                        self.assertEqual(self.request("POST", path="/control/resume")[0], 204)
                self.assertEqual(prefix + remainder.result(timeout=2), media)
                self.assertEqual(suffix.result(timeout=2)[::2], (206, media[40:]))
        self.assertEqual([row["action"] for row in self.records(4, event="control")],
                         ["stall", "stall", "resume", "resume"])

    def test_cli_publishes_loopback_url_after_listening(self):
        media = self.root / "tide.WAV"
        media.write_bytes(MEDIA)
        ready = self.root / "ready.json"
        log = self.root / "requests.jsonl"
        script = Path(__file__).with_name("range_audio_server.py")
        published = False
        with subprocess.Popen([sys.executable, str(script), "--media", str(media),
                               "--ready-file", str(ready), "--log", str(log),
                               "--allow-control", "--stall-after-byte", "3"],
                              stderr=subprocess.PIPE, text=True) as server:
            try:
                deadline = time.monotonic() + 15
                while not ready.exists() and server.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                published = ready.exists()
                if published:
                    url = urlsplit(json.loads(ready.read_text(encoding="utf-8"))["url"])
                    self.assertEqual((url.scheme, url.hostname, url.path), ("http", "127.0.0.1", "/audio"))
                    with closing(HTTPConnection(url.hostname, url.port, timeout=3)) as client:
                        client.request("GET", url.path, headers={"Range": "bytes=0-2"})
                        response = client.getresponse()
                        self.assertEqual((response.status, response.read()), (206, b"012"))
                        self.assertEqual(response.getheader("Content-Type"), "audio/wav")
                    with closing(HTTPConnection(url.hostname, url.port, timeout=3)) as client:
                        client.request("POST", "/control/resume")
                        self.assertEqual(client.getresponse().status, 204)
                    with closing(HTTPConnection(url.hostname, url.port, timeout=3)) as client:
                        client.request("GET", url.path, headers={"Range": "bytes=3-4"})
                        response = client.getresponse()
                        self.assertEqual((response.status, response.read()), (206, b"34"))
            finally:
                server.terminate()
                try:
                    errors = server.communicate(timeout=3)[1]
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.communicate()
                    self.fail("The range fixture did not shut down after termination")

        self.assertTrue(published, f"The fixture did not create its readiness file. Exit {server.returncode}. {errors}")
        if sys.platform != "win32":
            # Windows terminates this process directly instead of delivering SIGTERM.
            self.assertEqual(server.returncode, 0, errors)
            self.assertFalse(ready.exists())
        rows = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(rows[0]["range"], [0, 2])
