import json
import socket
import threading
import time
import urllib.error
import urllib.request

import pytest

from server import make_server


@pytest.fixture
def base_url():
    server = make_server(host="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    yield f"http://{host}:{port}"
    server.shutdown()
    server.server_close()


def get(url):
    with urllib.request.urlopen(url, timeout=5) as resp:  # noqa: S310 (local test server)
        return resp.status, resp.headers["Content-Type"], json.loads(resp.read())


def test_health_returns_ok(base_url):
    status, content_type, body = get(f"{base_url}/health")
    assert status == 200
    assert content_type == "application/json"
    assert body == {"status": "ok"}


def test_root_reports_version(base_url):
    status, _, body = get(f"{base_url}/")
    assert status == 200
    assert body["service"] == "oidc-lab"
    assert "version" in body


def test_unknown_path_is_404(base_url):
    with pytest.raises(urllib.error.HTTPError) as exc:
        get(f"{base_url}/nope")
    assert exc.value.code == 404


def test_log_escapes_control_characters():
    from server import CONTROL_CHARS

    assert "a\x1bb\x7f".translate(CONTROL_CHARS) == "a\\x1bb\\x7f"


def test_stalled_client_is_disconnected():
    from server import Handler

    assert 0 < Handler.timeout <= 30


def test_trickling_client_is_cut_off_at_the_request_deadline(monkeypatch):
    from server import Handler

    monkeypatch.setattr(Handler, "request_deadline", 0.5)
    server = make_server(host="127.0.0.1", port=0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        closed = False
        started = time.monotonic()
        with socket.create_connection(server.server_address, timeout=0.1) as client:
            client.sendall(b"GET / HTTP/1.1\r\n")
            while time.monotonic() - started < 5:
                try:
                    client.sendall(b"X")  # one byte of a header that never ends, well inside the socket timeout
                    if client.recv(1024) == b"":
                        closed = True
                        break
                except TimeoutError:
                    continue
                except OSError:
                    closed = True
                    break
        assert closed
        assert time.monotonic() - started < 3
    finally:
        server.shutdown()
        server.server_close()
