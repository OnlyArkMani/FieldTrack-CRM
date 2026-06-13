"""Admin live WebSocket.

WS /ws/admin-live?token=<access_jwt>

AUTH: WebSockets can't carry an Authorization header from a browser, so the
access token comes as a query param. We verify it the same way as HTTP
(signature, expiry, type) and additionally require role == ADMIN — this feed
exposes every employee's live position, so it is admin-only.

BROADCAST MODEL (hybrid):
  • A Redis pub/sub subscription on the location-updates channel pushes a fresh
    snapshot the moment any device reports a new position (near-real-time).
  • A 15s heartbeat sends a snapshot regardless, so elapsed-time / "last seen"
    stays fresh even when nobody's moving, and a dropped pub/sub message
    self-heals within 15s.

Each connection owns its own pubsub + DB session. Closes are handled so a
dropped client never leaks a subscription.
"""
import asyncio
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.core.database import async_session_factory
from app.core.exceptions import ApiError
from app.core.redis import Keys, get_redis
from app.core.security import verify_token
from app.services.location_service import LocationService

logger = logging.getLogger("fieldtrack.ws")

router = APIRouter()

HEARTBEAT_SECONDS = 15

# Custom close codes (4000-4999 are app-defined).
_CLOSE_UNAUTHORIZED = 4401
_CLOSE_FORBIDDEN = 4403


async def _build_snapshot() -> dict:
    async with async_session_factory() as db:
        points = await LocationService(db).all_live()
    return {
        "type": "LOCATION_UPDATE",
        "server_time": datetime.now(timezone.utc).isoformat(),
        "employees": [p.model_dump(mode="json") for p in points],
    }


@router.websocket("/ws/admin-live")
async def admin_live(websocket: WebSocket, token: str = Query(...)) -> None:
    # ── Authenticate BEFORE accepting (reject with a close code) ──────────
    try:
        payload = verify_token(token, "access")
    except ApiError:
        await websocket.close(code=_CLOSE_UNAUTHORIZED)
        return
    if payload.get("role") != "ADMIN":
        await websocket.close(code=_CLOSE_FORBIDDEN)
        return

    await websocket.accept()

    redis = get_redis()
    pubsub = redis.pubsub()
    await pubsub.subscribe(Keys.LOCATION_UPDATES_CHANNEL)

    try:
        # Initial snapshot on connect.
        await websocket.send_json(await _build_snapshot())

        while True:
            # Wait up to HEARTBEAT_SECONDS for a pub/sub nudge; either way we
            # then send a snapshot (event-driven + periodic in one loop).
            try:
                await pubsub.get_message(
                    ignore_subscribe_messages=True, timeout=HEARTBEAT_SECONDS
                )
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 — transient redis hiccup
                logger.debug("ws: pubsub read error, falling back to heartbeat")
            await websocket.send_json(await _build_snapshot())
    except WebSocketDisconnect:
        pass
    except Exception:  # noqa: BLE001
        logger.exception("ws: admin-live loop error")
    finally:
        try:
            await pubsub.unsubscribe(Keys.LOCATION_UPDATES_CHANNEL)
            await pubsub.aclose()
        except Exception:  # noqa: BLE001
            pass
