"""
Self-check runner for WebBlock FastAPI endpoints.
Uses isolated SQLite database to guarantee zero impact on production databases.
"""
import os
test_db_file = os.path.abspath(os.path.join(os.path.dirname(__file__), "test_isolated.db")).replace("\\", "/")
os.environ["DATABASE_URL"] = f"sqlite:///{test_db_file}"

from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from main import app, Base, get_db, AGENT_API_KEY, ADMIN_API_KEY

test_engine = create_engine(f"sqlite:///{test_db_file}", connect_args={"check_same_thread": False})
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=test_engine)

def override_get_db():
    db = TestingSessionLocal()
    try:
        yield db
    finally:
        db.close()

app.dependency_overrides[get_db] = override_get_db
Base.metadata.create_all(bind=test_engine)
client = TestClient(app)

AGENT_HEADERS = {"X-Agent-Key": AGENT_API_KEY}
ADMIN_HEADERS = {"X-Admin-Key": ADMIN_API_KEY}


def run_tests():
    try:
        # 1. Unauthorized check (Heartbeat without key -> 401)
        res = client.post("/api/heartbeat", json={"serial_number": "TEST-SN-1234"})
        assert res.status_code == 401, f"Expected 401 without key, got {res.status_code}"

        # 2. Heartbeat with Agent Key
        res = client.post("/api/heartbeat", headers=AGENT_HEADERS, json={
            "serial_number": "TEST-SN-1234",
            "brand": "Dell",
            "last_ip": "192.168.1.50",
            "last_ssid": "Starlink-Camp",
            "version": "1.0.9"
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

        print("ALL TESTS PASSED WITH 100% DATABASE ISOLATION!")
    finally:
        test_engine.dispose()
        if os.path.exists(test_db_file):
            try:
                os.remove(test_db_file)
            except Exception:
                pass


if __name__ == "__main__":
    run_tests()
