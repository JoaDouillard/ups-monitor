"""
Configuration de la base de données SQLAlchemy asynchrone (SQLite + aiosqlite).
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone, timedelta

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy import select, delete

from app.config import settings
from app.database.models import Base, UpsReading, ActionLog, AlertLog

logger = logging.getLogger(__name__)

engine = create_async_engine(
    settings.database_url,
    echo=False,
    connect_args={"check_same_thread": False},
)

AsyncSessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


async def init_db() -> None:
    """Crée les tables si elles n'existent pas."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    logger.info("Base de données initialisée.")


async def get_session() -> AsyncSession:
    """Générateur de session pour FastAPI Depends."""
    async with AsyncSessionLocal() as session:
        yield session


async def save_reading(data: dict) -> UpsReading:
    """Persiste un enregistrement SNMP en base."""
    fields = {
        col.name: data.get(col.name)
        for col in UpsReading.__table__.columns
        if col.name not in ("id", "timestamp")
    }
    fields["reachable"] = data.get("reachable", False)

    reading = UpsReading(**fields)
    async with AsyncSessionLocal() as session:
        session.add(reading)
        await session.commit()
        await session.refresh(reading)

    return reading


async def get_latest_reading() -> UpsReading | None:
    """Renvoie le dernier enregistrement."""
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(UpsReading).order_by(UpsReading.timestamp.desc()).limit(1)
        )
        return result.scalar_one_or_none()


async def get_readings_since(hours: int = 24) -> list[UpsReading]:
    """Renvoie les enregistrements des N dernières heures."""
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(UpsReading)
            .where(UpsReading.timestamp >= since)
            .order_by(UpsReading.timestamp.asc())
        )
        return list(result.scalars().all())


async def log_action(action_name: str, reason: str, success: bool = True, details: str = "") -> None:
    """Enregistre une action déclenchée."""
    entry = ActionLog(
        action_name=action_name,
        trigger_reason=reason,
        success=success,
        details=details,
    )
    async with AsyncSessionLocal() as session:
        session.add(entry)
        await session.commit()


async def log_alert(level: str, message: str) -> None:
    """Enregistre une alerte."""
    entry = AlertLog(level=level, message=message)
    async with AsyncSessionLocal() as session:
        session.add(entry)
        await session.commit()


async def get_recent_alerts(limit: int = 50) -> list[AlertLog]:
    """Renvoie les alertes récentes."""
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(AlertLog).order_by(AlertLog.timestamp.desc()).limit(limit)
        )
        return list(result.scalars().all())


async def get_recent_actions(limit: int = 50) -> list[ActionLog]:
    """Renvoie les actions récentes."""
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            select(ActionLog).order_by(ActionLog.timestamp.desc()).limit(limit)
        )
        return list(result.scalars().all())


async def purge_old_readings() -> int:
    """Supprime les enregistrements plus anciens que HISTORY_RETENTION_DAYS jours."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=settings.history_retention_days)
    async with AsyncSessionLocal() as session:
        result = await session.execute(
            delete(UpsReading).where(UpsReading.timestamp < cutoff)
        )
        await session.commit()
        count = result.rowcount
    if count:
        logger.info("Purge : %d enregistrements supprimés (>%d jours).", count, settings.history_retention_days)
    return count
