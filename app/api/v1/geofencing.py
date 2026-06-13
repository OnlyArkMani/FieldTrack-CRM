"""Geofencing router — thin HTTP layer; logic in GeofenceService.

Reads (list/detail/presence) are open to any authenticated active user (a
supervisor's mobile map renders zones); create/update/delete are ADMIN-only.
"""
from datetime import date as date_type
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_current_admin, get_db
from app.models.user import User
from app.schemas.geofence import (
    EmployeeVisitOut,
    GeofenceCreate,
    GeofenceDetailOut,
    GeofenceOut,
    GeofenceUpdate,
    PresenceOut,
)
from app.services.geofence_service import GeofenceService

router = APIRouter(prefix="/geofences", tags=["geofences"])


@router.get("", response_model=list[GeofenceOut])
async def list_geofences(
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[GeofenceOut]:
    return await GeofenceService(db).list_active()


@router.get("/{geofence_id}", response_model=GeofenceDetailOut)
async def get_geofence(
    geofence_id: int,
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GeofenceDetailOut:
    return await GeofenceService(db).get_detail(geofence_id)


@router.post("", response_model=GeofenceDetailOut, status_code=201)
async def create_geofence(
    body: GeofenceCreate,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GeofenceDetailOut:
    return await GeofenceService(db).create(body, actor=admin)


@router.put("/{geofence_id}", response_model=GeofenceDetailOut)
async def update_geofence(
    geofence_id: int,
    body: GeofenceUpdate,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GeofenceDetailOut:
    return await GeofenceService(db).update(geofence_id, body, actor=admin)


@router.delete("/{geofence_id}", status_code=204)
async def delete_geofence(
    geofence_id: int,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    await GeofenceService(db).soft_delete(geofence_id, actor=admin)


@router.get("/{geofence_id}/presence", response_model=list[PresenceOut])
async def geofence_presence(
    geofence_id: int,
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    date: Annotated[
        date_type | None, Query(description="Day (YYYY-MM-DD); defaults to today")
    ] = None,
) -> list[PresenceOut]:
    """Who was inside this zone, when, and for how long (ENTER/EXIT pairs)."""
    return await GeofenceService(db).presence(geofence_id, date or date_type.today())


@router.get("/employee/{user_id}/today", response_model=list[EmployeeVisitOut])
async def employee_geofences_today(
    user_id: int,
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    date: Annotated[date_type | None, Query()] = None,
) -> list[EmployeeVisitOut]:
    """Which geofences this employee visited (and total minutes) for the day."""
    return await GeofenceService(db).employee_today(user_id, date or date_type.today())
