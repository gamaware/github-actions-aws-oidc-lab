import json
import threading
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
