"""
Arrêt propre des VMs XenServer via SSH + commande xe.

Séquence :
  1. Alerte immédiate
  2. Délai configurable (SHUTDOWN_DELAY_SECONDS)
  3. Arrêt de toutes les VMs en cours d'exécution
  4. Log du résultat
"""
from __future__ import annotations

import asyncio
import logging

from app.config import settings
from app.actions.alert import send_alert
from app.database import db as database

logger = logging.getLogger(__name__)

# Empêche un double déclenchement pendant l'exécution du shutdown
_shutdown_in_progress = False


async def trigger_xenserver_shutdown(reason: str) -> None:
    """
    Lance l'arrêt des VMs XenServer.
    Opération idempotente : ignorée si un arrêt est déjà en cours.
    """
    global _shutdown_in_progress

    if _shutdown_in_progress:
        logger.warning("Shutdown déjà en cours, demande ignorée.")
        return

    _shutdown_in_progress = True
    delay = settings.shutdown_delay_seconds

    await send_alert(
        "CRITICAL",
        f"ARRÊT XENSERVER DÉCLENCHÉ dans {delay}s — Raison : {reason}",
    )
    await database.log_action("xenserver_shutdown", reason)

    logger.critical("Arrêt XenServer dans %ds. Raison : %s", delay, reason)
    await asyncio.sleep(delay)

    if not settings.xenserver_host:
        logger.error("XENSERVER_HOST non configuré — arrêt annulé.")
        _shutdown_in_progress = False
        return

    success, output = await _run_xe_shutdown()

    await database.log_action(
        "xenserver_shutdown_executed",
        reason,
        success=success,
        details=output,
    )

    if success:
        logger.critical("Arrêt XenServer exécuté avec succès.")
        await send_alert("CRITICAL", f"Arrêt XenServer exécuté : {output}")
    else:
        logger.error("Échec de l'arrêt XenServer : %s", output)
        await send_alert("CRITICAL", f"ÉCHEC arrêt XenServer : {output}")

    _shutdown_in_progress = False


async def _run_xe_shutdown() -> tuple[bool, str]:
    """
    Exécute l'arrêt des VMs via SSH sur le XenServer.
    Retourne (succès, sortie de la commande).
    """
    host = settings.xenserver_host
    user = settings.xenserver_user
    password = settings.xenserver_password or ""

    # Commandes xe à exécuter séquentiellement
    xe_commands = [
        # Arrêt propre de toutes les VMs en cours
        "xe vm-shutdown --multiple power-state=running",
        # Délai pour laisser les VMs s'arrêter
        "sleep 30",
        # Arrêt forcé des VMs restantes
        'xe vm-list power-state=running --minimal | '
        'tr , "\\n" | '
        'xargs -I{} xe vm-shutdown uuid={} --force',
    ]
    cmd_str = " && ".join(xe_commands)

    # Construction de la commande SSH
    ssh_cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=10",
        "-o", "BatchMode=yes",  # pas de prompt interactif
    ]

    if password:
        # Utilise sshpass si disponible (à installer : apt install sshpass)
        ssh_cmd = ["sshpass", f"-p{password}"] + ssh_cmd

    ssh_cmd += [f"{user}@{host}", cmd_str]

    try:
        proc = await asyncio.create_subprocess_exec(
            *ssh_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=120)
        output = stdout.decode() + stderr.decode()
        success = proc.returncode == 0
        return success, output.strip()
    except asyncio.TimeoutError:
        return False, "Timeout SSH (120s dépassé)"
    except FileNotFoundError as exc:
        return False, f"Commande SSH introuvable : {exc}. Installer openssh-client (et sshpass pour auth par mot de passe)."
    except Exception as exc:
        return False, f"Erreur SSH : {exc}"
