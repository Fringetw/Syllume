import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from delayed_navidrome_proxy import DelayProxy


class FixtureOrigin(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def do_GET(self):
        if self.path == "/rest/ping":
            self.reply(b"pong")
        elif self.path == "/rest/stream?t=fixture-token&u=fixture-user":
            requested = self.headers.get("Range")
            if requested == "bytes=0-1":
                self.reply(b"ab", "bytes 0-1/8")
            elif requested == "bytes=2-7":
                self.reply(b"cdefgh", "bytes 2-7/8")
            else:
                self.send_error(400)
        else:
            self.send_error(404)

    def reply(self, body, content_range=None):
        self.send_response(206 if content_range else 200)
        self.send_header("Content-Length", str(len(body)))
        if content_range:
            self.send_header("Content-Range", content_range)
        self.end_headers()
        self.wfile.write(body)


class FixtureClock:
    elapsed = 0.0

    def monotonic(self):
        return self.elapsed

    def time(self):
        return self.elapsed

    def sleep(self, seconds):
        self.elapsed += seconds


class DelayedNavidromeProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        openssl = shutil.which("openssl")
        if openssl is None:
            raise unittest.SkipTest("OpenSSL is required for disposable loopback TLS")
        tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(tmp.cleanup)
        folder = Path(tmp.name)
        key = folder / "key.pem"
        certificate = folder / "cert.pem"
        config = folder / "openssl.cnf"
        config.write_text("[req]\ndistinguished_name=subject\n[subject]\n[extensions]\n"
                          "subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\n"
                          "keyUsage=critical,keyCertSign,digitalSignature\n", encoding="utf-8")
        # Avoid MSYS rewriting the certificate subject into a Windows file path.
        subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-config", str(config), "-extensions", "extensions",
                        "-keyout", str(key), "-out", str(certificate)],
                       env={**os.environ, "MSYS2_ARG_CONV_EXCL": "*"}, check=True, capture_output=True)
        cls.local_tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.local_tls.load_cert_chain(certificate, key)
        cls.trust = ssl.create_default_context(cafile=str(certificate))

    def start(self, server):
        server.socket = self.local_tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(thread.join, 3)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server.server_port

    def test_probe_and_bulk_use_one_verified_tls_gate(self):
        clock = FixtureClock()
        self.enterContext(patch("delayed_navidrome_proxy.time", clock))
        origin = self.start(ThreadingHTTPServer(("127.0.0.1", 0), FixtureOrigin))
        finished = threading.Event()

        class Evidence(io.StringIO):
            def write(self, value):
                count = super().write(value)
                if '"stream-body"' in value:
                    finished.set()
                return count

        evidence = Evidence()
        port = self.start(DelayProxy(origin, self.trust, delay=1, evidence=evidence))

        def request(path, headers=None):
            client = http.client.HTTPSConnection("localhost", port, context=self.trust, timeout=4)
            try:
                client.request("GET", path, headers=headers or {})
                response = client.getresponse()
                return response.status, response.getheader("Content-Range"), response.read()
            finally:
                client.close()

        self.assertEqual(request("/rest/ping"), (200, None, b"pong"))
        media = "/rest/stream?t=fixture-token&u=fixture-user"
        self.assertEqual(request(media, {"Range": "bytes=0-1"}), (206, "bytes 0-1/8", b"ab"))
        clock.elapsed = 0.5
        self.assertEqual(request(media, {"Range": "bytes=2-7"}), (206, "bytes 2-7/8", b"cdefgh"))
        self.assertTrue(finished.wait(2), "Record the downstream media bytes")
        log = evidence.getvalue()
        self.assertNotIn("fixture-token", log)
        self.assertNotIn("fixture-user", log)
        events = [json.loads(line) for line in log.splitlines()]
        self.assertEqual([event["event"] for event in events], [
            "proxy-preflight", "stream-request", "stream-prefix", "stream-request",
            "stream-prefix", "stream-gated", "stream-released", "stream-body",
        ])
        self.assertIsNone(events[0]["elapsedMs"])
        self.assertEqual(events[2]["bodyBytes"], 2)
        self.assertEqual(events[-2]["elapsedMs"], 1000)
        self.assertEqual(events[-1]["bodyBytes"], 6)


if __name__ == "__main__":
    unittest.main()
