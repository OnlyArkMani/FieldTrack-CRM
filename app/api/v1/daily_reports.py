"""Daily Sales Report (DSR) router -- Module 5.

Route ordering: static paths (/my, /team, /archive) declared before
parameterised paths (/{id}/...) to avoid conflicts.
"""
from __future__ import annotations

from datetime import date
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import (
    CurrentUser,
    get_current_admin,
    get_current_supervisor,
    get_db,
)
from app.core.exceptions import forbidden, not_found
from app.models.crm import DailyReport
from app.models.enums import UserRole
from app.models.user import User
from app.schemas.common import CursorPage, decode_cursor, encode_cursor
from app.schemas.crm import DailyReportResponse
from app.services.dsr_service import (
    add_manager_comment,
    get_dsr_with_details,
    submit_dsr,
)

router = APIRouter(prefix="/daily-reports", tags=["daily-reports"])


# -- Request schemas ----------------------------------------------------------

class DsrSubmitRequest(BaseModel):
    end_of_day_note: str | None = Field(
        default=None,
        max_length=300,
        description="Optional end-of-day summary note (max 300 chars)",
    )


class ManagerCommentRequest(BaseModel):
    comment: str = Field(min_length=1, max_length=1000)


# -- Enriched response schemas ------------------------------------------------

class VisitSummaryItem(BaseModel):
    id: int
    farmer_name: str
    purpose: str | None
    check_in_at: Any
    check_out_at: Any
    lead_status: str | None


class OrderSummaryItem(BaseModel):
    id: int
    farmer_name: str
    bags_count: int
    delivery_date: date
    payment_mode: str | None


class FollowUpSummaryItem(BaseModel):
    id: int
    farmer_name: str
    scheduled_date: date
    scheduled_time: Any
    purpose: str | None


class DsrDetailResponse(DailyReportResponse):
    manager_comment: str | None = None
    visits: list[VisitSummaryItem] = []
    orders: list[OrderSummaryItem] = []
    follow_ups: list[FollowUpSummaryItem] = []


class TeamDsrItem(BaseModel):
    employee_id: int
    employee_name: str
    status: str  # SUBMITTED / DRAFT / MISSING
    visits_completed: int
    orders_captured: int
    hot_leads: int
    warm_leads: int
    cold_leads: int
    is_late: bool
    report_id: int | None


# -- Employee: own DSR history ------------------------------------------------

@router.get("/my", response_model=list[DailyReportResponse])
async def my_dsr_history(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    month: int = Query(default=None, ge=1, le=12),
    year: int = Query(default=None, ge=2020, le=2099),
) -> list[DailyReportResponse]:
    from sqlalchemy import extract

    q = select(DailyReport).where(DailyReport.employee_id == user.id)
    if year:
        q = q.where(extract("year", DailyReport.report_date) == year)
    if month:
        q = q.where(extract("month", DailyReport.report_date) == month)
    q = q.order_by(DailyReport.report_date.desc())

    rows = (await db.execute(q)).scalars().all()
    return [DailyReportResponse.model_validate(r) for r in rows]


