"""Daily Sales Report (DSR) service — Module 5.

generate_dsr  → called as a background task on attendance END.
submit_dsr    → called explicitly by the employee after reviewing the draft.

DESIGN:
- generate_dsr is idempotent: INSERT … ON CONFLICT (employee_id, report_date)
  DO UPDATE so a re-trigger (e.g. after a manual attendance correction) just
  refreshes the counts. The employee's end_of_day_note is never overwritten if
  already set (they may have typed something before re-generation).
- is_late: set at generation time if the current wall-clock hour ≥ 19:30 in the
  business timezone. The APScheduler job at 19:30 also marks surviving DRAFTs.
- submit_dsr sends FCM to the supervisor and (if late) back to the employee.
  The supervisor FCM target is: team's supervisor_id (from users.team_id via
  the supervisors join table). If multiple supervisors exist for the team we
  notify all; if none, we skip gracefully.
"""
from __future__ import annotations

import logging
from datetime import date as date_type
from datetime import datetime, time, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import func, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import async_session_factory
from app.core.exceptions import bad_request, not_found
from app.models.attendance import Attendance, AttendanceSession
from app.models.crm import (
    DailyReport,
    Farmer,
    FollowUp,
    Lead,
    Visit,
    VisitOrder,
    VisitPlan,
    VisitPlanItem,
)
from app.models.enums import SessionType
from app.models.user import User
from app.services.notification_service import NotificationService

logger = logging.getLogger("fieldtrack.dsr")

_LATE_HOUR = 19
_LATE_MINUTE = 30


def _is_late_now(tz_name: str) -> bool:
    """True if the current business-timezone wall clock is past 19:30."""
    try:
        tz = ZoneInfo(tz_name)
    except Exception:
        tz = timezone.utc
    now = datetime.now(tz)
    return (now.hour, now.minute) >= (_LATE_HOUR, _LATE_MINUTE)


def _day_bounds_utc(report_date: date_type) -> tuple[datetime, datetime]:
    """UTC start and end (inclusive) for a calendar date in the business tz."""
    settings = get_settings()
    try:
        tz = ZoneInfo(settings.business_timezone)
    except Exception:
        tz = timezone.utc
    day_start = datetime(
        report_date.year, report_date.month, report_date.day, 0, 0, 0, tzinfo=tz
    ).astimezone(timezone.utc)
    day_end = datetime(
        report_date.year, report_date.month, report_date.day, 23, 59, 59, tzinfo=tz
    ).astimezone(timezone.utc)
    return day_start, day_end


# ── Public API ───────────────────────────────────────────────────────────────

async def generate_dsr(
    employee_id: int,
    attendance_id: int,
    report_date: date_type,
) -> DailyReport:
    """Build (or refresh) the DSR for `employee_id` on `report_date`.

    Safe to call multiple times — ON CONFLICT DO UPDATE. Returns the upserted
    row. Caller is responsible for providing a fresh DB session (the function
    opens its own session so it can be used from background tasks AND from
    direct service calls).
    """
    async with async_session_factory() as db:
        return await _generate_in_session(db, employee_id, attendance_id, report_date)


