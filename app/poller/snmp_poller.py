"""
Poller SNMP asynchrone — SNMPv3 avec authentification SHA et chiffrement AES.
Utilise pysnmp (lextudio fork, v7.x) — API snake_case.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from typing import Any, Optional

from pysnmp.hlapi.v3arch.asyncio import (
    SnmpEngine,
    UsmUserData,
    UdpTransportTarget,
    ContextData,
    ObjectType,
    ObjectIdentity,
    get_cmd,
    usmHMACSHAAuthProtocol,
    usmHMAC128SHA224AuthProtocol,
    usmHMAC192SHA256AuthProtocol,
    usmAesCfb128Protocol,
    usmDESPrivProtocol,
)
from pysnmp.proto.rfc1902 import OctetString, Integer, Gauge32, Counter32, TimeTicks

from app.config import settings
from app.poller.oids import POLLING_OIDS, INFO_OIDS, OIDDef

logger = logging.getLogger(__name__)

_AUTH_PROTOCOLS = {
    "SHA": usmHMACSHAAuthProtocol,
    "SHA224": usmHMAC128SHA224AuthProtocol,
    "SHA256": usmHMAC192SHA256AuthProtocol,
}

_PRIV_PROTOCOLS = {
    "AES": usmAesCfb128Protocol,
    "DES": usmDESPrivProtocol,
}


def _snmp_value_to_python(val: Any) -> Any:
    """Convertit un objet pysnmp en type Python natif."""
    if isinstance(val, OctetString):
        try:
            return val.prettyPrint()
        except Exception:
            return str(val)
    if isinstance(val, (Integer, Gauge32, Counter32, TimeTicks)):
        return int(val)
    return val.prettyPrint()


async def _get_one(
    engine: SnmpEngine,
    user_data: UsmUserData,
    transport: UdpTransportTarget,
    oid_def: OIDDef,
) -> tuple[str, Any]:
    """Interroge un unique OID et renvoie (name, valeur convertie)."""
    error_indication, error_status, error_index, var_binds = await get_cmd(
        engine,
        user_data,
        transport,
        ContextData(),
        ObjectType(ObjectIdentity(oid_def.oid)),
    )

    if error_indication:
        raise ConnectionError(f"SNMP error for {oid_def.name}: {error_indication}")
    if error_status:
        raise ValueError(
            f"SNMP PDU error for {oid_def.name}: "
            f"{error_status.prettyPrint()} at index {error_index}"
        )

    _, value = var_binds[0]
    raw = _snmp_value_to_python(value)

    if oid_def.convert is not None:
        try:
            raw = oid_def.convert(raw)
        except Exception as exc:
            logger.warning("Conversion error for %s (raw=%r): %s", oid_def.name, raw, exc)

    return oid_def.name, raw


async def poll_ups() -> Optional[dict[str, Any]]:
    """
    Interroge l'onduleur via SNMPv3 et renvoie un dict avec toutes
    les métriques de polling, plus un timestamp UTC.
    Renvoie None si l'onduleur est injoignable.
    """
    auth_proto = _AUTH_PROTOCOLS.get(settings.snmp_auth_protocol.upper(), usmHMACSHAAuthProtocol)
    priv_proto = _PRIV_PROTOCOLS.get(settings.snmp_priv_protocol.upper(), usmAesCfb128Protocol)

    engine = SnmpEngine()

    user_data = UsmUserData(
        settings.snmp_user,
        authKey=settings.snmp_auth_key,
        privKey=settings.snmp_priv_key,
        authProtocol=auth_proto,
        privProtocol=priv_proto,
    )

    try:
        transport = await UdpTransportTarget.create(
            (settings.ups_host, settings.ups_port),
            timeout=settings.snmp_timeout,
            retries=settings.snmp_retries,
        )
    except Exception as exc:
        logger.error("Cannot create SNMP transport to %s: %s", settings.ups_host, exc)
        return None

    result: dict[str, Any] = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "reachable": True,
    }

    failed = []
    for oid_def in POLLING_OIDS:
        try:
            name, value = await _get_one(engine, user_data, transport, oid_def)
            result[name] = value
        except Exception as exc:
            logger.warning("Failed to poll %s: %s", oid_def.name, exc)
            failed.append(oid_def.name)
            result[oid_def.name] = None

    if failed:
        logger.warning("OIDs non disponibles : %s", ", ".join(failed))

    try:
        engine.closeDispatcher()
    except Exception:
        pass
    return result


async def get_ups_info() -> dict[str, Any]:
    """
    Lit les OIDs d'information statique (modèle, série, firmware…).
    Appelé une fois au démarrage.
    """
    auth_proto = _AUTH_PROTOCOLS.get(settings.snmp_auth_protocol.upper(), usmHMACSHAAuthProtocol)
    priv_proto = _PRIV_PROTOCOLS.get(settings.snmp_priv_protocol.upper(), usmAesCfb128Protocol)

    engine = SnmpEngine()
    user_data = UsmUserData(
        settings.snmp_user,
        authKey=settings.snmp_auth_key,
        privKey=settings.snmp_priv_key,
        authProtocol=auth_proto,
        privProtocol=priv_proto,
    )

    try:
        transport = await UdpTransportTarget.create(
            (settings.ups_host, settings.ups_port),
            timeout=settings.snmp_timeout,
            retries=settings.snmp_retries,
        )
    except Exception as exc:
        logger.error("Cannot reach UPS for info: %s", exc)
        return {}

    info: dict[str, Any] = {}
    for oid_def in INFO_OIDS:
        try:
            name, value = await _get_one(engine, user_data, transport, oid_def)
            info[name] = value
        except Exception as exc:
            logger.warning("Info OID %s failed: %s", oid_def.name, exc)
            info[oid_def.name] = None

    try:
        engine.closeDispatcher()
    except Exception:
        pass
    return info
