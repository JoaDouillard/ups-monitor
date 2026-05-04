"""
Registre des OIDs SNMP de l'onduleur Eaton 5PX 3000i RT2U G2.
Basé sur XUPS-MIB (enterprise .1.3.6.1.4.1.534.1) et validé
contre result.xml (export réel des requêtes SNMP sur l'onduleur).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Callable, Any, List, Dict


@dataclass
class OIDDef:
    oid: str
    name: str          # clé interne (snake_case)
    label: str         # libellé pour l'UI
    unit: str          # unité d'affichage
    convert: Optional[Callable[[Any], Any]] = None  # transformation post-SNMP
    enum_map: Optional[dict] = None  # mapping valeur entière → string


# ---------------------------------------------------------------------------
# Fonctions de conversion
# ---------------------------------------------------------------------------

def _div10(v) -> float:
    """Fréquence : valeur SNMP en dixièmes de Hz → Hz."""
    return round(int(v) / 10.0, 1)


def _seconds_to_minutes(v) -> int:
    """Autonomie batterie : secondes → minutes."""
    return int(v) // 60


def _enum_int(v) -> int:
    """Extrait l'entier d'une valeur enum SNMP (ex: 'batteryFloating (3)' → 3)."""
    s = str(v)
    if "(" in s:
        try:
            return int(s.split("(")[-1].rstrip(")").strip())
        except ValueError:
            pass
    try:
        return int(s)
    except ValueError:
        return 0


def _bool_from_12(v) -> bool:
    """yes(1)=True, no(2)=False."""
    return _enum_int(v) == 1


# ---------------------------------------------------------------------------
# Enums XUPS-MIB
# ---------------------------------------------------------------------------

BATTERY_ABM_STATUS = {
    1: "En charge",
    2: "En décharge",
    3: "Flottant (plein)",
    4: "Au repos",
    5: "Inconnu",
    6: "Batterie déconnectée",
    7: "Test en cours",
    8: "Vérifier batterie",
}

OUTPUT_SOURCE = {
    1: "Autre",
    2: "Aucune sortie",
    3: "Secteur (normal)",
    4: "Bypass",
    5: "Batterie",
    6: "Booster",
    7: "Réducteur",
    8: "Parallèle capacité",
    9: "Parallèle redondant",
    10: "Mode haute efficacité",
    11: "Bypass maintenance",
    12: "Mode ESS",
}

INPUT_SOURCE = {
    1: "Autre",
    2: "Aucune",
    3: "Secteur principal",
    4: "Alimentation bypass",
    5: "Secteur secondaire",
    6: "Générateur",
    7: "Volant d'inertie",
    8: "Pile à combustible",
}

INPUT_STATUS = {
    1: "Défaut entrée",
    2: "Entrée correcte",
}

OUTPUT_STATUS = {
    0: "Inconnu",
    1: "Sortie hors tension",
    2: "Non protégée",
    3: "Protégée",
    4: "Alimentée sans continuité",
}


# ---------------------------------------------------------------------------
# Définition des OIDs à interroger à chaque cycle de polling
# ---------------------------------------------------------------------------

POLLING_OIDS: list[OIDDef] = [
    # --- Batterie ---
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.2.4.0",
        name="bat_capacity",
        label="Capacité batterie",
        unit="%",
        convert=int,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.2.1.0",
        name="bat_runtime_seconds",
        label="Autonomie",
        unit="min",
        convert=_seconds_to_minutes,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.2.2.0",
        name="bat_voltage",
        label="Tension batterie",
        unit="V DC",
        convert=int,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.2.5.0",
        name="bat_abm_status",
        label="État batterie (ABM)",
        unit="",
        convert=_enum_int,
        enum_map=BATTERY_ABM_STATUS,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.2.7.0",
        name="bat_failure",
        label="Défaut batterie",
        unit="",
        convert=_bool_from_12,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.2.9.0",
        name="bat_aged",
        label="Batterie vieillie",
        unit="",
        convert=_bool_from_12,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.2.10.0",
        name="bat_low_capacity",
        label="Capacité basse",
        unit="",
        convert=_bool_from_12,
    ),

    # --- Entrée ---
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.3.4.1.2.1",
        name="input_voltage",
        label="Tension entrée",
        unit="V",
        convert=int,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.3.1.0",
        name="input_frequency",
        label="Fréquence entrée",
        unit="Hz",
        convert=_div10,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.3.5.0",
        name="input_source",
        label="Source entrée",
        unit="",
        convert=_enum_int,
        enum_map=INPUT_SOURCE,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.3.9.0",
        name="input_status",
        label="État entrée",
        unit="",
        convert=_enum_int,
        enum_map=INPUT_STATUS,
    ),

    # --- Sortie ---
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.4.5.0",
        name="output_source",
        label="Source sortie",
        unit="",
        convert=_enum_int,
        enum_map=OUTPUT_SOURCE,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.4.10.0",
        name="output_status",
        label="État sortie",
        unit="",
        convert=_enum_int,
        enum_map=OUTPUT_STATUS,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.4.4.1.2.1",
        name="output_voltage",
        label="Tension sortie",
        unit="V",
        convert=int,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.4.2.0",
        name="output_frequency",
        label="Fréquence sortie",
        unit="Hz",
        convert=_div10,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.4.4.1.4.1",
        name="output_watts",
        label="Puissance active sortie",
        unit="W",
        convert=int,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.4.4.1.8.1",
        name="output_load_percent",
        label="Charge sortie",
        unit="%",
        convert=int,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.4.4.1.9.1",
        name="output_va",
        label="Puissance apparente sortie",
        unit="VA",
        convert=int,
    ),

    # --- Alarmes ---
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.7.1.0",
        name="alarm_count",
        label="Alarmes actives",
        unit="",
        convert=int,
    ),
]

# OIDs d'information statique (lus une fois au démarrage)
INFO_OIDS: list[OIDDef] = [
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.1.1.0",
        name="manufacturer",
        label="Fabricant",
        unit="",
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.1.2.0",
        name="model",
        label="Modèle",
        unit="",
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.1.3.0",
        name="firmware",
        label="Firmware",
        unit="",
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.1.6.0",
        name="serial_number",
        label="Numéro de série",
        unit="",
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.10.3.0",
        name="rated_power_watts",
        label="Puissance nominale",
        unit="W",
        convert=int,
    ),
    OIDDef(
        oid=".1.3.6.1.4.1.534.1.2.6.0",
        name="battery_last_replaced",
        label="Dernière remplacement batterie",
        unit="",
    ),
]

# Index par nom pour accès rapide
POLLING_BY_NAME = {o.name: o for o in POLLING_OIDS}
INFO_BY_NAME = {o.name: o for o in INFO_OIDS}
