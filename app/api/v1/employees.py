"""Employee router — thin HTTP layer; all logic lives in EmployeeService.

AUTHZ:
- List/detail/summary/location: any authenticated active user (managers &
  admins use these; the mobile team views read them). Tightening to team scope
  is a future refinement — the data returned is non-sensitive directory + live
  status. Create / status-change are ADMIN-only (per spec). Update is
  manager-or-admin.
"""
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import (
    CurrentUser,
    get_current_admin,
    get_current_manager,
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
    manager: Annotated[User, Depends(get_current_manager)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> EmployeeDetailOut:
    return await EmployeeService(db).update(
        employee_id, body, actor=manager, ip=_client_ip(request)
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
    _manager: Annotated[User, Depends(get_current_manager)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> GpsIntegrityOut:
    """Mock-GPS integrity for one employee (7-day window). Manager/admin
    only — this anti-gaming data is never exposed to the employee themselves."""
    return await EmployeeService(db).gps_integrity(employee_id)


# ── CRM Performance ──────────────────────────────────────────────────────────

from pydantic import BaseModel as _BaseModel


class CrmPerformanceOut(_BaseModel):
    employee_id: int
    start_date: date
    end_date: date
    visits_planned: int
    visits_completed: int
    # Checklist A7 — visits completed broken down by counterparty type
    # (FARMER_MEET / FPO / VLCC today; any future customer_type value, e.g.
    # Retailer, appears automatically once it exists).
    visits_completed_by_type: dict[str, int]
    # Checklist A8 — vet requests raised by this employee in range, broken
    # down by status (REQUESTED / SCHEDULED / DONE).
    vet_requests_raised: int
    vet_requests_by_status: dict[str, int]
    orders_captured: int
    # Target bags set while planning visits (VisitPlanItem.target_order_bags)
    # vs bags actually captured via orders in the same range — the field
    # equivalent of the Visits (Done/Planned) card, for order volume.
    target_order_bags: int
    bags_captured: int
    hot_leads: int
    warm_leads: int
    cold_leads: int
    follow_ups_total: int
    follow_ups_done: int
    follow_up_completion_rate: float  # 0–1
    dsrs_submitted: int
    dsrs_total: int
    unique_farmers_visited: int
    visits_with_remarks: int
    # Order count/bags per customer_type (FARMER_MEET / FPO / VLCC). Always has an
    # entry for every current CustomerType value, 0 when there's no data.
    orders_by_type: dict[str, int]
    bags_by_type: dict[str, int]


@router.get("/{employee_id}/crm-performance", response_model=CrmPerformanceOut)
async def crm_performance(
    employee_id: int,
    _manager: Annotated[User, Depends(get_current_manager)],
    db: Annotated[AsyncSession, Depends(get_db)],
    start_date: date | None = Query(default=None, description="Inclusive start (UTC)"),
    end_date: date | None = Query(default=None, description="Inclusive end (UTC)"),
) -> CrmPerformanceOut:
    """CRM performance scorecard for one employee over a date range.

    Defaults to last 30 days when no dates are provided.
    Accessible by managers and admins.
    """
    from datetime import timedelta, date as _date
    from sqlalchemy import and_, func, select, distinct, or_
    from app.models.crm import (
        Visit, VisitOrder, Lead, FollowUp, DailyReport, VisitNote, Farmer,
        VisitPlan, VisitPlanItem,
    )
    from app.models.enums import CustomerType

    today = _date.today()
    if end_date is None:
        end_date = today
    if start_date is None:
        start_date = today - timedelta(days=29)

    # Visits planned in range (checklist A5 — same source as the daily DSR's
    # visits_planned: count of VisitPlanItem rows under this employee's plans)
    visits_planned = (
        await db.execute(
            select(func.count(VisitPlanItem.id))
            .join(VisitPlan, VisitPlan.id == VisitPlanItem.plan_id)
            .where(
                VisitPlan.employee_id == employee_id,
                VisitPlan.plan_date >= start_date,
                VisitPlan.plan_date <= end_date,
            )
        )
    ).scalar_one() or 0

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

    # Visits completed broken down by counterparty type (checklist A7)
    by_type_rows = (
        await db.execute(
            select(Farmer.customer_type, func.count(Visit.id))
            .join(Farmer, Farmer.id == Visit.farmer_id)
            .where(
                Visit.employee_id == employee_id,
                Visit.check_out_at.isnot(None),
                func.date(Visit.check_in_at) >= start_date,
                func.date(Visit.check_in_at) <= end_date,
            )
            .group_by(Farmer.customer_type)
        )
    ).all()
    visits_completed_by_type = {
        (t.value if hasattr(t, "value") else str(t)): c for t, c in by_type_rows
    }

    # Vet requests raised in range (checklist A8) — not gated on check_out_at
    # since vet_required is set during the visit, independent of completion.
    vet_by_status_rows = (
        await db.execute(
            select(Visit.vet_status, func.count(Visit.id))
            .where(
                Visit.employee_id == employee_id,
                Visit.vet_required.is_(True),
                func.date(Visit.check_in_at) >= start_date,
                func.date(Visit.check_in_at) <= end_date,
            )
            .group_by(Visit.vet_status)
        )
    ).all()
    vet_requests_by_status = {
        (s or "REQUESTED"): c for s, c in vet_by_status_rows
    }
    vet_requests_raised = sum(vet_requests_by_status.values())

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

    # Target bags set while planning visits in range (checklist-adjacent: the
    # "Target order (bags)" question asked when a visit is planned) — plus
    # targets set on the spot for ad-hoc visits, which have no VisitPlan
    # (plan_id is null) and are instead scoped by the visit's own check-in.
    target_order_bags = (
        await db.execute(
            select(func.coalesce(func.sum(VisitPlanItem.target_order_bags), 0))
            .outerjoin(VisitPlan, VisitPlan.id == VisitPlanItem.plan_id)
            .outerjoin(Visit, Visit.plan_item_id == VisitPlanItem.id)
            .where(
                or_(
                    and_(
                        VisitPlan.employee_id == employee_id,
                        VisitPlan.plan_date >= start_date,
                        VisitPlan.plan_date <= end_date,
                    ),
                    and_(
                        VisitPlanItem.plan_id.is_(None),
                        Visit.employee_id == employee_id,
                        func.date(Visit.check_in_at) >= start_date,
                        func.date(Visit.check_in_at) <= end_date,
                    ),
                )
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

    # Orders captured, grouped by the customer's type (Farmer/FPO/VLCC)
    orders_by_type_rows = (
        await db.execute(
            select(
                Farmer.customer_type,
                func.count(VisitOrder.id),
                func.coalesce(func.sum(VisitOrder.bags_count), 0),
            )
            .join(Visit, Visit.id == VisitOrder.visit_id)
            .join(Farmer, Farmer.id == VisitOrder.farmer_id)
            .where(
                Visit.employee_id == employee_id,
                func.date(Visit.check_in_at) >= start_date,
                func.date(Visit.check_in_at) <= end_date,
            )
            .group_by(Farmer.customer_type)
        )
    ).all()
    orders_by_type = {t.value: 0 for t in CustomerType}
    bags_by_type = {t.value: 0 for t in CustomerType}
    for customer_type, order_count, bag_count in orders_by_type_rows:
        orders_by_type[customer_type] = order_count
        bags_by_type[customer_type] = int(bag_count)
    bags_captured = sum(bags_by_type.values())

    # Visits with a remark captured (meeting highlights and/or farmer concerns)
    visits_with_remarks = (
        await db.execute(
            select(func.count(func.distinct(Visit.id)))
            .join(VisitNote, VisitNote.visit_id == Visit.id)
            .where(
                Visit.employee_id == employee_id,
                func.date(Visit.check_in_at) >= start_date,
                func.date(Visit.check_in_at) <= end_date,
                or_(
                    func.trim(VisitNote.meeting_highlights) != "",
                    func.trim(VisitNote.farmer_concerns) != "",
                ),
            )
        )
    ).scalar_one() or 0

    return CrmPerformanceOut(
        employee_id=employee_id,
        start_date=start_date,
        end_date=end_date,
        visits_planned=visits_planned,
        visits_completed=visits_completed,
        visits_completed_by_type=visits_completed_by_type,
        vet_requests_raised=vet_requests_raised,
        vet_requests_by_status=vet_requests_by_status,
        orders_captured=orders_captured,
        target_order_bags=target_order_bags,
        bags_captured=bags_captured,
        hot_leads=hot_leads,
        warm_leads=warm_leads,
        cold_leads=cold_leads,
        follow_ups_total=fu_total,
        follow_ups_done=fu_done,
        follow_up_completion_rate=round(completion_rate, 3),
        dsrs_submitted=dsr_submitted,
        dsrs_total=dsr_total,
        unique_farmers_visited=unique_farmers,
        visits_with_remarks=visits_with_remarks,
        orders_by_type=orders_by_type,
        bags_by_type=bags_by_type,
    )


@router.get("/{employee_id}/profile-photo")
async def get_profile_photo(
    employee_id: int,
    db: Annotated[AsyncSession, Depends(get_db)],
):
    """Retrieve and redirect to the presigned download URL for the user's profile photo.
    Public endpoint (no auth required) so browsers and image caches can fetch it directly.
    """
    from fastapi.responses import RedirectResponse
    from app.services.employee_service import EmployeeService
    url = await EmployeeService(db).get_profile_photo_url(employee_id)
    return RedirectResponse(url, status_code=307)