@router.get("/my/{report_date}", response_model=DsrDetailResponse)
async def my_dsr_for_date(
    report_date: date,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> DsrDetailResponse:
    detail = await get_dsr_with_details(db, employee_id=user.id, report_date=report_date)
    if detail is None:
        raise HTTPException(
            status_code=404,
            detail="No attendance recorded for this date.",
        )
    return _build_detail_response(detail)


# -- Employee: submit DSR -----------------------------------------------------

@router.post("/{report_id}/submit", response_model=DailyReportResponse)
async def submit(
    report_id: int,
    body: DsrSubmitRequest,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> DailyReportResponse:
    report = await submit_dsr(
        db,
        report_id=report_id,
        employee_id=user.id,
        end_of_day_note=body.end_of_day_note,
    )
    return DailyReportResponse.model_validate(report)


# -- Supervisor: team DSRs ----------------------------------------------------

@router.get("/team", response_model=list[TeamDsrItem])
async def team_dsrs(
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
    report_date: date = Query(default_factory=date.today),
) -> list[TeamDsrItem]:
    team_id = supervisor.team_id
    if not team_id:
        return []

    emp_q = await db.execute(
        select(User).where(
            User.team_id == team_id,
            User.role == UserRole.EMPLOYEE,
            User.is_active.is_(True),
        )
    )
    employees = emp_q.scalars().all()
    if not employees:
        return []

    emp_ids = [e.id for e in employees]

    dsr_q = await db.execute(
        select(DailyReport).where(
            DailyReport.employee_id.in_(emp_ids),
            DailyReport.report_date == report_date,
        )
    )
    dsrs_by_emp: dict[int, DailyReport] = {
        d.employee_id: d for d in dsr_q.scalars().all()
    }

    return [
        TeamDsrItem(
            employee_id=emp.id,
            employee_name=emp.full_name,
            status=dsrs_by_emp[emp.id].status if emp.id in dsrs_by_emp else "MISSING",
            visits_completed=dsrs_by_emp[emp.id].visits_completed if emp.id in dsrs_by_emp else 0,
            orders_captured=dsrs_by_emp[emp.id].orders_captured if emp.id in dsrs_by_emp else 0,
            hot_leads=dsrs_by_emp[emp.id].hot_leads if emp.id in dsrs_by_emp else 0,
            warm_leads=dsrs_by_emp[emp.id].warm_leads if emp.id in dsrs_by_emp else 0,
            cold_leads=dsrs_by_emp[emp.id].cold_leads if emp.id in dsrs_by_emp else 0,
            is_late=dsrs_by_emp[emp.id].is_late if emp.id in dsrs_by_emp else False,
            report_id=dsrs_by_emp[emp.id].id if emp.id in dsrs_by_emp else None,
        )
        for emp in employees
    ]


@router.get("/team/{employee_id}/{report_date}", response_model=DsrDetailResponse)
async def team_dsr_detail(
    employee_id: int,
    report_date: date,
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> DsrDetailResponse:
    if supervisor.role == UserRole.SUPERVISOR:
        emp = await db.get(User, employee_id)
        if emp is None or emp.team_id != supervisor.team_id:
            raise forbidden("Employee is not on your team")

    detail = await get_dsr_with_details(db, employee_id=employee_id, report_date=report_date)
    if detail is None:
        raise not_found("No DSR found for this employee on this date")
    return _build_detail_response(detail)


# -- Supervisor: add manager comment ------------------------------------------

@router.post("/{report_id}/manager-comment", response_model=DailyReportResponse)
async def post_manager_comment(
    report_id: int,
    body: ManagerCommentRequest,
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> DailyReportResponse:
    report = await add_manager_comment(
        db,
        report_id=report_id,
        supervisor_id=supervisor.id,
        comment=body.comment,
    )
    return DailyReportResponse.model_validate(report)


# -- Admin: archive -----------------------------------------------------------

@router.get("/archive", response_model=CursorPage[DailyReportResponse])
async def archive(
    _admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
    employee_id: int | None = Query(default=None),
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
    status: str | None = Query(default=None),
    cursor: str | None = Query(default=None),
    limit: int = Query(default=30, ge=1, le=100),
) -> CursorPage[DailyReportResponse]:
    from sqlalchemy import func

    base_filters = []
    if employee_id:
        base_filters.append(DailyReport.employee_id == employee_id)
    if date_from:
        base_filters.append(DailyReport.report_date >= date_from)
    if date_to:
        base_filters.append(DailyReport.report_date <= date_to)
    if status:
        base_filters.append(DailyReport.status == status.upper())

    total = (
        await db.execute(select(func.count(DailyReport.id)).where(*base_filters))
    ).scalar_one()

    q = select(DailyReport).where(*base_filters)
    cursor_id = decode_cursor(cursor)
    if cursor_id:
        q = q.where(DailyReport.id < cursor_id)

    q = q.order_by(DailyReport.id.desc()).limit(limit + 1)
    rows = (await db.execute(q)).scalars().all()

    has_more = len(rows) > limit
    page = rows[:limit]
    next_cursor = encode_cursor(page[-1].id) if has_more and page else None

    return CursorPage[DailyReportResponse](
        items=[DailyReportResponse.model_validate(r) for r in page],
        next_cursor=next_cursor,
        total=total,
        has_more=has_more,
    )


# -- Internal helper ----------------------------------------------------------

def _build_detail_response(detail: dict) -> DsrDetailResponse:
    report = detail["report"]
    base = DailyReportResponse.model_validate(report)
    return DsrDetailResponse(
        **base.model_dump(),
        manager_comment=getattr(report, "manager_comment", None),
        visits=[VisitSummaryItem(**v) for v in detail["visits"]],
        orders=[OrderSummaryItem(**o) for o in detail["orders"]],
        follow_ups=[FollowUpSummaryItem(**f) for f in detail["follow_ups"]],
    )
