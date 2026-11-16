"""main.py: public and protected routes, security headers, SPA serving."""

from pathlib import Path

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


def test_health_is_public(anon: TestClient):
    assert anon.get("/api/health").json() == {"ok": True}


def test_status_needs_a_session(anon: TestClient, client: TestClient):
    assert anon.get("/api/status").status_code == 401
    body = client.get("/api/status").json()
    assert body["ok"] is True
    assert body["timezone"] == "America/New_York"
    assert isinstance(body["modules"], list)


def test_every_api_route_but_the_public_ones_needs_auth(app, anon: TestClient):
    public = {
        "/api/health",
        "/api/auth/state",
        "/api/auth/setup",
        "/api/auth/login",
        "/api/settings/timezones",
        "/api/settings/holiday-countries",
    }
    checked = 0
    for path, operations in app.openapi()["paths"].items():
        if path in public:
            continue
        for method in operations:
            url = path.replace("{", "").replace("}", "")  # any value; auth runs first
            response = anon.request(method.upper(), url)
            assert response.status_code == 401, (method, path, response.status_code)
            checked += 1
    assert checked > 10


def test_security_headers(anon: TestClient):
    response = anon.get("/api/health")
    assert response.headers["x-frame-options"] == "DENY"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["cache-control"] == "no-store"


def test_spa_fallback_and_api_404(tmp_path: Path, settings: Settings):
    dist = tmp_path / "dist"
    (dist / "assets").mkdir(parents=True)
    (dist / "index.html").write_text("<html>app</html>")
    (dist / "assets" / "main.js").write_text("console.log(1)")
    client = TestClient(create_app(settings.model_copy(update={"web_dist": dist})))

    assert client.get("/").text == "<html>app</html>"
    assert client.get("/settings").text == "<html>app</html>"  # client-side route
    asset = client.get("/assets/main.js")
    assert asset.text == "console.log(1)"
    assert "immutable" in asset.headers["cache-control"]
    assert client.get("/api/nope").status_code == 404
    assert client.get("/../secrets").text == "<html>app</html>"
