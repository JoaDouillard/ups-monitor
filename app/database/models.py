"""
Modèles SQLAlchemy pour la persistance des données UPS.
"""

from datetime import datetime, timezone
from sqlalchemy import (
    Column, Integer, Float, Boolean, String, DateTime, Text, Index
)
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


class UpsReading(Base):
    """
    Enregistrement d'une mesure SNMP à un instant T.
    Toutes les valeurs numériques sont stockées telles que converties par oids.py.
    """
    __tablename__ = "ups_readings"

    id = Column(Integer, primary_key=True, autoincrement=True)
    timestamp = Column(DateTime(timezone=True), nullable=False, index=True,
                       default=lambda: datetime.now(timezone.utc))

    # Disponibilité
    reachable = Column(Boolean, nullable=False, default=True)

    # --- Batterie ---
    bat_capacity = Column(Integer)           # %
    bat_runtime_seconds = Column(Integer)    # minutes (après conversion)
    bat_voltage = Column(Float)              # V DC
    bat_abm_status = Column(Integer)         # enum int
    bat_failure = Column(Boolean)
    bat_aged = Column(Boolean)
    bat_low_capacity = Column(Boolean)

    # --- Entrée ---
    input_voltage = Column(Float)            # V RMS
    input_frequency = Column(Float)          # Hz
    input_source = Column(Integer)           # enum int
    input_status = Column(Integer)           # enum int

    # --- Sortie ---
    output_source = Column(Integer)          # enum int (5=batterie)
    output_status = Column(Integer)          # enum int
    output_voltage = Column(Float)           # V RMS
    output_frequency = Column(Float)         # Hz
    output_watts = Column(Integer)           # W
    output_load_percent = Column(Integer)    # %
    output_va = Column(Integer)              # VA

    # --- Alarmes ---
    alarm_count = Column(Integer)

    __table_args__ = (
        Index("idx_readings_timestamp", "timestamp"),
    )


class ActionLog(Base):
    """Journal des actions déclenchées (alertes, shutdowns, scripts)."""
    __tablename__ = "action_log"

    id = Column(Integer, primary_key=True, autoincrement=True)
    timestamp = Column(DateTime(timezone=True), nullable=False,
                       default=lambda: datetime.now(timezone.utc))
    action_name = Column(String(64), nullable=False)
    trigger_reason = Column(Text)
    success = Column(Boolean, default=True)
    details = Column(Text)

    __table_args__ = (
        Index("idx_action_timestamp", "timestamp"),
    )


class AlertLog(Base):
    """Journal des alertes (emails, logs système)."""
    __tablename__ = "alert_log"

    id = Column(Integer, primary_key=True, autoincrement=True)
    timestamp = Column(DateTime(timezone=True), nullable=False,
                       default=lambda: datetime.now(timezone.utc))
    level = Column(String(16), nullable=False)  # INFO / WARNING / CRITICAL
    message = Column(Text, nullable=False)
    acknowledged = Column(Boolean, default=False)

    __table_args__ = (
        Index("idx_alert_timestamp", "timestamp"),
    )
