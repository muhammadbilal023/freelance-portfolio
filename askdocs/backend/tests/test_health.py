"""M1 plumbing: health + error envelope."""

from fastapi.testclient import TestClient


def test_health_reports_counters(client: TestClient) -> None:
    res = client.get("/health")
    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "ok"
    assert body["llm_provider"] == "fake"
    assert "documents" in body and "jobs" in body


def test_unknown_route_uses_error_envelope(client: TestClient) -> None:
    res = client.get("/does-not-exist")
    assert res.status_code == 404
    assert res.json()["error"]["code"] == "not_found"
