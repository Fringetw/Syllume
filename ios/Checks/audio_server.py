"""Loopback-only fixture server for the native downloader; serves Folia's own synthetic audio."""
import argparse
import http.server
from pathlib import Path
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    args = parser.parse_args()
    audio = args.audio.read_bytes()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path in ("/redirect", "/foreign-redirect"):
                self.send_response(302)
                self.send_header("Location", "/audio" if self.path == "/redirect" else "https://example.com/blocked")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path == "/html":
                body, mime = b"<html>not an audio file</html>", "text/html"
            elif self.path in ("/audio", "/slow", "/oversized"):
                body, mime = audio, "audio/mp4"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(1_000_000_001 if self.path == "/oversized" else len(body)))
            self.end_headers()
            try:
                for start in range(0, len(body), 4096):
                    self.wfile.write(body[start:start + 4096])
                    self.wfile.flush()
                    if self.path in ("/slow", "/oversized"):
                        time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    args.port_file.write_text(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