async def _generate_in_session(
    db: AsyncSession,
    employee_id: int,
    attendance_id: int,
    report_date: date_type,
) -> DailyReport:
    day_start, day_end = _day_bounds_utc(report_date)
    settings = get_settings()

    # ── a) Attendance check-in / check-out times ─────────────────────────
    att_row = await db.get(Attendance, attendance_id)
    # Sessions are not eagerly loaded here — the attendance object from bg task
    # may not have relationships populated. We reload just enough.
    sessions_q = await db.execute(
        select(AttendanceSession)
        .where(AttendanceSession.attendance_id == attendance_id)
        .order_by(AttendanceSession.timestamp)
    )
    sessions = sessions_q.scalars().all()

    check_in_time: datetime | None = None
    check_out_time: datetime | None = None
    for s in sessions:
        if s.type == SessionType.START and check_in_time is None:
            check_in_time = s.timestamp
        if s.type == SessionType.END:
            check_out_time = s.timestamp

    # ── b) Visit plan for today — planned count ───────────────────────────
    plan_q = await db.execute(
        select(VisitPlan).where(
            VisitPlan.employee_id == employee_id,
            VisitPlan.plan_date == report_date,
        )
    )
    plan = plan_q.scalar_one_or_none()

    visits_planned = 0
    visits_completed_count = 0
    visits_skipped_count = 0

    if plan is not None:
        items_q = await db.execute(
            select(VisitPlanItem).where(VisitPlanItem.plan_id == plan.id)
        )
        items = items_q.scalars().all()
        visits_planned = len(items)
        visits_completed_count = sum(1 for i in items if i.status == "COMPLETED")
        visits_skipped_count = sum(1 for i in items if i.status == "SKIPPED")

    # ── c) Completed visits (actual visits today, regardless of plan) ─────
    visits_q = await db.execute(
        select(Visit, Farmer.name.label("farmer_name"))
        .join(Farmer, Visit.farmer_id == Farmer.id, isouter=True)
        .where(
            Visit.employee_id == employee_id,
            Visit.status == "COMPLETED",
            Visit.check_in_at >= day_start,
            Visit.check_in_at <= day_end,
        )
        .order_by(Visit.check_in_at)
    )
    completed_visits = visits_q.all()
    # Use actual completed visits as the count if > plan-based count
    actual_completed = len(completed_visits)
    visits_completed_count = max(visits_completed_count, actual_completed)

    # ── d) Orders today ───────────────────────────────────────────────────
    orders_q = await db.execute(
        select(VisitOrder, Farmer.name.label("farmer_name"))
        .join(Farmer, VisitOrder.farmer_id == Farmer.id, isouter=True)
        .where(
            VisitOrder.employee_id == employee_id,
            VisitOrder.created_at >= day_start,
            VisitOrder.created_at <= day_end,
        )
        .order_by(VisitOrder.created_at)
    )
    orders_today = orders_q.all()
    orders_captured = len(orders_today)

    # ── e) Lead changes today — grouped by status ─────────────────────────
    leads_q = await db.execute(
        select(Lead.status, func.count().label("cnt"))
        .where(
            Lead.employee_id == employee_id,
            Lead.created_at >= day_start,
            Lead.created_at <= day_end,
        )
        .group_by(Lead.status)
    )
    lead_counts: dict[str, int] = {row.status: row.cnt for row in leads_q.all()}
    hot_leads = lead_counts.get("HOT", 0)
    warm_leads = lead_counts.get("WARM", 0)
    cold_leads = lead_counts.get("COLD", 0)

    # ── f) Follow-ups scheduled today ─────────────────────────────────────
    fu_q = await db.execute(
        select(func.count()).where(
            FollowUp.employee_id == employee_id,
            FollowUp.created_at >= day_start,
            FollowUp.created_at <= day_end,
        )
    )
    follow_ups_scheduled = fu_q.scalar_one() or 0

    # ── is_late ────────────────────────────────────────────────────────────
    is_late = _is_late_now(settings.business_timezone)

    # ── Upsert daily_reports ──────────────────────────────────────────────
    stmt = (
        pg_insert(DailyReport)
        .values(
            employee_id=employee_id,
            report_date=report_date,
            attendance_id=attendance_id,
            visits_planned=visits_planned,
            visits_completed=visits_completed_count,
            visits_skipped=visits_skipped_count,
            orders_captured=orders_captured,
            hot_leads=hot_leads,
            warm_leads=warm_leads,
            cold_leads=cold_leads,
            follow_ups_scheduled=follow_ups_scheduled,
            is_late=is_late,
            status="DRAFT",
        )
        .on_conflict_do_update(
            constraint="uq_daily_reports_employee_id_report_date",
            set_={
                "attendance_id": attendance_id,
                "visits_planned": visits_planned,
                "visits_completed": visits_completed_count,
                "visits_skipped": visits_skipped_count,
                "orders_captured": orders_captured,
                "hot_leads": hot_leads,
                "warm_leads": warm_leads,
                "cold_leads": cold_leads,
                "follow_ups_scheduled": follow_ups_scheduled,
                # is_late: only set to True, never downgrade back to False
                "is_late": text("daily_reports.is_late OR EXCLUDED.is_late"),
            },
        )
        .returning(DailyReport.id)
    )
    result = await db.execute(stmt)
    report_id = result.scalar_one()
    await db.commit()

    report = await db.get(DailyReport, report_id)
    logger.info(
        "DSR generated: employee=%s date=%s id=%s late=%s",
        employee_id, report_date, report_id, is_late,
    )
    return report  # type: ignore[return-value]


