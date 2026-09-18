import os
import uuid
import csv
import io
import zipfile
from urllib.parse import urlparse
from datetime import datetime, timezone, timedelta
from typing import List, Optional, Union

from fastapi import FastAPI, Depends, HTTPException, Query, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response, FileResponse
from pydantic import BaseModel
from sqlalchemy import (
    create_engine, Column, String, Boolean, Integer, DateTime, ForeignKey, func, select
)
from sqlalchemy.orm import declarative_base, sessionmaker, Session, relationship

# Load .env configuration
_env_path = os.path.join(os.path.dirname(__file__), ".env")
if os.path.exists(_env_path):
    with open(_env_path, "r", encoding="utf-8") as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith("#") and "=" in _line:
                _k, _v = _line.split("=", 1)
                os.environ[_k.strip()] = _v.strip().strip('"').strip("'")

# Database configuration (overridable with DATABASE_URL environment variable)
DB_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "webblock.db")).replace("\\", "/")
DEFAULT_DB_URL = f"sqlite:///{DB_PATH}"
DATABASE_URL = os.getenv("DATABASE_URL", DEFAULT_DB_URL)
if DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql://", 1)

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, connect_args=connect_args)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


# --- Models ---
class Device(Base):
    __tablename__ = "devices"
    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    serial_number = Column(String(100), unique=True, index=True, nullable=False)
    brand = Column(String(100), default="Unknown")
    last_ip = Column(String(45), default="")
    last_ssid = Column(String(100), default="")
    last_ping = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    current_key = Column(String(255), default="")
    pending_key = Column(String(255), nullable=True)
    version = Column(String(50), default="")

    activities = relationship("WebActivity", back_populates="device", cascade="all, delete-orphan")


class BlockedDomain(Base):
    __tablename__ = "blocked_domains"
    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    domain = Column(String(255), unique=True, index=True, nullable=False)
    is_active = Column(Boolean, default=True)
    added_by = Column(String(100), default="admin")


class WebActivity(Base):
    __tablename__ = "web_activity"
    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    device_id = Column(String(36), ForeignKey("devices.id"), nullable=False, index=True)
    domain = Column(String(255), nullable=False, index=True)
    duration_seconds = Column(Integer, default=0)
    logged_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    device = relationship("Device", back_populates="activities")


Base.metadata.create_all(bind=engine)

# Ensure new columns exist on legacy tables without requiring Alembic
with engine.connect() as _c:
    for _col in ["current_key", "pending_key", "version"]:
        try:
            _c.exec_driver_sql(f"ALTER TABLE devices ADD COLUMN {_col} VARCHAR(255)")
            _c.commit()
        except Exception:
            pass


# --- Schemas ---
class HeartbeatRequest(BaseModel):
    serial_number: str
    brand: Optional[str] = "Unknown"
    last_ip: Optional[str] = ""
    last_ssid: Optional[str] = ""
    version: Optional[str] = ""


class ActivityItem(BaseModel):
    domain: str
    duration_seconds: int
    logged_at: Optional[datetime] = None


class BatchActivityRequest(BaseModel):
    device_id: str
    activities: Union[List[ActivityItem], ActivityItem]


class BlockDomainCreate(BaseModel):
    domain: str
    added_by: Optional[str] = "admin"


class BlockDomainToggle(BaseModel):
    is_active: bool


# API Security Keys
AGENT_API_KEY = os.getenv("AGENT_API_KEY", "wb_agent_secret_2026")
ADMIN_API_KEY = os.getenv("ADMIN_API_KEY", "wb_admin_secret_2026")


# --- App & DB Dependency ---
app = FastAPI(title="WebBlock API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def verify_agent_or_admin(
    x_agent_key: Optional[str] = Header(None),
    x_admin_key: Optional[str] = Header(None),
    db: Session = Depends(get_db),
):
    if x_admin_key == ADMIN_API_KEY:
        return True
    if x_agent_key:
        if x_agent_key == AGENT_API_KEY:
            return True
        match = db.query(Device).filter((Device.current_key == x_agent_key) | (Device.pending_key == x_agent_key)).first()
        if match:
            return True
    raise HTTPException(status_code=401, detail="Unauthorized: Invalid or missing API Key")


