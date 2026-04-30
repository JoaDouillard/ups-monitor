"""
Point d'entrée FastAPI — orchestre le poller SNMP, la base de données,
les actions et l'interface web.
"""

import asyncio
import logging
import logging.config
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.database.db import init_db, save_reading, purge_old_readings
from app.poller.snmp_poller import poll_ups, get_ups_info
from app.actions.action_manager import evaluate
from app.api.routes_auth import router as auth_router
from app.api.routes_data import router as data_router, ws_manager, _ups_info

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Tâche de polling en arrière-plan
# ---------------------------------------------------------------------------

async def _polling_loop() -> None:
    """Boucle principale : poll SNMP → sauvegarde → évaluation → broadcast WS."""
    logger.info(
        "Démarrage du polling SNMP (intervalle : %ds, hôte : %s)",
        settings.poll_interval,
        settings.ups_host,
    )

    consecutive_failures = 0

    while True:
        try:
            data = await poll_ups()

            if data is None:
                consecutive_failures += 1
                logger.warning(
                    "Poll SNMP échoué (tentative %d) — UPS injoignable ?",
                    consecutive_failures,
                )
                data = {"reachable": False}
                if consecutive_failures >= 3:
                    await evaluate(data)
            else:
                consecutive_failures = 0
                await save_reading(data)
                await evaluate(data)
                await ws_manager.broadcast(data)

        except Exception as exc:
            logger.exception("Erreur inattendue dans la boucle de polling : %s", exc)

        await asyncio.sleep(settings.poll_interval)


async def _purge_loop() -> None:
    """Purge quotidienne des anciens enregistrements."""
    while True:
        await asyncio.sleep(86400)  # 24h
        try:
            await purge_old_readings()
        except Exception as exc:
            logger.error("Erreur lors de la purge : %s", exc)


# ---------------------------------------------------------------------------
# Lifecycle FastAPI
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Démarrage
    logger.info("=== UPS Monitor démarrage ===")
    await init_db()

    # Lecture des informations statiques de l'UPS
    info = await get_ups_info()
    _ups_info.update(info)
    if info:
        logger.info(
            "UPS identifié : %s — %s (S/N: %s, FW: %s)",
            info.get("manufacturer", "?"),
            info.get("model", "?"),
            info.get("serial_number", "?"),
            info.get("firmware", "?"),
        )
    else:
        logger.warning("Impossible de lire les infos UPS — vérifier la connexion SNMP.")

    # Lancement des tâches d'arrière-plan
    polling_task = asyncio.create_task(_polling_loop(), name="snmp_poller")
    purge_task = asyncio.create_task(_purge_loop(), name="purge_worker")

    yield

    # Arrêt propre
    logger.info("=== UPS Monitor arrêt ===")
    polling_task.cancel()
    purge_task.cancel()
    try:
        await polling_task
    except asyncio.CancelledError:
        pass
    try:
        await purge_task
    except asyncio.CancelledError:
        pass


# ---------------------------------------------------------------------------
# Application FastAPI
# ---------------------------------------------------------------------------

app = FastAPI(
    title="UPS Monitor",
    description="Monitoring Eaton 5PX 3000i RT2U G2 via SNMPv3",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/api/docs",
    redoc_url=None,
)

# Routes API
app.include_router(auth_router)
app.include_router(data_router)

# Fichiers statiques (CSS, JS)
_WEB_DIR = Path(__file__).parent / "web"
app.mount("/static", StaticFiles(directory=str(_WEB_DIR)), name="static")


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
async def index(request: Request):
    """Sert le dashboard. Redirige vers le login si non authentifié."""
    return FileResponse(str(_WEB_DIR / "index.html"))


@app.get("/health", include_in_schema=False)
async def health():
    return {"status": "ok"}