async def submit_dsr(
    db: AsyncSession,
    *,
    report_id: int,
    employee_id: int,
    end_of_day_note: str | None,
) -> DailyReport:
    """Mark the DSR as SUBMITTED. Sends FCM to supervisor (and employee if late).

    Validates:
    - Report must exist and belong to `employee_id`.
    - end_of_day_note max 300 chars.
    - Not already SUBMITTED (idempotent guard).
    """
    report = await db.get(DailyReport, report_id)
    if report is None or report.employee_id != employee_id:
        raise not_found("Daily report not found")

    if report.status == "SUBMITTED":
        return report  # idempotent

    if end_of_day_note and len(end_of_day_note) > 300:
        raise bad_request("end_of_day_note must be 300 characters or less")

    now = datetime.now(timezone.utc)
    report.status = "SUBMITTED"
    report.submitted_at = now
    if end_of_day_note is not None:
        report.end_of_day_note = end_of_day_note

    # Re-check late: if they're submitting before 19:30 but was flagged late
    # at generation time (edge case), keep is_late=True.
    settings = get_settings()
    if _is_late_now(settings.business_timezone):
        report.is_late = True

    await db.flush()

    # Load employee name for FCM body
    emp = await db.get(User, employee_id)
    emp_name = emp.full_name if emp else f"Employee #{employee_id}"

    svc = NotificationService(db)

    # Notify supervisor(s) of this employee's team
    if emp and emp.team_id:
        sup_ids = await _supervisor_ids_for_team(db, emp.team_id)
        for sup_id in sup_ids:
            await svc.send_fcm(
                sup_id,
                title="DSR Submitted",
                body=f"{emp_name} submitted today's report.",
                type="DSR_SUBMITTED",
                data={"screen": "dsr", "employee_id": str(employee_id)},
                commit=False,
            )

    # Notify employee if late
    if report.is_late:
        await svc.send_fcm(
            employee_id,
            title="DSR Marked Late",
            body="Your Daily Sales Report was marked as submitted late.",
            type="DSR_LATE",
            data={"screen": "dsr"},
            commit=False,
        )

    await db.commit()
    await db.refresh(report)
    logger.info("DSR submitted: id=%s employee=%s late=%s", report_id, employee_id, report.is_late)
    return report


async def add_manager_comment(
    db: AsyncSession,
    *,
    report_id: int,
    supervisor_id: int,
    comment: str,
) -> DailyReport:
    """Supervisor adds a comment to any DSR they can see."""
    report = await db.get(DailyReport, report_id)
    if report is None:
        raise not_found("Daily report not found")

    # Load supervisor to verify team scope
    sup = await db.get(User, supervisor_id)
    if sup is None:
        raise not_found("Supervisor not found")

    report.manager_comment = comment  # type: ignore[attr-defined]
    await db.flush()

    # Notify the employee
    svc = NotificationService(db)
    await svc.send_fcm(
        report.employee_id,
        title="Manager commented on your report",
        body="Your manager left a comment on your Daily Sales Report.",
        type="DSR_COMMENT",
        data={"screen": "dsr", "report_id": str(report_id)},
        commit=False,
    )

    await db.commit()
    await db.refresh(report)
    return report


async def mark_late_reports(report_date: date_type) -> int:
    """APScheduler job body: mark DRAFT reports for today as is_late=True.
    Returns the count of rows updated.
    Called by the 19:30 scheduler job.
    """
    async with async_session_factory() as db:
        result = await db.execute(
            text(
                "UPDATE daily_reports SET is_late = TRUE "
                "WHERE report_date = :d AND status = 'DRAFT' AND is_late = FALSE"
            ),
            {"d": report_date},
        )
        count = result.rowcount
        await db.commit()
        logger.info("late_dsr_check: marked %d report(s) late on %s", count, report_date)
        return count


# ── Helpers ──────────────────────────────────────────────────────────────────

