"""Location router — thin HTTP layer; logic in LocationService."""
from datetime import date as date_type
from datetime import time
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import (
    CurrentUser,
    get_current_supervisor,
    get_db,
    per_user_rate_limit,
)
from app.models.user import User
from app.schemas.location import (
    LivePoint,
    LocationBatchIn,
    LocationBatchResult,
    LocationHistoryOut,
    RouteReplayOut,
    TeamLivePoint,
    TrailSummaryOut,
)
from app.services.location_service import LocationService

router = APIRouter(prefix="/location", tags=["location"])


@router.post(
    "/batch",
    response_model=LocationBatchResult,
    dependencies=[Depends(per_user_rate_limit)],
)
async def ingest_batch(
    body: LocationBatchIn,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> LocationBatchResult:
    """Devices upload their offline queue here (<=100 records). Idempotent:
    retried batches dedupe via Redis and report as `skipped`."""
    return await LocationService(db).ingest_batch(user, body)


@router.get("/live/{user_id}", response_model=LivePoint | None)
async def live(
    user_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> LivePoint | None:
    """Redis-cached latest position (2h TTL); DB fallback on cache miss.
    null body = no location data exists for this user at all."""
    return await LocationService(db).live(user, user_id)


@router.get("/history/{user_id}", response_model=LocationHistoryOut)
async def history(
    user_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    date: Annotated[date_type, Query(description="Day to fetch (YYYY-MM-DD)")],
    start_time: Annotated[time | None, Query()] = None,
    end_time: Annotated[time | None, Query()] = None,
) -> LocationHistoryOut:
    """Chronological points for route rendering on the map."""
    return await LocationService(db).history(
        user, user_id, date, start_time, end_time
    )


@router.get("/route/{user_id}", response_model=RouteReplayOut)
async def route(
    user_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    date: Annotated[
        date_type | None, Query(description="Day (YYYY-MM-DD); defaults to today")
    ] = None,
) -> RouteReplayOut:
    """Trail-replay payload for a day: enriched points (speed/accuracy/mock/
    attendance_state), attendance session markers, and aggregate stats. Tracks
    over 500 points are simplified (Douglas–Peucker) but mock-GPS points are
    always preserved."""
    day = date or date_type.today()
    return await LocationService(db).route(user, user_id, day)


@router.get("/trail-summary/{user_id}", response_model=TrailSummaryOut)
async def trail_summary(
    user_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    days: Annotated[
        int, Query(ge=1, le=31, description="Window size in days (max 31)")
    ] = 31,
) -> TrailSummaryOut:
    """31-day distance report for one employee: per-day distance (metres) +
    GPS point count, derived on the fly from location_logs (retention window is
    31 days — no extra storage). Pick a day with `has_trail=true` and call
    /location/route/{user_id}?date=... for that day's full trail."""
    return await LocationService(db).trail_summary(user, user_id, days)


@router.get("/team-live", response_model=list[TeamLivePoint])
async def team_live(
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[TeamLivePoint]:
    """Live positions of every member of the teams this supervisor manages.
    Redis live-cache first, last DB record as fallback (shown as OFFLINE)."""
    return await LocationService(db).team_live(supervisor)
