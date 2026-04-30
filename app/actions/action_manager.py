"""
Gestionnaire d'actions : évalue les seuils après chaque poll et déclenche
les actions configurées avec protection anti-rebond (cooldown).

Actions disponibles :
  - alert_warning  : alerte de niveau WARNING
  - alert_critical : alerte de niveau CRITICAL
  - shutdown_vms   : arrêt des VMs XenServer
"""

import asyncio
import logging
from datetime import datetime, timezone, timedelta
from dataclasses import dataclass, field
from typing import Callable, Awaitable, Any

from app.actions.alert import send_alert
from app.actions.shutdown import trigger_xenserver_shutdown

logger = logging.getLogger(__name__)


@dataclass
class ActionRule:
    """Définit une règle de déclenchement d'action."""
    name: str
    # Condition : fonction async ou sync prenant le dict de métriques → bool
    condition: Callable[[dict], bool]
    action: str               # "alert_warning" | "alert_critical" | "shutdown_vms"
    message_template: str     # peut utiliser {bat_capacity}, {output_source}, etc.
    cooldown_minutes: int = 5
    _last_triggered: datetime | None = field(default=None, repr=False, compare=False)

    def is_on_cooldown(self) -> bool:
        if self._last_triggered is None:
            return False
        return datetime.now(timezone.utc) - self._last_triggered < timedelta(minutes=self.cooldown_minutes)

    def mark_triggered(self) -> None:
        self._last_triggered = datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# Règles par défaut
# ---------------------------------------------------------------------------

_DEFAULT_RULES: list[ActionRule] = [
    # Passage sur batterie
    ActionRule(
        name="on_battery",
        condition=lambda m: m.get("output_source") == 5,
        action="alert_critical",
        message_template=(
            "L'UPS est sur BATTERIE ! "
            "Capacité : {bat_capacity}% — Autonomie : {bat_runtime_seconds} min"
        ),
        cooldown_minutes=10,
    ),

    # Retour sur secteur (après passage batterie)
    ActionRule(
        name="back_on_mains",
        condition=lambda m: (
            m.get("output_source") == 3
            and m.get("_prev_output_source") == 5
        ),
        action="alert_warning",
        message_template="Retour sur SECTEUR. Capacité batterie : {bat_capacity}%",
        cooldown_minutes=5,
    ),

    # Batterie faible → alerte
    ActionRule(
        name="low_battery_alert",
        condition=lambda m: (
            m.get("bat_capacity") is not None
            and m["bat_capacity"] < 30
            and m.get("output_source") == 5
        ),
        action="alert_critical",
        message_template=(
            "BATTERIE FAIBLE : {bat_capacity}% — Autonomie : {bat_runtime_seconds} min"
        ),
        cooldown_minutes=5,
    ),

    # Batterie critique → shutdown
    ActionRule(
        name="critical_battery_shutdown",
        condition=lambda m: (
            m.get("bat_capacity") is not None
            and m["bat_capacity"] < 15
            and m.get("output_source") == 5
        ),
        action="shutdown_vms",
        message_template=(
            "Batterie critique : {bat_capacity}% — Autonomie : {bat_runtime_seconds} min"
        ),
        cooldown_minutes=60,
    ),

    # Autonomie critique → shutdown
    ActionRule(
        name="critical_runtime_shutdown",
        condition=lambda m: (
            m.get("bat_runtime_seconds") is not None
            and m["bat_runtime_seconds"] < 5
            and m.get("output_source") == 5
        ),
        action="shutdown_vms",
        message_template=(
            "Autonomie critique : {bat_runtime_seconds} min — Batterie : {bat_capacity}%"
        ),
        cooldown_minutes=60,
    ),

    # Défaut batterie
    ActionRule(
        name="battery_failure",
        condition=lambda m: m.get("bat_failure") is True,
        action="alert_critical",
        message_template="DÉFAUT BATTERIE détecté sur l'UPS !",
        cooldown_minutes=60,
    ),

    # Batterie vieillie
    ActionRule(
        name="battery_aged",
        condition=lambda m: m.get("bat_aged") is True,
        action="alert_warning",
        message_template="La batterie de l'UPS est vieillie — remplacement recommandé.",
        cooldown_minutes=1440,  # 1 fois par jour
    ),

    # Sortie non protégée
    ActionRule(
        name="output_not_protected",
        condition=lambda m: m.get("output_status") in (1, 2),
        action="alert_critical",
        message_template="Sortie UPS NON PROTÉGÉE (status={output_status})",
        cooldown_minutes=15,
    ),

    # UPS injoignable
    ActionRule(
        name="ups_unreachable",
        condition=lambda m: not m.get("reachable", True),
        action="alert_critical",
        message_template="UPS INJOIGNABLE via SNMP !",
        cooldown_minutes=5,
    ),
]

# État précédent pour les règles de transition
_prev_metrics: dict[str, Any] = {}

# Instance des règles (peut être étendue depuis main.py)
rules: list[ActionRule] = list(_DEFAULT_RULES)


async def evaluate(metrics: dict[str, Any]) -> None:
    """
    Évalue toutes les règles contre les métriques actuelles.
    Déclenche les actions dont la condition est vraie et le cooldown expiré.
    """
    global _prev_metrics

    # Injecte l'état précédent pour les règles de transition
    enriched = dict(metrics)
    enriched["_prev_output_source"] = _prev_metrics.get("output_source")

    triggered = []
    for rule in rules:
        try:
            if not rule.condition(enriched):
                continue
        except Exception as exc:
            logger.error("Erreur évaluation règle '%s': %s", rule.name, exc)
            continue

        if rule.is_on_cooldown():
            logger.debug("Règle '%s' en cooldown, ignorée.", rule.name)
            continue

        # Construction du message
        try:
            message = rule.message_template.format(**{
                k: v for k, v in enriched.items() if not k.startswith("_")
            })
        except KeyError:
            message = rule.message_template

        triggered.append((rule, message))

    # Déclenche les actions (shutdown en dernier pour laisser les alertes passer)
    triggered.sort(key=lambda x: 1 if x[0].action == "shutdown_vms" else 0)

    for rule, message in triggered:
        rule.mark_triggered()
        logger.info("Règle déclenchée : '%s' → %s", rule.name, rule.action)
        await _dispatch(rule.action, message)

    _prev_metrics = dict(metrics)


async def _dispatch(action: str, message: str) -> None:
    """Exécute l'action demandée."""
    if action == "alert_warning":
        await send_alert("WARNING", message)
    elif action == "alert_critical":
        await send_alert("CRITICAL", message)
    elif action == "shutdown_vms":
        # Lance l'arrêt en tâche de fond pour ne pas bloquer le polling
        asyncio.create_task(trigger_xenserver_shutdown(message))
    else:
        logger.warning("Action inconnue : %s", action)
