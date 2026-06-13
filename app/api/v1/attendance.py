"""Attendance router — thin HTTP layer; all logic in AttendanceService.

Transition endpoints (start/break/resume/end) return the COMPLETE current
attendance (status, rollups, current_state, full session timeline) so the
device re-renders from one authoritative payload. Invalid transitions surface
as 409 CONFLICT with a specific message from the service.
"""
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import (
    CurrentUser,
    get_current_admin,
    get_current_supervisor,
    get_db,
)
from app.models.enums import SessionType
from app.models.user import User
from app.schemas.attendance import (
    AttendanceActionRequest,
    AttendanceEndRequest,
    AttendanceOut,
    AttendanceStatusOverride,
    ManualSessionRequest,
    TodayAttendanceOut,
)
from app.schemas.common import CursorPage, decode_cursor, encode_cursor
from app.services.attendance_service import AttendanceService

router = APIRouter(prefix="/attendance", tags=["attendance"])


def _client_ip(request: Request) -> str | None:
    return request.headers.get("x-real-ip") or (
        request.client.host if request.client else None
    )


# ── Transitions (any authenticated active user, acting on themselves) ────
@router.post("/start", response_model=AttendanceOut)
async def start(
    body: AttendanceActionRequest,
    request: Request,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AttendanceOut:
    return await AttendanceService(db).transition_state(
        user=user, action=SessionType.START, lat=body.lat, lng=body.lng,
        notes=body.notes, ip=_client_ip(request),
    )


@router.post("/break", response_model=AttendanceOut)
async def take_break(
    body: AttendanceActionRequest,
    request: Request,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AttendanceOut:
    return await AttendanceService(db).transition_state(
        user=user, action=SessionType.BREAK, lat=body.lat, lng=body.lng,
        notes=body.notes, ip=_client_ip(request),
    )


@router.post("/resume", response_model=AttendanceOut)
async def resume(
    body: AttendanceActionRequest,
    request: Request,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AttendanceOut:
    return await AttendanceService(db).transition_state(
        user=user, action=SessionType.RESUME, lat=body.lat, lng=body.lng,
        notes=body.notes, ip=_client_ip(request),
    )


@router.post("/end", response_model=AttendanceOut)
async def end(
    body: AttendanceEndRequest,
    request: Request,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AttendanceOut:
    return await AttendanceService(db).transition_state(
        user=user, action=SessionType.END, lat=body.lat, lng=body.lng,
        work_summary=body.work_summary, ip=_client_ip(request),
    )


# ── Personal reads ───────────────────────────────────────────────────────
@router.get("/today", response_model=TodayAttendanceOut)
async def today(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TodayAttendanceOut:
    return await AttendanceService(db).get_today(user.id)


@router.get("/history", response_model=CursorPage[AttendanceOut])
async def history(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    start_date: date = Query(..., description="Inclusive start (UTC)"),
    end_date: date = Query(..., description="Inclusive end (UTC)"),
    cursor: str | None = Query(default=None),
    limit: int = Query(default=30, ge=1, le=100),
) -> CursorPage[AttendanceOut]:
    items, total = await AttendanceService(db).get_history(
        user.id,
        start=start_date,
        end=end_date,
        cursor_id=decode_cursor(cursor),
        limit=limit,
    )
    has_more = len(items) > limit
    page = items[:limit]
    next_cursor = encode_cursor(page[-1].id) if has_more and page else None
    return CursorPage[AttendanceOut](
        items=page, next_cursor=next_cursor, total=total, has_more=has_more
    )


# ── Supervisor: team attendance for a date ───────────────────────────────
@router.get("/team/{team_id}", response_model=list[AttendanceOut])
async def team_attendance(
    team_id: int,
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
    day: date = Query(default_factory=date.today, alias="date"),
) -> list[AttendanceOut]:
    return await AttendanceService(db).get_team_for_date(
        supervisor=supervisor, team_id=team_id, day=day
    )


# ── Admin: all employees for a date ──────────────────────────────────────
@router.get("/all", response_model=CursorPage[AttendanceOut])
async def all_attendance(
    _admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
    day: date = Query(default_factory=date.today, alias="date"),
    cursor: str | None = Query(default=None),
    limit: int = Query(default=30, ge=1, le=100),
) -> CursorPage[AttendanceOut]:
    items, total = await AttendanceService(db).get_all_for_date(
        day=day, cursor_id=decode_cursor(cursor), limit=limit
    )
    has_more = len(items) > limit
    page = items[:limit]
    next_cursor = encode_cursor(page[-1].id) if has_more and page else None
    return CursorPage[AttendanceOut](
        items=page, next_cursor=next_cursor, total=total, has_more=has_more
    )


# ── Admin overrides ──────────────────────────────────────────────────────
@router.patch("/{attendance_id}/status", response_model=AttendanceOut)
async def override_status(
    attendance_id: int,
    body: AttendanceStatusOverride,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AttendanceOut:
    return await AttendanceService(db).override_status(
        attendance_id,
        status=body.status,
        reason=body.reason,
        actor=admin,
        ip=_client_ip(request),
    )


@router.post("/{attendance_id}/sessions", response_model=AttendanceOut)
async def add_manual_session(
    attendance_id: int,
    body: ManualSessionRequest,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> AttendanceOut:
    return await AttendanceService(db).add_manual_session(
        attendance_id,
        action=body.type,
        timestamp=body.timestamp,
        lat=body.lat,
        lng=body.lng,
        reason=body.reason,
        actor=admin,
        ip=_client_ip(request),
    )
