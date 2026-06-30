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


# ── CRM Performance ──────────────────────────────────────────────────────────

from pydantic import BaseModel as _BaseModel


class CrmPerformanceOut(_BaseModel):
    employee_id: int
    start_date: date
    end_date: date
    visits_completed: int
    orders_captured: int
    hot_leads: int
    warm_leads: int
    cold_leads: int
    follow_ups_total: int
    follow_ups_done: int
    follow_up_completion_rate: float  # 0–1
    dsrs_submitted: int
    dsrs_total: int
    unique_farmers_visited: int


@router.get("/{employee_id}/crm-performance", response_model=CrmPerformanceOut)
async def crm_performance(
    employee_id: int,
    _supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
    start_date: date | None = Query(default=None, description="Inclusive start (UTC)"),
    end_date: date | None = Query(default=None, description="Inclusive end (UTC)"),
) -> CrmPerformanceOut:
    """CRM performance scorecard for one employee over a date range.

    Defaults to last 30 days when no dates are provided.
    Accessible by supervisors and admins.
    """
    from datetime import timedelta, date as _date
    from sqlalchemy import func, select, distinct
    from app.models.crm import (
        Visit, VisitOrder, Lead, FollowUp, DailyReport,
    )

    today = _date.today()
    if end_date is None:
        end_date = today
    if start_date is None:
        start_date = today - timedelta(days=29)

    # Visits completed in range
    visits_completed = (
        await db.execute(
            select(func.count(Visit.id)).where(
                Visit.employee_id == employee_id,
                Visit.check_out_at.isnot(None),
                func.date(Visit.check_in_at) >= start_date,
                func.date(Visit.check_in_at) <= end_date,
            )
        )
    ).scalar_one() or 0

    # Unique farmers visited
    unique_farmers = (
        await db.execute(
            select(func.count(distinct(Visit.farmer_id))).where(
                Visit.employee_id == employee_id,
                Visit.check_out_at.isnot(None),
                func.date(Visit.check_in_at) >= start_date,
                func.date(Visit.check_in_at) <= end_date,
            )
        )
    ).scalar_one() or 0

    # Orders captured via visits in range (join through visit)
    orders_captured = (
        await db.execute(
            select(func.count(VisitOrder.id))
            .join(Visit, Visit.id == VisitOrder.visit_id)
            .where(
                Visit.employee_id == employee_id,
                func.date(Visit.check_in_at) >= start_date,
                func.date(Visit.check_in_at) <= end_date,
            )
        )
    ).scalar_one() or 0

    # Leads by status (employee-owned leads updated in range)
    leads_rows = (
        await db.execute(
            select(Lead.status, func.count(Lead.id))
            .where(
                Lead.employee_id == employee_id,
                func.date(Lead.created_at) >= start_date,
                func.date(Lead.created_at) <= end_date,
            )
            .group_by(Lead.status)
        )
    ).all()
    lead_counts = {row[0]: row[1] for row in leads_rows}
    hot_leads = lead_counts.get("HOT", 0)
    warm_leads = lead_counts.get("WARM", 0)
    cold_leads = lead_counts.get("COLD", 0)

    # Follow-ups in range
    fu_total = (
        await db.execute(
            select(func.count(FollowUp.id)).where(
                FollowUp.employee_id == employee_id,
                FollowUp.scheduled_date >= start_date,
                FollowUp.scheduled_date <= end_date,
            )
        )
    ).scalar_one() or 0

    fu_done = (
        await db.execute(
            select(func.count(FollowUp.id)).where(
                FollowUp.employee_id == employee_id,
                FollowUp.scheduled_date >= start_date,
                FollowUp.scheduled_date <= end_date,
                FollowUp.status == "DONE",
            )
        )
    ).scalar_one() or 0

    # DSRs in range
    dsr_total = (end_date - start_date).days + 1
    dsr_submitted = (
        await db.execute(
            select(func.count(DailyReport.id)).where(
                DailyReport.employee_id == employee_id,
                DailyReport.report_date >= start_date,
                DailyReport.report_date <= end_date,
                DailyReport.status == "SUBMITTED",
            )
        )
    ).scalar_one() or 0

    completion_rate = (fu_done / fu_total) if fu_total > 0 else 0.0

    return CrmPerformanceOut(
        employee_id=employee_id,
        start_date=start_date,
        end_date=end_date,
        visits_completed=visits_completed,
        orders_captured=orders_captured,
        hot_leads=hot_leads,
        warm_leads=warm_leads,
        cold_leads=cold_leads,
        follow_ups_total=fu_total,
        follow_ups_done=fu_done,
        follow_up_completion_rate=round(completion_rate, 3),
        dsrs_submitted=dsr_submitted,
        dsrs_total=dsr_total,
        unique_farmers_visited=unique_farmers,
    )
