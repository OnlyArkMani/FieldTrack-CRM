"""Employee router — thin HTTP layer; all logic lives in EmployeeService.

AUTHZ:
- List/detail/summary/location: any authenticated active user (supervisors &
  admins use these; the mobile team views read them). Tightening to team scope
  is a future refinement — the data returned is non-sensitive directory + live
  status. Create / status-change are ADMIN-only (per spec). Update is
  supervisor-or-admin.
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
from app.models.user import User
from app.schemas.common import CursorPage
from app.schemas.employee import (
    AttendanceSummaryOut,
    EmployeeCreate,
    EmployeeDetailOut,
    EmployeeOut,
    EmployeeStatusUpdate,
    EmployeeUpdate,
    GpsIntegrityOut,
    LocationHistoryOut,
)
from app.services.employee_service import EmployeeService

router = APIRouter(prefix="/employees", tags=["employees"])


def _client_ip(request: Request) -> str | None:
    return request.headers.get("x-real-ip") or (
        request.client.host if request.client else None
    )


@router.get("", response_model=CursorPage[EmployeeOut])
async def list_employees(
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    cursor: str | None = Query(default=None, description="Opaque forward cursor"),
    limit: int = Query(default=20, ge=1, le=100),
    team_id: int | None = Query(default=None),
    status: str | None = Query(
        default=None, description="Filter by account status: active | inactive"
    ),
    search: str | None = Query(default=None, max_length=120),
) -> CursorPage[EmployeeOut]:
    return await EmployeeService(db).list_employees(
        cursor=cursor,
        limit=limit,
        team_id=team_id,
        status=status,
        search=search,
    )


@router.get("/{employee_id}", response_model=EmployeeDetailOut)
async def get_employee(
    employee_id: int,
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> EmployeeDetailOut:
    return await EmployeeService(db).get_detail(employee_id)


@router.post("", response_model=EmployeeDetailOut, status_code=201)
async def create_employee(
    body: EmployeeCreate,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> EmployeeDetailOut:
    return await EmployeeService(db).create(
        body, actor=admin, ip=_client_ip(request)
    )


@router.put("/{employee_id}", response_model=EmployeeDetailOut)
async def update_employee(
    employee_id: int,
    body: EmployeeUpdate,
    request: Request,
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> EmployeeDetailOut:
    return await EmployeeService(db).update(
        employee_id, body, actor=supervisor, ip=_client_ip(request)
    )


@router.patch("/{employee_id}/status", response_model=EmployeeDetailOut)
async def set_employee_status(
    employee_id: int,
    body: EmployeeStatusUpdate,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> EmployeeDetailOut:
    return await EmployeeService(db).set_status(
        employee_id, body, actor=admin, ip=_client_ip(request)
    )


@router.get(
    "/{employee_id}/attendance-summary", response_model=AttendanceSummaryOut
)
async def attendance_summary(
    employee_id: int,
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    year: int = Query(..., ge=2020, le=2100),
    month: int = Query(..., ge=1, le=12),
) -> AttendanceSummaryOut:
    return await EmployeeService(db).attendance_summary(
        employee_id, year=year, month=month
    )


@router.get("/{employee_id}/location-history", response_model=LocationHistoryOut)
async def location_history(
    employee_id: int,
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    date_from: date = Query(..., description="Inclusive start date (UTC)"),
    date_to: date = Query(..., description="Inclusive end date (UTC)"),
    limit: int = Query(default=1000, ge=1, le=2000),
) -> LocationHistoryOut:
    return await EmployeeService(db).location_history(
        employee_id, date_from=date_from, date_to=date_to, limit=limit
    )


@router.get("/{employee_id}/gps-integrity", response_model=GpsIntegrityOut)
async def gps_integrity(
    employee_id: int,
    _supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GpsIntegrityOut:
    """Mock-GPS integrity for one employee (7-day window). Supervisor/admin
    only — this anti-gaming data is never exposed to the employee themselves."""
    return await EmployeeService(db).gps_integrity(employee_id)
