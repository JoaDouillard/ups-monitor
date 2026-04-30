"""
Système d'alerte : log système + email SMTP optionnel.
"""

import logging
import smtplib
import ssl
from email.message import EmailMessage
from datetime import datetime

from app.config import settings
from app.database import db as database

logger = logging.getLogger(__name__)


async def send_alert(level: str, message: str) -> None:
    """
    Envoie une alerte :
    1. Log Python (niveau correspondant)
    2. Persistance en base
    3. Email si SMTP configuré
    """
    # 1. Log
    log_level = {
        "INFO": logging.INFO,
        "WARNING": logging.WARNING,
        "CRITICAL": logging.CRITICAL,
    }.get(level.upper(), logging.WARNING)
    logger.log(log_level, "[UPS ALERT %s] %s", level, message)

    # 2. Base de données
    await database.log_alert(level, message)

    # 3. Email (optionnel)
    if settings.smtp_host and settings.alert_email_to:
        await _send_email(level, message)


async def _send_email(level: str, message: str) -> None:
    """Envoi d'email via SMTP (synchrone dans un executor)."""
    import asyncio
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, _send_email_sync, level, message)


def _send_email_sync(level: str, message: str) -> None:
    subject = f"[UPS Monitor] {level} — {settings.ups_host}"
    body = (
        f"Alerte UPS Monitor\n"
        f"==================\n"
        f"Date    : {datetime.now().strftime('%d/%m/%Y %H:%M:%S')}\n"
        f"Niveau  : {level}\n"
        f"Hôte UPS: {settings.ups_host}\n\n"
        f"{message}\n"
    )

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = settings.smtp_from
    msg["To"] = settings.alert_email_to
    msg.set_content(body)

    try:
        if settings.smtp_tls:
            context = ssl.create_default_context()
            with smtplib.SMTP(settings.smtp_host, settings.smtp_port) as server:
                server.starttls(context=context)
                if settings.smtp_user:
                    server.login(settings.smtp_user, settings.smtp_password or "")
                server.send_message(msg)
        else:
            with smtplib.SMTP(settings.smtp_host, settings.smtp_port) as server:
                if settings.smtp_user:
                    server.login(settings.smtp_user, settings.smtp_password or "")
                server.send_message(msg)
        logger.info("Email d'alerte envoyé à %s", settings.alert_email_to)
    except Exception as exc:
        logger.error("Échec envoi email : %s", exc)