def clean_domain_input(raw: str) -> str:
    if not raw:
        return ""
    raw = raw.strip().lower()
    if "://" in raw:
        parsed = urlparse(raw)
        host = parsed.netloc or parsed.path
    elif "/" in raw or ":" in raw:
        parsed = urlparse("//" + raw)
        host = parsed.netloc or parsed.path
    else:
        host = raw
    host = host.split(":")[0].strip("/. ")
    return host


def verify_admin(x_admin_key: Optional[str] = Header(None)):
    if x_admin_key == ADMIN_API_KEY:
        return True
    raise HTTPException(status_code=401, detail="Unauthorized: Admin Key required")


LATEST_AGENT_VERSION = os.getenv("LATEST_AGENT_VERSION", "1.0.9")


# --- Versioning & Auto-Update Endpoints ---
@app.get("/api/agent/version")
def get_agent_version(_: bool = Depends(verify_agent_or_admin)):
    """Returns the latest agent version and download path."""
    return {
        "version": LATEST_AGENT_VERSION,
        "download_url": "/api/agent/download"
    }


@app.get("/api/agent/download")
def download_agent_script(_: bool = Depends(verify_agent_or_admin)):
    """Serves the latest agent.ps1 file for client self-updates."""
    candidates = [
        os.path.join(os.path.dirname(__file__), "..", "client", "agent.ps1"),
        os.path.join(os.path.dirname(__file__), "agent.ps1"),
        os.path.abspath("client/agent.ps1"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return FileResponse(path, media_type="text/plain", filename="agent.ps1")
    raise HTTPException(status_code=404, detail="Agent script not found on server")


@app.get("/api/client/zip")
def download_client_zip(server_url: Optional[str] = None):
    """Serves the complete client installer package as a ZIP."""
    client_dir = os.path.join(os.path.dirname(__file__), "client")
    if not os.path.exists(client_dir):
        client_dir = os.path.join(os.path.dirname(__file__), "..", "client")
    if not os.path.exists(client_dir):
        raise HTTPException(status_code=404, detail="Client directory not found")

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for fname in ["agent.ps1", "install.ps1", "deploy_silent.bat", "uninstall.ps1"]:
            fpath = os.path.join(client_dir, fname)
            if os.path.exists(fpath):
                z.write(fpath, arcname=fname)

        srv = server_url or "http://localhost:8000"
        bat = (
            "@echo off\r\n"
            "net session >nul 2>&1\r\n"
            "if %errorlevel% neq 0 (\r\n"
            '    echo Elevando privilegios de Administrador...\r\n'
            '    powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "Start-Process cmd -ArgumentList \'/c \"\"%~f0\"\"\' -Verb RunAs"\r\n'
            "    exit /b\r\n"
            ")\r\n"
            "echo Instalando WebBlock Enterprise Agent (Bypass de directivas activo)...\r\n"
            f'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1" -ServerUrl "{srv}" -ApiKey "{AGENT_API_KEY}" -Silent\r\n'
            "echo Instalacion completada exitosamente.\r\n"
            "timeout /t 5\r\n"
        )
        z.writestr("instalar_automatico.bat", bat)

    buf.seek(0)
    return Response(
        content=buf.getvalue(),
        media_type="application/zip",
        headers={"Content-Disposition": "attachment; filename=WebBlock-Client.zip"}
    )


# --- Agent Endpoints ---
@app.post("/api/heartbeat", dependencies=[Depends(verify_agent_or_admin)])
def heartbeat(
    data: HeartbeatRequest,
    x_agent_key: Optional[str] = Header(None),
    db: Session = Depends(get_db),
):
    """Registers or updates device, tracks reported API key, returns active blocklist and pending new keys."""
    device = db.query(Device).filter(Device.serial_number == data.serial_number).first()
    now = datetime.now(timezone.utc)
    if not device:
        device = Device(
            serial_number=data.serial_number,
            brand=data.brand,
            last_ip=data.last_ip,
            last_ssid=data.last_ssid,
            version=data.version or "",
            last_ping=now,
            current_key=x_agent_key or "",
        )
        db.add(device)
    else:
        device.brand = data.brand
        device.last_ip = data.last_ip
        device.last_ssid = data.last_ssid
        device.last_ping = now
        if data.version:
            device.version = data.version
        # If the device called with its pending_key, rotation is confirmed!
        if device.pending_key and x_agent_key == device.pending_key:
            device.current_key = device.pending_key
            device.pending_key = None
        elif x_agent_key and not device.current_key:
            device.current_key = x_agent_key

    db.commit()
    db.refresh(device)

    # Active blocked domains included to minimize Starlink round-trips
    blocked = [d.domain for d in db.query(BlockedDomain).filter(BlockedDomain.is_active == True).all()]
    resp = {"device_id": device.id, "blocked_domains": blocked}
    if device.pending_key:
        resp["new_api_key"] = device.pending_key
    return resp


@app.get("/api/blocked-domains")
def get_active_blocked_domains(db: Session = Depends(get_db)):
    """Returns active blocked domain names list for clients."""
    rows = db.query(BlockedDomain).filter(BlockedDomain.is_active == True).all()
    return [r.domain for r in rows]


@app.post("/api/activity", dependencies=[Depends(verify_agent_or_admin)])
def ingest_activity(
    payload: BatchActivityRequest,
    x_agent_key: Optional[str] = Header(None),
    db: Session = Depends(get_db),
):
    """Ingests a batch of activity records buffered during offline/Starlink drops."""
    device = db.query(Device).filter(Device.id == payload.device_id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    # Confirm key rotation immediately on telemetry flush
    if x_agent_key and device.pending_key and x_agent_key == device.pending_key:
        device.current_key = device.pending_key
        device.pending_key = None
        db.commit()
    elif x_agent_key and not device.current_key:
        device.current_key = x_agent_key
        db.commit()

    items = payload.activities if isinstance(payload.activities, list) else [payload.activities]

    records = []
    for item in items:
        clean = clean_domain_input(item.domain)
        if clean and "." in clean:
            records.append(
                WebActivity(
                    device_id=payload.device_id,
                    domain=clean,
                    duration_seconds=item.duration_seconds,
                    logged_at=item.logged_at or datetime.now(timezone.utc),
                )
            )
    if records:
        db.bulk_save_objects(records)
        db.commit()
    return {"status": "ok", "inserted": len(records)}


# --- Dashboard Management Endpoints ---
@app.get("/api/devices")
def list_devices(db: Session = Depends(get_db)):
    """Lists all devices and online status (pinged in last 10 minutes)."""
    devices = db.query(Device).all()
    now = datetime.now(timezone.utc)
    result = []
    for d in devices:
        ping = d.last_ping.replace(tzinfo=timezone.utc) if d.last_ping.tzinfo is None else d.last_ping
        is_online = (now - ping).total_seconds() < 600
        result.append({
            "id": d.id,
            "serial_number": d.serial_number,
            "brand": d.brand,
            "last_ip": d.last_ip,
            "last_ssid": d.last_ssid,
            "last_ping": d.last_ping.isoformat(),
            "is_online": is_online,
        })
    return result


@app.get("/api/blocked-domains/all")
def list_all_blocked_domains(db: Session = Depends(get_db)):
    return db.query(BlockedDomain).all()


@app.post("/api/blocked-domains", dependencies=[Depends(verify_admin)])
def add_blocked_domain(data: BlockDomainCreate, db: Session = Depends(get_db)):
    domain_clean = clean_domain_input(data.domain)
    if not domain_clean or "." not in domain_clean:
        raise HTTPException(status_code=400, detail="Invalid domain or subdomain format")
    existing = db.query(BlockedDomain).filter(BlockedDomain.domain == domain_clean).first()
    if existing:
        existing.is_active = True
        db.commit()
        db.refresh(existing)
        return existing

    new_entry = BlockedDomain(domain=domain_clean, added_by=data.added_by, is_active=True)
    db.add(new_entry)
    db.commit()
    db.refresh(new_entry)
    return new_entry


@app.patch("/api/blocked-domains/{domain_id}", dependencies=[Depends(verify_admin)])
def toggle_blocked_domain(domain_id: str, data: BlockDomainToggle, db: Session = Depends(get_db)):
    entry = db.query(BlockedDomain).filter(BlockedDomain.id == domain_id).first()
    if not entry:
        raise HTTPException(status_code=404, detail="Domain not found")
    entry.is_active = data.is_active
    db.commit()
    return {"id": entry.id, "domain": entry.domain, "is_active": entry.is_active}


@app.delete("/api/blocked-domains/{domain_id}", dependencies=[Depends(verify_admin)])
def delete_blocked_domain(domain_id: str, db: Session = Depends(get_db)):
    entry = db.query(BlockedDomain).filter(BlockedDomain.id == domain_id).first()
    if not entry:
        raise HTTPException(status_code=404, detail="Domain not found")
    db.delete(entry)
    db.commit()
    return {"status": "deleted", "id": domain_id}


@app.post("/api/admin/cleanup", dependencies=[Depends(verify_admin)])
def cleanup_old_records(days: int = Query(60, ge=1, le=365), db: Session = Depends(get_db)):
    """Deletes activity logs older than specified days to keep PostgreSQL lean."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    deleted = db.query(WebActivity).filter(WebActivity.logged_at < cutoff).delete()
    db.commit()
    return {"status": "ok", "deleted_records": deleted, "cutoff": cutoff.isoformat()}


@app.get("/api/metrics/export-csv")
def export_csv(db: Session = Depends(get_db)):
    """Exports activity data as CSV compatible with Microsoft Excel."""
    rows = (
        db.query(
            WebActivity.logged_at,
            Device.serial_number,
            Device.brand,
            Device.last_ssid,
            WebActivity.domain,
            WebActivity.duration_seconds,
        )
        .join(Device, WebActivity.device_id == Device.id)
        .order_by(WebActivity.logged_at.desc())
        .limit(5000)
        .all()
    )
    output = io.StringIO()
    output.write('\ufeff')  # UTF-8 BOM
    writer = csv.writer(output)
    writer.writerow(["Fecha y Hora (UTC)", "Serie Equipo", "Marca", "SSID Starlink", "Dominio Visitado", "Duracion (Segundos)"])
    for r in rows:
        writer.writerow([r[0].isoformat() if r[0] else "", r[1], r[2], r[3], r[4], r[5]])

    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=webblock_reporte_navegacion.csv"}
    )


# --- Analytics & Metrics Endpoints ---
@app.get("/api/metrics/top-domains")
def get_top_domains(limit: int = Query(10, ge=1, le=100), db: Session = Depends(get_db)):
    """Top visited domains sorted by aggregated focus time."""
    rows = (
        db.query(
            WebActivity.domain,
            func.sum(WebActivity.duration_seconds).label("total_seconds"),
            func.count(WebActivity.id).label("hits"),
        )
        .group_by(WebActivity.domain)
        .order_by(func.sum(WebActivity.duration_seconds).desc())
        .limit(limit)
        .all()
    )
    return [{"domain": r[0], "total_seconds": r[1], "hits": r[2]} for r in rows]


@app.get("/api/metrics/device/{device_id}")
def get_device_activity(device_id: str, db: Session = Depends(get_db)):
    """Detailed domain activity summary for a single device."""
    rows = (
        db.query(
            WebActivity.domain,
            func.sum(WebActivity.duration_seconds).label("total_seconds"),
            func.count(WebActivity.id).label("hits"),
        )
        .filter(WebActivity.device_id == device_id)
        .group_by(WebActivity.domain)
        .order_by(func.sum(WebActivity.duration_seconds).desc())
        .all()
    )
    return [{"domain": r[0], "total_seconds": r[1], "hits": r[2]} for r in rows]
