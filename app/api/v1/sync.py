"""Sync router — offline replay + clock-drift probe.

Locations sync via the existing POST /location/batch (it already dedupes
replayed batches via Redis SET NX, so a crash-and-retry never double-inserts).
This router adds the attendance-session replay and the server-clock probe.
"""
from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_db, per_user_rate_limit
from app.schemas.sync import (
    AttendanceSessionSyncIn,
    AttendanceSessionSyncResult,
    ServerStatusOut,
)
from app.services.sync_service import SyncService

router = APIRouter(prefix="/sync", tags=["sync"])


@router.post(
    "/attendance-sessions",
    response_model=AttendanceSessionSyncResult,
    dependencies=[Depends(per_user_rate_limit)],
)
async def sync_attendance_sessions(
    body: AttendanceSessionSyncIn,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AttendanceSessionSyncResult:
    """Batch-replay offline attendance taps. Idempotent: duplicates (same
    attendance_id + type within 30s) report as `skipped`."""
    return await SyncService(db).sync_attendance_sessions(user, body)


@router.get("/status", response_model=ServerStatusOut)
async def sync_status(
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> ServerStatusOut:
    """Authoritative server time. The client compares it to its own clock and
    warns the user if drift exceeds 5 minutes (offline timestamps depend on a
    correct device clock)."""
    return await SyncService(db).server_status()
