"""
Self-check runner for WebBlock FastAPI endpoints.
Can be executed with: python test_server.py
"""
import os
# Force isolated sqlite test db
os.environ["DATABASE_URL"] = "sqlite:///./test_webblock.db"

from fastapi.testclient import TestClient
from main import app, Base, engine, AGENT_API_KEY, ADMIN_API_KEY

client = TestClient(app)

AGENT_HEADERS = {"X-Agent-Key": AGENT_API_KEY}
ADMIN_HEADERS = {"X-Admin-Key": ADMIN_API_KEY}

def run_tests():
    # Clean recreate schema
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)

    # 1. Unauthorized check (Heartbeat without key -> 401)
    res = client.post("/api/heartbeat", json={"serial_number": "TEST-SN-1234"})
    assert res.status_code == 401, f"Expected 401 without key, got {res.status_code}"

    # 2. Heartbeat with Agent Key
    res = client.post("/api/heartbeat", headers=AGENT_HEADERS, json={
        "serial_number": "TEST-SN-1234",
        "brand": "Dell",
        "last_ip": "192.168.1.50",
        "last_ssid": "Starlink-Camp"
    })
    assert res.status_code == 200, res.text
    data = res.json()
    device_id = data["device_id"]
    assert device_id is not None
    assert data["blocked_domains"] == []

    # 3. Blocked domain creation without admin key -> 401
    res = client.post("/api/blocked-domains", json={"domain": "tiktok.com"})
    assert res.status_code == 401

    # 4. Blocked domain creation with admin key -> 200
    res = client.post("/api/blocked-domains", headers=ADMIN_HEADERS, json={"domain": "tiktok.com", "added_by": "gerencia"})
    assert res.status_code == 200
    dom_id = res.json()["id"]

    res = client.get("/api/blocked-domains")
    assert res.status_code == 200
    assert "tiktok.com" in res.json()

    # 5. Heartbeat includes blocked domain
    res = client.post("/api/heartbeat", headers=AGENT_HEADERS, json={"serial_number": "TEST-SN-1234"})
    assert "tiktok.com" in res.json()["blocked_domains"]

    # 6. Activity batch ingestion with Agent Key
    res = client.post("/api/activity", headers=AGENT_HEADERS, json={
        "device_id": device_id,
        "activities": [
            {"domain": "youtube.com", "duration_seconds": 300},
            {"domain": "tiktok.com", "duration_seconds": 120}
        ]
    })
    assert res.status_code == 200
    assert res.json()["inserted"] == 2

    # 7. Metrics verification
    res = client.get("/api/metrics/top-domains")
    assert res.status_code == 200
    top = res.json()
    assert len(top) == 2
    assert top[0]["domain"] == "youtube.com"

    # 8. CSV Export verification
    res = client.get("/api/metrics/export-csv")
    assert res.status_code == 200
    assert "text/csv" in res.headers["content-type"]
    assert "youtube.com" in res.text

    # 9. Admin cleanup endpoint
    res = client.post("/api/admin/cleanup?days=30", headers=ADMIN_HEADERS)
    assert res.status_code == 200
    assert res.json()["status"] == "ok"

    print("ALL PRODUCTION SECURITY & METRIC TESTS PASSED SUCCESSFULLY!")

if __name__ == "__main__":
    run_tests()
