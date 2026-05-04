"""
Endpoints API pour les données UPS : statut temps réel, historique,
alertes, actions, et WebSocket live.
"""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timezone
from typing import Any
try:
    from typing import Annotated
except ImportError:
    from typing_extensions import Annotated  # Python 3.8

from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect, Query
from pydantic import BaseModel

from app.api.routes_auth import CurrentUser, get_current_user
from app.database import db as database
from app.database.models import UpsReading, AlertLog, ActionLog
from app.poller.oids import POLLING_BY_NAME, OUTPUT_SOURCE, BATTERY_ABM_STATUS, OUTPUT_STATUS

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["data"])


# ---------------------------------------------------------------------------
# Schémas de réponse Pydantic
# ---------------------------------------------------------------------------

class ReadingOut(BaseModel):
    id: int
    timestamp: datetime
    reachable: bool

    bat_capacity: int | None
    bat_runtime_seconds: int | None
    bat_voltage: float | None
    bat_abm_status: int | None
    bat_abm_status_label: str | None
    bat_failure: bool | None
    bat_aged: bool | None

    input_voltage: float | None
    input_frequency: float | None
    input_source: int | None
    input_status: int | None

    output_source: int | None
    output_source_label: str | None
    output_status: int | None
    output_status_label: str | None
    output_voltage: float | None
    output_frequency: float | None
    output_watts: int | None
    output_load_percent: int | None
    output_va: int | None

    alarm_count: int | None

    class Config:
        from_attributes = True


class AlertOut(BaseModel):
    id: int
    timestamp: datetime
    level: str
    message: str
    acknowledged: bool

    class Config:
        from_attributes = True


class ActionOut(BaseModel):
    id: int
    timestamp: datetime
    action_name: str
    trigger_reason: str | None
    success: bool
    details: str | None

    class Config:
        from_attributes = True


class UpsInfoOut(BaseModel):
    manufacturer: str | None
    model: str | None
    firmware: str | None
    serial_number: str | None
    rated_power_watts: int | None
    battery_last_replaced: str | None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _enrich(reading: UpsReading) -> dict:
    """Ajoute les labels lisibles aux champs enum."""
    d = {c.name: getattr(reading, c.name) for c in reading.__table__.columns}
    d["bat_abm_status_label"] = BATTERY_ABM_STATUS.get(d.get("bat_abm_status", 0), "?")
    d["output_source_label"] = OUTPUT_SOURCE.get(d.get("output_source", 0), "?")
    d["output_status_label"] = OUTPUT_STATUS.get(d.get("output_status", 0), "?")
    return d


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/status", response_model=ReadingOut)
async def get_status(_: CurrentUser):
    """Renvoie le dernier enregistrement SNMP."""
    reading = await database.get_latest_reading()
    if reading is None:
        raise HTTPException(status_code=503, detail="Aucune donnée disponible")
    return _enrich(reading)


@router.get("/history", response_model=list[ReadingOut])
async def get_history(
    _: CurrentUser,
    hours: int = Query(default=24, ge=1, le=720),
):
    """Renvoie l'historique des N dernières heures."""
    readings = await database.get_readings_since(hours)
    return [_enrich(r) for r in readings]


@router.get("/alerts", response_model=list[AlertOut])
async def get_alerts(
    _: CurrentUser,
    limit: int = Query(default=50, ge=1, le=500),
):
    """Renvoie les alertes récentes."""
    return await database.get_recent_alerts(limit)


@router.get("/actions", response_model=list[ActionOut])
async def get_actions(
    _: CurrentUser,
    limit: int = Query(default=50, ge=1, le=500),
):
    """Renvoie le journal des actions déclenchées."""
    return await database.get_recent_actions(limit)


# Stocké par main.py au démarrage
_ups_info: dict[str, Any] = {}


@router.get("/info", response_model=UpsInfoOut)
async def get_info(_: CurrentUser):
    """Renvoie les informations statiques de l'onduleur."""
    return _ups_info


@router.post("/alerts/{alert_id}/acknowledge")
async def acknowledge_alert(alert_id: int, _: CurrentUser):
    """Marque une alerte comme acquittée."""
    from sqlalchemy import select, update
    from app.database.db import AsyncSessionLocal
    from app.database.models import AlertLog

    async with AsyncSessionLocal() as session:
        result = await session.execute(select(AlertLog).where(AlertLog.id == alert_id))
        alert = result.scalar_one_or_none()
        if alert is None:
            raise HTTPException(status_code=404, detail="Alerte introuvable")
        alert.acknowledged = True
        await session.commit()
    return {"ok": True}


# ---------------------------------------------------------------------------
# WebSocket — mises à jour temps réel
# ---------------------------------------------------------------------------

class _ConnectionManager:
    def __init__(self):
        self._clients: list[WebSocket] = []
        self._lock = asyncio.Lock()

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        async with self._lock:
            self._clients.append(ws)
        logger.debug("WebSocket connecté — %d client(s) actif(s)", len(self._clients))

    async def disconnect(self, ws: WebSocket) -> None:
        async with self._lock:
            self._clients = [c for c in self._clients if c is not ws]
        logger.debug("WebSocket déconnecté — %d client(s) actif(s)", len(self._clients))

    async def broadcast(self, data: dict) -> None:
        if not self._clients:
            return
        payload = json.dumps(data, default=str)
        dead = []
        async with self._lock:
            clients = list(self._clients)
        for ws in clients:
            try:
                await ws.send_text(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            await self.disconnect(ws)


ws_manager = _ConnectionManager()


@router.websocket("/ws/live")
async def websocket_live(websocket: WebSocket):
    """
    WebSocket authentifié par cookie ou query param token.
    Pousse les nouvelles données en temps réel à chaque poll.
    """
    # Authentification via cookie
    token = websocket.cookies.get("ups_token") or websocket.query_params.get("token")
    if not token:
        await websocket.close(code=4001, reason="Non authentifié")
        return

    from jose import JWTError, jwt
    from app.config import settings
    try:
        jwt.decode(token, settings.secret_key, algorithms=["HS256"])
    except JWTError:
        await websocket.close(code=4001, reason="Token invalide")
        return

    await ws_manager.connect(websocket)
    try:
        # Envoie immédiatement le dernier état connu
        reading = await database.get_latest_reading()
        if reading:
            await websocket.send_text(json.dumps(_enrich(reading), default=str))

        # Reste connecté jusqu'à déconnexion
        while True:
            try:
                await asyncio.wait_for(websocket.receive_text(), timeout=30)
            except asyncio.TimeoutError:
                # Ping pour maintenir la connexion
                await websocket.send_text(json.dumps({"type": "ping"}))
    except WebSocketDisconnect:
        pass
    finally:
        await ws_manager.disconnect(websocket)
