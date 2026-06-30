"""Configurable GPS Interval router — Module 6.

Endpoints
---------
GET  /gps-config/team/{team_id}   Admin or supervisor of that team.
PUT  /gps-config/team/{team_id}   Admin only.  Upserts config + caches.
GET  /gps-config/my               Employee: returns their team's config.
                                  Redis-first, DB fallback, re-caches on miss.

Redis key: fieldtrack:gps_config:{team_id}  TTL: 86400s (24h)
"""
from __future__ import annotations

import json
from datetime import date as _date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.core.dependencies import (
    CurrentUser,
    get_current_admin,
    get_current_supervisor,
    get_db,
)
from app.core.redis import get_redis
from app.models.crm import GpsConfig
from app.models.enums import UserRole
from app.models.user import User

router = APIRouter(prefix="/gps-config", tags=["gps-config"])

# ── Defaults ─────────────────────────────────────────────────────────────────

DEFAULTS = {
    "moving_interval_seconds": 180,
    "stationary_interval_seconds": 720,
    "low_battery_interval_seconds": 1200,
    "low_battery_threshold": 20,
}

_REDIS_TTL = 86_400  # 24 hours


def _redis_key(team_id: int) -> str:
    return f"fieldtrack:gps_config:{team_id}"


# ── Schemas ───────────────────────────────────────────────────────────────────

class GpsConfigOut(BaseModel):
    team_id: int | None
    moving_interval_seconds: int
    stationary_interval_seconds: int
    low_battery_interval_seconds: int
    low_battery_threshold: int

    model_config = {"from_attributes": True}


class GpsConfigIn(BaseModel):
    moving_interval_seconds: int = Field(
        ...,
        ge=60,
        le=600,
        description="1–10 minutes",
    )
    stationary_interval_seconds: int = Field(
        ...,
        ge=300,
        le=1800,
        description="5–30 minutes",
    )
    low_battery_interval_seconds: int = Field(
        ...,
        ge=600,
        le=3600,
        description="10–60 minutes",
    )
    low_battery_threshold: int = Field(
        ...,
        ge=10,
        le=30,
        description="Battery % that triggers low-battery mode",
    )


# ── Helpers ───────────────────────────────────────────────────────────────────

def _config_to_dict(cfg: GpsConfig | None) -> dict:
    """Row → dict, or defaults when cfg is None."""
    if cfg is None:
        return dict(DEFAULTS, team_id=None)
    return {
        "team_id": cfg.team_id,
        "moving_interval_seconds": cfg.moving_interval_seconds,
        "stationary_interval_seconds": cfg.stationary_interval_seconds,
        "low_battery_interval_seconds": cfg.low_battery_interval_seconds,
        "low_battery_threshold": cfg.low_battery_threshold,
    }


async def _get_config_from_db(db: AsyncSession, team_id: int) -> dict:
    row = (
        await db.execute(
            select(GpsConfig).where(GpsConfig.team_id == team_id)
        )
    ).scalar_one_or_none()
    return _config_to_dict(row)


async def _cache(team_id: int, data: dict) -> None:
    """Write config to Redis, best-effort."""
    try:
        r = get_redis()
        await r.set(_redis_key(team_id), json.dumps(data), ex=_REDIS_TTL)
    except Exception:  # noqa: BLE001
        pass  # Redis unavailable → DB fallback always works


async def _get_config_cached(db: AsyncSession, team_id: int) -> dict:
    """Redis-first, DB fallback, re-caches on miss."""
    try:
        r = get_redis()
        raw = await r.get(_redis_key(team_id))
        if raw:
            return json.loads(raw)
    except Exception:  # noqa: BLE001
        pass  # Redis unavailable → fall through to DB
    data = await _get_config_from_db(db, team_id)
    await _cache(team_id, data)
    return data


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/team/{team_id}", response_model=GpsConfigOut)
async def get_team_config(
    team_id: int,
    principal: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GpsConfigOut:
    """Admin or team's supervisor can fetch config. Falls back to defaults."""
    if principal.role == UserRole.SUPERVISOR and principal.team_id != team_id:
        raise HTTPException(status_code=403, detail="Not your team.")
    data = await _get_config_cached(db, team_id)
    return GpsConfigOut(**data)


@router.put("/team/{team_id}", response_model=GpsConfigOut)
async def upsert_team_config(
    team_id: int,
    body: GpsConfigIn,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GpsConfigOut:
    """Admin only. Upserts config and caches in Redis."""
    stmt = (
        pg_insert(GpsConfig)
        .values(
            team_id=team_id,
            moving_interval_seconds=body.moving_interval_seconds,
            stationary_interval_seconds=body.stationary_interval_seconds,
            low_battery_interval_seconds=body.low_battery_interval_seconds,
            low_battery_threshold=body.low_battery_threshold,
            updated_by=admin.id,
        )
        .on_conflict_do_update(
            constraint="uq_gps_config_team_id",
            set_={
                "moving_interval_seconds": body.moving_interval_seconds,
                "stationary_interval_seconds": body.stationary_interval_seconds,
                "low_battery_interval_seconds": body.low_battery_interval_seconds,
                "low_battery_threshold": body.low_battery_threshold,
                "updated_by": admin.id,
                "updated_at": __import__("sqlalchemy").func.now(),
            },
        )
        .returning(GpsConfig)
    )
    row = (await db.execute(stmt)).scalar_one()
    await db.commit()
    data = _config_to_dict(row)
    await _cache(team_id, data)
    return GpsConfigOut(**data)


@router.get("/my", response_model=GpsConfigOut)
async def my_config(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GpsConfigOut:
    """Employee endpoint — returns their team's config (Redis-first).
    Called at attendance START to prime the Flutter location service."""
    team_id = user.team_id
    if team_id is None:
        # No team → serve defaults so the employee can still track.
        return GpsConfigOut(**{**DEFAULTS, "team_id": None})
    data = await _get_config_cached(db, team_id)
    return GpsConfigOut(**data)
