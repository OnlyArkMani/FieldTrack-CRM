"""Daily Sales Report (DSR) service — Module 5.

generate_dsr           → called as a background task on a manual attendance END
                         (leaves the report in DRAFT for the employee to review).
generate_and_submit_dsr → called as a background task when END is the
                         auto-clock-out fired by mobile logout (checklist #52).
submit_dsr             → called explicitly by the employee after reviewing the
                         draft, or internally by generate_and_submit_dsr.

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
from decimal import Decimal
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
    LivestockProfile,
    Visit,
    VisitNote,
    VisitOrder,
    VisitPlan,
    VisitPlanItem,
)
from app.models.enums import SessionType, UserRole
from app.models.user import Team, User
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


async def generate_and_submit_dsr(
    employee_id: int,
    attendance_id: int,
    report_date: date_type,
) -> DailyReport:
    """Generate the DSR and immediately submit it (checklist #52 — auto-submit
    on logout, as opposed to the manual "Submit DSR" tap used for a plain
    /attendance/end without logging out). Runs generate + submit in the same
    session so there's no gap where a client could observe a DRAFT that
    never gets submitted."""
    async with async_session_factory() as db:
        report = await _generate_in_session(db, employee_id, attendance_id, report_date)
        return await submit_dsr(
            db, report_id=report.id, employee_id=employee_id, end_of_day_note=None,
        )


def _checkpoints_from_sessions(sessions) -> dict:
    """First START and last END timestamp+lat/lng from a list of
    AttendanceSession rows, ordered by timestamp. Shared by DSR generation
    and by the detail-view live override (checklist #46)."""
    check_in_time: datetime | None = None
    check_out_time: datetime | None = None
    check_in_lat: float | None = None
    check_in_lng: float | None = None
    check_out_lat: float | None = None
    check_out_lng: float | None = None
    for s in sessions:
        if s.type == SessionType.START and check_in_time is None:
            check_in_time = s.timestamp
            check_in_lat = s.lat
            check_in_lng = s.lng
        if s.type == SessionType.END:
            check_out_time = s.timestamp
            check_out_lat = s.lat
            check_out_lng = s.lng
    return {
        "check_in_at": check_in_time,
        "check_out_at": check_out_time,
        "check_in_lat": check_in_lat,
        "check_in_lng": check_in_lng,
        "check_out_lat": check_out_lat,
        "check_out_lng": check_out_lng,
    }


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
    checkpoints = _checkpoints_from_sessions(sessions)
    check_in_time = checkpoints["check_in_at"]
    check_out_time = checkpoints["check_out_at"]
    check_in_lat = checkpoints["check_in_lat"]
    check_in_lng = checkpoints["check_in_lng"]
    check_out_lat = checkpoints["check_out_lat"]
    check_out_lng = checkpoints["check_out_lng"]

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
    order_values = [
        r.VisitOrder.bags_count * r.VisitOrder.price_per_bag
        for r in orders_today
        if r.VisitOrder.price_per_bag is not None
    ]
    orders_value = sum(order_values) if order_values else None

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
            orders_value=orders_value,
            hot_leads=hot_leads,
            warm_leads=warm_leads,
            cold_leads=cold_leads,
            follow_ups_scheduled=follow_ups_scheduled,
            check_in_at=check_in_time,
            check_out_at=check_out_time,
            check_in_lat=check_in_lat,
            check_in_lng=check_in_lng,
            check_out_lat=check_out_lat,
            check_out_lng=check_out_lng,
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
                "orders_value": orders_value,
                "hot_leads": hot_leads,
                "warm_leads": warm_leads,
                "cold_leads": cold_leads,
                "follow_ups_scheduled": follow_ups_scheduled,
                "check_in_at": check_in_time,
                "check_out_at": check_out_time,
                "check_in_lat": check_in_lat,
                "check_in_lng": check_in_lng,
                "check_out_lat": check_out_lat,
                "check_out_lng": check_out_lng,
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
    emp_name = emp.name if emp else f"Employee #{employee_id}"

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


async def mark_late_reports(report_date: date_type) -> list[tuple[int, str, int | None]]:
    """APScheduler job body: mark DRAFT reports for today as is_late=True.
    Returns (employee_id, employee_name, team_id) for each newly-late report,
    so the scheduler can notify supervisors with an individual per-employee
    flag instead of just an aggregate count (checklist #53).
    Called by the 19:30 scheduler job.
    """
    async with async_session_factory() as db:
        # Select the about-to-flip rows FIRST — the UPDATE alone can't tell us
        # who they belong to.
        rows = (
            await db.execute(
                select(DailyReport.employee_id, User.name, User.team_id)
                .join(User, User.id == DailyReport.employee_id)
                .where(
                    DailyReport.report_date == report_date,
                    DailyReport.status == "DRAFT",
                    DailyReport.is_late.is_(False),
                )
            )
        ).all()
        if not rows:
            return []
        await db.execute(
            text(
                "UPDATE daily_reports SET is_late = TRUE "
                "WHERE report_date = :d AND status = 'DRAFT' AND is_late = FALSE"
            ),
            {"d": report_date},
        )
        await db.commit()
        logger.info("late_dsr_check: marked %d report(s) late on %s", len(rows), report_date)
        return [(r[0], r[1], r[2]) for r in rows]


# ── Helpers ──────────────────────────────────────────────────────────────────

async def _supervisor_ids_for_team(db: AsyncSession, team_id: int) -> list[int]:
    """Returns user IDs of supervisors assigned to this team.

    A team's supervisor is `Team.supervisor_id` — the FK `TeamService.create`/
    `update` actually maintain — NOT `User.team_id`. `User.team_id` is only
    ever set via `TeamService.add_member`/`remove_member`, which is for
    employees joining a team; the supervisor's own `team_id` is never
    populated by the app. Fixed: this used to filter on `User.team_id`,
    which silently returned zero supervisors for any team assigned through
    the normal admin API — it only ever worked in this session's own testing
    because `scripts/seed_users.py` happens to also set the supervisor's
    `team_id` as a seeding convenience, masking the bug."""
    from app.models.user import Team
    from app.models.enums import UserRole

    q = await db.execute(
        select(User.id)
        .join(Team, Team.supervisor_id == User.id)
        .where(
            Team.id == team_id,
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

    # Live override for check-in/out time+location (checklist #46) — the
    # daily_reports snapshot is only written once at generation time and can
    # go stale (e.g. generated before check-out, or a report row created via
    # a path that skipped it). Re-derive from the session log so the detail
    # view always matches reality, same as the team-list endpoint already
    # does independently in `_attendance_times()`.
    checkpoints: dict = {}
    if report.attendance_id is not None:
        sessions_q = await db.execute(
            select(AttendanceSession)
            .where(AttendanceSession.attendance_id == report.attendance_id)
            .order_by(AttendanceSession.timestamp)
        )
        checkpoints = _checkpoints_from_sessions(sessions_q.scalars().all())

    day_start, day_end = _day_bounds_utc(report_date)

    # Completed visits with farmer name/location + purpose + lead status chip
    # + meeting highlights and farmer concerns (checklist #47 location, #48 highlights).
    visits_q = await db.execute(
        select(
            Visit,
            Farmer.name.label("farmer_name"),
            Farmer.village.label("village"),
            Farmer.district.label("district"),
            Farmer.customer_type.label("customer_type"),
            VisitNote.meeting_highlights.label("meeting_highlights"),
            VisitNote.farmer_concerns.label("farmer_concerns"),
            VisitNote.product_interest.label("product_interest"),
        )
        .join(Farmer, Visit.farmer_id == Farmer.id, isouter=True)
        .outerjoin(VisitNote, VisitNote.visit_id == Visit.id)
        .where(
            Visit.employee_id == employee_id,
            Visit.status == "COMPLETED",
            Visit.check_in_at >= day_start,
            Visit.check_in_at <= day_end,
        )
        .order_by(Visit.check_in_at)
    )
    visits_rows = visits_q.all()

    # Per-visit order roll-up (bags + value) and latest livestock snapshot, so
    # each DSR visit row can expand to full detail (DSR drill-down).
    visit_ids = [r.Visit.id for r in visits_rows]
    orders_by_visit: dict[int, tuple[int, Decimal | None]] = {}
    livestock_by_visit: dict[int, LivestockProfile] = {}
    if visit_ids:
        ovr = await db.execute(
            select(VisitOrder).where(VisitOrder.visit_id.in_(visit_ids))
        )
        for o in ovr.scalars().all():
            bags, val = orders_by_visit.get(o.visit_id, (0, None))
            bags += o.bags_count or 0
            if o.price_per_bag is not None:
                val = (val or Decimal(0)) + o.price_per_bag * (o.bags_count or 0)
            orders_by_visit[o.visit_id] = (bags, val)
        lsr = await db.execute(
            select(LivestockProfile)
            .where(LivestockProfile.visit_id.in_(visit_ids))
            .order_by(LivestockProfile.id.desc())
        )
        for ls in lsr.scalars().all():
            livestock_by_visit.setdefault(ls.visit_id, ls)

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
        select(
            VisitOrder,
            Farmer.name.label("farmer_name"),
            Farmer.customer_type.label("customer_type"),
        )
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
        "checkpoints": checkpoints,
        "visits": [
            {
                "id": r.Visit.id,
                "farmer_id": r.Visit.farmer_id,
                "farmer_name": r.farmer_name or "Unknown Farmer",
                "village": r.village,
                "district": r.district,
                "customer_type": r.customer_type or "FARMER",
                "purpose": r.Visit.purpose,
                "check_in_at": r.Visit.check_in_at,
                "check_out_at": r.Visit.check_out_at,
                "check_in_lat": r.Visit.check_in_lat,
                "check_in_lng": r.Visit.check_in_lng,
                "lead_status": lead_status_map.get(r.Visit.farmer_id),
                "meeting_highlights": r.meeting_highlights,
                "farmer_concerns": r.farmer_concerns,
                "product_interest": r.product_interest,
                "vet_required": bool(r.Visit.vet_required),
                "vet_cattle_count": r.Visit.vet_cattle_count,
                "order_bags": orders_by_visit.get(r.Visit.id, (0, None))[0] or None,
                "order_value": orders_by_visit.get(r.Visit.id, (0, None))[1],
                "breed": (
                    livestock_by_visit[r.Visit.id].breed
                    if r.Visit.id in livestock_by_visit
                    else None
                ),
                "current_brand": (
                    livestock_by_visit[r.Visit.id].current_brand
                    if r.Visit.id in livestock_by_visit
                    else None
                ),
                "livestock_cattle": (
                    livestock_by_visit[r.Visit.id].total_cattle
                    if r.Visit.id in livestock_by_visit
                    else None
                ),
                "price_per_bag": (
                    livestock_by_visit[r.Visit.id].current_price_per_bag
                    if r.Visit.id in livestock_by_visit
                    else None
                ),
            }
            for r in visits_rows
        ],
        "orders": [
            {
                "id": r.VisitOrder.id,
                "farmer_name": r.farmer_name or "Unknown Farmer",
                "customer_type": r.customer_type or "FARMER",
                "bags_count": r.VisitOrder.bags_count,
                "delivery_date": r.VisitOrder.delivery_date,
                "payment_mode": r.VisitOrder.payment_mode,
                "price_per_bag": r.VisitOrder.price_per_bag,
                "total_value": (
                    r.VisitOrder.bags_count * r.VisitOrder.price_per_bag
                    if r.VisitOrder.price_per_bag is not None
                    else None
                ),
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


async def visits_export_rows(
    db: AsyncSession,
    *,
    user: User,
    date_from: date_type,
    date_to: date_type,
    team_id: int | None = None,
    employee_id: int | None = None,
) -> list[dict]:
    """One dict per COMPLETED visit across the caller's scope in [date_from,
    date_to] — powers the granular per-visit Excel export (checklist: each
    employee's each visit detail). ADMIN sees all (optional team/employee
    filter); SUPERVISOR is pinned to their own team; EMPLOYEE forbidden."""
    if user.role not in (UserRole.ADMIN, UserRole.SUPERVISOR):
        raise bad_request("Not permitted")

    start, _ = _day_bounds_utc(date_from)
    _, end = _day_bounds_utc(date_to)

    filters = [
        Visit.status == "COMPLETED",
        Visit.check_in_at >= start,
        Visit.check_in_at <= end,
    ]
    if user.role == UserRole.SUPERVISOR:
        if not user.team_id:
            return []
        filters.append(User.team_id == user.team_id)
    elif team_id is not None:
        filters.append(User.team_id == team_id)
    if employee_id is not None:
        filters.append(Visit.employee_id == employee_id)

    q = (
        select(
            Visit,
            Farmer.name.label("farmer_name"),
            Farmer.customer_type.label("customer_type"),
            Farmer.village.label("village"),
            Farmer.district.label("district"),
            User.name.label("employee_name"),
            Team.name.label("team_name"),
            VisitNote.meeting_highlights.label("meeting_highlights"),
            VisitNote.farmer_concerns.label("farmer_concerns"),
            VisitNote.product_interest.label("product_interest"),
            Lead.status.label("lead_status"),
        )
        .join(Farmer, Visit.farmer_id == Farmer.id, isouter=True)
        .join(User, Visit.employee_id == User.id, isouter=True)
        .join(Team, User.team_id == Team.id, isouter=True)
        .outerjoin(VisitNote, VisitNote.visit_id == Visit.id)
        .outerjoin(Lead, Lead.visit_id == Visit.id)
        .where(*filters)
        .order_by(Visit.check_in_at)
    )
    rows = (await db.execute(q)).all()
    visit_ids = [r.Visit.id for r in rows]

    orders_by_visit: dict[int, tuple[int, Decimal | None]] = {}
    livestock_by_visit: dict[int, LivestockProfile] = {}
    if visit_ids:
        ovr = await db.execute(
            select(VisitOrder).where(VisitOrder.visit_id.in_(visit_ids))
        )
        for o in ovr.scalars().all():
            bags, val = orders_by_visit.get(o.visit_id, (0, None))
            bags += o.bags_count or 0
            if o.price_per_bag is not None:
                val = (val or Decimal(0)) + o.price_per_bag * (o.bags_count or 0)
            orders_by_visit[o.visit_id] = (bags, val)
        lsr = await db.execute(
            select(LivestockProfile)
            .where(LivestockProfile.visit_id.in_(visit_ids))
            .order_by(LivestockProfile.id.desc())
        )
        for ls in lsr.scalars().all():
            livestock_by_visit.setdefault(ls.visit_id, ls)

    out: list[dict] = []
    for r in rows:
        v = r.Visit
        ls = livestock_by_visit.get(v.id)
        bags, val = orders_by_visit.get(v.id, (0, None))
        duration = None
        if v.check_in_at and v.check_out_at:
            duration = round((v.check_out_at - v.check_in_at).total_seconds() / 60)
        out.append(
            {
                "date": v.check_in_at.date() if v.check_in_at else None,
                "employee": r.employee_name or "",
                "team": r.team_name or "",
                "customer": r.farmer_name or "",
                "type": r.customer_type or "FARMER",
                "village": r.village or "",
                "district": r.district or "",
                "check_in": v.check_in_at,
                "check_out": v.check_out_at,
                "lat": v.check_in_lat,
                "lng": v.check_in_lng,
                "duration_min": duration,
                "location_warning": "Yes" if v.location_warning else "",
                "lead": r.lead_status or "",
                "order_bags": bags or "",
                "order_value": val,
                "vet_needed": "Yes" if v.vet_required else "",
                "vet_cattle": v.vet_cattle_count,
                "breed": (ls.breed if ls else "") or "",
                "current_brand": (ls.current_brand if ls else "") or "",
                "cattle": ls.total_cattle if ls else None,
                "price_per_bag": ls.current_price_per_bag if ls else None,
                "highlights": r.meeting_highlights or "",
                "concerns": r.farmer_concerns or "",
                "product_interest": r.product_interest or "",
            }
        )
    return out
