"""Tiny HTTP service with a health endpoint, standard library only."""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.environ.get("APP_VERSION", "dev")


class Handler(BaseHTTPRequestHandler):
    """Serves GET /health and GET /; everything else is a 404."""

    server_version = "oidc-lab"
    sys_version = ""

    def do_GET(self) -> None:  # noqa: N802 (name fixed by BaseHTTPRequestHandler)
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        elif self.path == "/":
            self._send(200, {"service": "oidc-lab", "version": VERSION})
        else:
            self._send(404, {"error": "not found"})

    def _send(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: object) -> None:
        # One line per request on stdout, picked up by the awslogs driver.
        # Escape control characters the same way the base class does.
        message = (fmt % args).translate(self._control_char_table)
        print(f"{self.address_string()} {message}", flush=True)


def make_server(host: str = "0.0.0.0", port: int = 8080) -> ThreadingHTTPServer:  # noqa: S104
    return ThreadingHTTPServer((host, port), Handler)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    make_server(port=port).serve_forever()