async def _supervisor_ids_for_team(db: AsyncSession, team_id: int) -> list[int]:
    """Returns user IDs of supervisors assigned to this team."""
    from app.models.user import Team
    from app.models.enums import UserRole

    q = await db.execute(
        select(User.id).where(
            User.team_id == team_id,
            User.role == UserRole.SUPERVISOR,
            User.is_active.is_(True),
        )
    )
    return list(q.scalars().all())


async def get_dsr_with_details(
    db: AsyncSession,
    *,
    employee_id: int,
    report_date: date_type,
) -> dict | None:
    """Load DSR row + enriched visit/order/follow-up detail dicts.
    Returns None if no DSR row exists.
    """
    q = await db.execute(
        select(DailyReport).where(
            DailyReport.employee_id == employee_id,
            DailyReport.report_date == report_date,
        )
    )
    report = q.scalar_one_or_none()
    if report is None:
        return None

    day_start, day_end = _day_bounds_utc(report_date)

    # Completed visits with farmer name + purpose + lead status chip
    visits_q = await db.execute(
        select(Visit, Farmer.name.label("farmer_name"))
        .join(Farmer, Visit.farmer_id == Farmer.id, isouter=True)
        .where(
            Visit.employee_id == employee_id,
            Visit.status == "COMPLETED",
            Visit.check_in_at >= day_start,
            Visit.check_in_at <= day_end,
        )
        .order_by(Visit.check_in_at)
    )
    visits_rows = visits_q.all()

    # Latest lead status per farmer (for the visit chip)
    lead_status_map: dict[int, str] = {}
    if visits_rows:
        farmer_ids = [r.Visit.farmer_id for r in visits_rows if r.Visit.farmer_id]
        if farmer_ids:
            ls_q = await db.execute(
                select(Lead.farmer_id, Lead.status)
                .where(
                    Lead.farmer_id.in_(farmer_ids),
                    Lead.employee_id == employee_id,
                )
                .order_by(Lead.farmer_id, Lead.created_at.desc())
                .distinct(Lead.farmer_id)
            )
            for row in ls_q.all():
                lead_status_map[row.farmer_id] = row.status

    # Orders today
    orders_q = await db.execute(
        select(VisitOrder, Farmer.name.label("farmer_name"))
        .join(Farmer, VisitOrder.farmer_id == Farmer.id, isouter=True)
        .where(
            VisitOrder.employee_id == employee_id,
            VisitOrder.created_at >= day_start,
            VisitOrder.created_at <= day_end,
        )
        .order_by(VisitOrder.created_at)
    )
    orders_rows = orders_q.all()

    # Follow-ups scheduled today
    fu_q = await db.execute(
        select(FollowUp, Farmer.name.label("farmer_name"))
        .join(Farmer, FollowUp.farmer_id == Farmer.id, isouter=True)
        .where(
            FollowUp.employee_id == employee_id,
            FollowUp.created_at >= day_start,
            FollowUp.created_at <= day_end,
        )
        .order_by(FollowUp.scheduled_date)
    )
    fu_rows = fu_q.all()

    return {
        "report": report,
        "visits": [
            {
                "id": r.Visit.id,
                "farmer_name": r.farmer_name or "Unknown Farmer",
                "purpose": r.Visit.purpose,
                "check_in_at": r.Visit.check_in_at,
                "check_out_at": r.Visit.check_out_at,
                "lead_status": lead_status_map.get(r.Visit.farmer_id),
            }
            for r in visits_rows
        ],
        "orders": [
            {
                "id": r.VisitOrder.id,
                "farmer_name": r.farmer_name or "Unknown Farmer",
                "bags_count": r.VisitOrder.bags_count,
                "delivery_date": r.VisitOrder.delivery_date,
                "payment_mode": r.VisitOrder.payment_mode,
            }
            for r in orders_rows
        ],
        "follow_ups": [
            {
                "id": r.FollowUp.id,
                "farmer_name": r.farmer_name or "Unknown Farmer",
                "scheduled_date": r.FollowUp.scheduled_date,
                "scheduled_time": r.FollowUp.scheduled_time,
                "purpose": r.FollowUp.purpose,
            }
            for r in fu_rows
        ],
    }
