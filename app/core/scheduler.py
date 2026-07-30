"""Daily notification & maintenance jobs (in-process APScheduler).

WHY HERE (not Celery): single VPS, a handful of cron jobs — see ARCHITECTURE.md.
The existing housekeeping scheduler lives in main.py's lifespan; this module
owns the *human-facing* daily jobs and is wired in alongside it.

SCHEDULE (business-local wall clock — settings.business_timezone, default
Asia/Kolkata):
  09:00  ATTENDANCE_REMINDER  -> active field users with no attendance today
  18:00  END_WORK_REMINDER    -> active field users started-but-not-ended today
  19:00  AUTO_CHECKOUT        -> force-end anyone still on the clock + auto-submit DSR
  23:00  redis cleanup        -> defensive TTL sweep of live keys
  :00/:30 VISIT_REMINDER      -> employees with a planned visit ~1h away

TIMEZONE NOTE: APScheduler fires on the business tz, but the "today" used to
query attendance is the UTC calendar date — that's how attendance.date is
stored (attendance_service._today). For Asia/Kolkata (UTC+5:30) 09:00/18:00/
23:00 all fall on the same UTC date, so the two agree. If deployed to a tz
where a reminder hour crosses UTC midnight, revisit this.

MULTI-WORKER: with >1 uvicorn worker each process holds a scheduler. The
reminder jobs are idempotent-ish (a duplicate run would create a second
notification row); we guard with a short Redis lock so only one worker runs
each fire. coalesce + max_instances=1 guard against pile-ups within a process.
"""
import logging
from collections import defaultdict
from datetime import date as date_type
from datetime import datetime, time, timedelta, timezone
from math import asin, cos, radians, sin, sqrt
from zoneinfo import ZoneInfo

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

from app.core.config import get_settings
from app.core.database import async_session_factory
from app.core.redis import Keys, get_redis
from app.repositories.attendance_repository import AttendanceRepository
from app.repositories.follow_up_repository import FollowUpRepository
from app.repositories.location_repository import LocationRepository
from app.repositories.notification_repository import NotificationRepository
from app.repositories.report_repository import ReportRepository
from app.repositories.visit_plan_repository import VisitPlanRepository
from app.schemas.report import ReportFormat
from app.services.attendance_service import AttendanceService
from app.services.dsr_service import (
    _manager_ids_for_team,
    business_today,
    generate_and_submit_dsr,
    mark_late_reports,
)
from app.services.notification_service import NotificationService
from app.services.report_service import generate_team_report_file

# Stationary detection tuning: an on-clock executive whose trailing-window pings
# all sit inside this radius for at least this long is flagged idle.
_STATIONARY_RADIUS_M = 75.0
_STATIONARY_MIN_MINUTES = 90
# Weekly/monthly auto-report download links live this long (seconds).
_WEEKLY_REPORT_TTL = 8 * 86400
_MONTHLY_REPORT_TTL = 40 * 86400


def _haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Great-circle distance in metres between two lat/lng points."""
    radius = 6_371_000.0
    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2 - lat1)
    dlmb = radians(lng2 - lng1)
    a = sin(dphi / 2) ** 2 + cos(p1) * cos(p2) * sin(dlmb / 2) ** 2
    return 2 * radius * asin(min(1.0, sqrt(a)))

logger = logging.getLogger("fieldtrack.scheduler")

# A fired job holds this lock briefly so only ONE worker actually runs it.
_LOCK_TTL_SECONDS = 300


async def _claim(job_key: str) -> bool:
    """Single-winner guard across uvicorn workers. SET NX EX — the first worker
    to land takes the job; the rest no-op. Best-effort: if Redis is down we let
    the job run (a missing reminder is worse than a rare duplicate)."""
    try:
        r = get_redis()
        won = await r.set(
            f"{Keys.PREFIX}:scheduler:lock:{job_key}",
            "1",
            nx=True,
            ex=_LOCK_TTL_SECONDS,
        )
        return bool(won)
    except Exception:  # noqa: BLE001
        logger.warning("scheduler lock check failed; running job anyway")
        return True


def _today_utc():
    """UTC calendar date — matches how attendance.date is stored."""
    return datetime.now(timezone.utc).date()


def _business_now() -> datetime:
    """Current wall-clock time in the business timezone."""
    try:
        tz = ZoneInfo(get_settings().business_timezone)
    except Exception:  # noqa: BLE001 — bad/missing tz config -> UTC
        tz = timezone.utc
    return datetime.now(tz)


def _business_tomorrow():
    """Tomorrow's date in the business timezone — the day plans are made for."""
    return (_business_now() + timedelta(days=1)).date()


# ── Jobs ────────────────────────────────────────────────────────────────────
async def attendance_reminder_job() -> None:
    """09:00 — nudge every active field user who hasn't clocked in today."""
    if not await _claim(f"attendance_reminder:{_today_utc()}"):
        return
    async with async_session_factory() as db:
        repo = NotificationRepository(db)
        users = await repo.users_without_attendance_today(_today_utc())
        if not users:
            return
        service = NotificationService(db)
        for user in users:
            await service.attendance_reminder(user.id, commit=False)
        await db.commit()
        logger.info("ATTENDANCE_REMINDER sent to %d user(s)", len(users))


async def end_work_reminder_job() -> None:
    """18:00 — nudge every active field user still on the clock."""
    if not await _claim(f"end_work_reminder:{_today_utc()}"):
        return
    async with async_session_factory() as db:
        repo = NotificationRepository(db)
        users = await repo.users_started_not_ended_today(_today_utc())
        if not users:
            return
        service = NotificationService(db)
        for user in users:
            await service.end_work_reminder(user.id, commit=False)
        await db.commit()
        logger.info("END_WORK_REMINDER sent to %d user(s)", len(users))


async def redis_cleanup_job() -> None:
    """23:00 — defensive TTL sweep. All live keys (location, attendance state)
    are written WITH a TTL, so this is a safety net: any such key that somehow
    lost its expiry (manual ops, a crashed writer) gets a default TTL so it
    can't leak forever. Uses SCAN (non-blocking) — never KEYS."""
    if not await _claim(f"redis_cleanup:{_today_utc()}"):
        return
    try:
        r = get_redis()
        swept = 0
        for pattern, ttl in (
            (f"{Keys.PREFIX}:location:*", 7200),  # 2h, matches live-cache TTL
            (f"{Keys.PREFIX}:attendance:state:*", 86400),  # 24h
            (f"{Keys.PREFIX}:scheduler:lock:*", _LOCK_TTL_SECONDS),
        ):
            async for key in r.scan_iter(match=pattern, count=200):
                if await r.ttl(key) == -1:  # -1 = exists but no expiry set
                    await r.expire(key, ttl)
                    swept += 1
        if swept:
            logger.info("redis_cleanup applied TTL to %d orphan key(s)", swept)
    except Exception:  # noqa: BLE001
        logger.exception("redis_cleanup job failed")


async def check_unsubmitted_plans() -> None:
    """20:00 — find employees with no SUBMITTED plan for tomorrow. Nudge the
    employee to plan, and alert their team's manager that it's outstanding.

    Idempotent-ish: a duplicate run would create a second notification row, so
    the cross-worker claim lock guards it (keyed by tomorrow's date)."""
    tomorrow = _business_tomorrow()
    if not await _claim(f"unsubmitted_plans:{tomorrow}"):
        return
    async with async_session_factory() as db:
        repo = VisitPlanRepository(db)
        employees = await repo.all_active_employees_with_manager()
        submitted = await repo.submitted_employee_ids(tomorrow)
        service = NotificationService(db)

        notified = 0
        for emp_id, emp_name, _team_name, manager_id in employees:
            if emp_id in submitted:
                continue
            # Nudge the employee.
            await service.send_fcm(
                emp_id,
                title="Plan tomorrow's visits",
                body="Don't forget to plan tomorrow's visits.",
                type="PLAN_REMINDER",
                data={"screen": "planning"},
                commit=False,
            )
            # Alert the manager (never the employee themselves).
            if manager_id and manager_id != emp_id:
                await service.send_fcm(
                    manager_id,
                    title="Plan not submitted",
                    body=f"{emp_name} has not submitted tomorrow's visit plan.",
                    type="PLAN_NOT_SUBMITTED",
                    data={"screen": "planning", "employee_id": str(emp_id)},
                    commit=False,
                )
            notified += 1

        await db.commit()
        if notified:
            logger.info(
                "unsubmitted-plan reminders sent for %d employee(s)", notified
            )


async def missed_visits_reminder_job() -> None:
    """18:30 — nudge employees who still have PLANNED (unvisited) stops on
    today's plan, and alert their manager. Those stops auto-carry-over onto
    the next day's plan where the employee can reschedule or drop them."""
    today = _today_utc()
    if not await _claim(f"missed_visits:{today}"):
        return
    async with async_session_factory() as db:
        repo = VisitPlanRepository(db)
        rows = await repo.employees_with_missed_items(today)
        if not rows:
            return
        service = NotificationService(db)
        notified = 0
        for emp_id, emp_name, manager_id, missed in rows:
            if not missed:
                continue
            plural = "visit" if missed == 1 else "visits"
            await service.send_fcm(
                emp_id,
                title="Unvisited stops today",
                body=f"You have {missed} planned {plural} left. They'll carry "
                "over to tomorrow — reschedule or drop them.",
                type="MISSED_VISITS",
                data={"screen": "planning"},
                commit=False,
            )
            if manager_id and manager_id != emp_id:
                await service.send_fcm(
                    manager_id,
                    title="Missed visits",
                    body=f"{emp_name} has {missed} unvisited planned {plural} today.",
                    type="MISSED_VISITS_MANAGER",
                    data={"screen": "planning", "employee_id": str(emp_id)},
                    commit=False,
                )
            notified += 1
        await db.commit()
        if notified:
            logger.info("MISSED_VISITS reminders sent for %d employee(s)", notified)


def _fu_data(farmer_id: int | None) -> dict[str, str]:
    """Deep-link payload: a follow-up reminder opens the farmer's detail."""
    data = {"screen": "farmer"}
    if farmer_id is not None:
        data["farmer_id"] = str(farmer_id)
    return data


async def send_24h_followup_reminders() -> None:
    """08:00 — fallback reminder for follow-ups with NO scheduled_time (legacy
    rows, or ones scheduled via the standalone lead-status-update endpoint
    where time is optional). Follow-ups WITH a time are handled by
    `send_24h_followup_reminders_precise` instead (checklist #39)."""
    tomorrow = _business_tomorrow()
    if not await _claim(f"fu_24h:{tomorrow}"):
        return
    async with async_session_factory() as db:
        repo = FollowUpRepository(db)
        rows = await repo.due_24h(tomorrow)
        if not rows:
            return
        service = NotificationService(db)
        for fu, farmer_name in rows:
            await service.send_fcm(
                fu.employee_id,
                title="Follow-up tomorrow",
                body=f"Visit {farmer_name or 'a farmer'} tomorrow.",
                type="FOLLOW_UP_REMINDER",
                data=_fu_data(fu.farmer_id),
                commit=False,
            )
            fu.reminder_sent_24h = True
            db.add(fu)
        await db.commit()
        logger.info("FOLLOW_UP 24h (no-time fallback) reminders sent: %d", len(rows))


async def send_24h_followup_reminders_precise() -> None:
    """Every 30 min — remind employees of follow-ups exactly ~24h away, for
    follow-ups that DO have a scheduled_time. Checklist #39 wants a rolling
    24h window rather than a single fixed-hour daily blast; this checks a
    30-minute window centered on now+24h each time it runs, so the reminder
    lands within ~30 min of the true 24h mark instead of the old ~16-32h
    spread from the once-a-day 08:00 job."""
    now = _business_now()
    if not await _claim(f"fu_24h_precise:{now.strftime('%Y%m%d%H%M')}"):
        return
    window_start = now + timedelta(hours=24)
    window_end = window_start + timedelta(minutes=30)
    async with async_session_factory() as db:
        repo = FollowUpRepository(db)
        rows = await repo.due_24h_precise(window_start, window_end)
        if not rows:
            return
        service = NotificationService(db)
        for fu, farmer_name in rows:
            when = fu.scheduled_time.strftime("%H:%M")
            await service.send_fcm(
                fu.employee_id,
                title="Follow-up tomorrow",
                body=f"Visit {farmer_name or 'a farmer'} at {when}.",
                type="FOLLOW_UP_REMINDER",
                data=_fu_data(fu.farmer_id),
                commit=False,
            )
            fu.reminder_sent_24h = True
            db.add(fu)
        await db.commit()
        logger.info("FOLLOW_UP 24h (precise) reminders sent: %d", len(rows))


async def send_1h_followup_reminders() -> None:
    """Every 30 min — remind employees of follow-ups ~1 hour away (60±30 min)."""
    now = _business_now()
    today = now.date()
    if not await _claim(f"fu_1h:{now.strftime('%Y%m%d%H%M')}"):
        return
    t_from = (now + timedelta(minutes=30)).time()
    upper = now + timedelta(minutes=90)
    # Clamp to end-of-day if the window would spill into tomorrow.
    t_to = upper.time() if upper.date() == today else time(23, 59, 59)
    async with async_session_factory() as db:
        repo = FollowUpRepository(db)
        rows = await repo.due_1h(today, t_from, t_to)
        if not rows:
            return
        service = NotificationService(db)
        for fu, farmer_name in rows:
            await service.send_fcm(
                fu.employee_id,
                title="Follow-up in 1 hour",
                body=f"Follow-up with {farmer_name or 'a farmer'} is coming up.",
                type="FOLLOW_UP_REMINDER",
                data=_fu_data(fu.farmer_id),
                commit=False,
            )
            fu.reminder_sent_1h = True
            db.add(fu)
        await db.commit()
        logger.info("FOLLOW_UP 1h reminders sent: %d", len(rows))


def _visit_reminder_data(farmer_id: int | None) -> dict[str, str]:
    """Deep-link payload: a planned-visit reminder opens the farmer's detail."""
    data = {"screen": "farmer"}
    if farmer_id is not None:
        data["farmer_id"] = str(farmer_id)
    return data


async def send_visit_reminders() -> None:
    """Every 30 min — remind employees of a planned visit ~1 hour away
    (60±30 min), mirroring send_1h_followup_reminders (checklist B5)."""
    now = _business_now()
    today = now.date()
    if not await _claim(f"visit_reminder:{now.strftime('%Y%m%d%H%M')}"):
        return
    t_from = (now + timedelta(minutes=30)).time()
    upper = now + timedelta(minutes=90)
    # Clamp to end-of-day if the window would spill into tomorrow.
    t_to = upper.time() if upper.date() == today else time(23, 59, 59)
    async with async_session_factory() as db:
        repo = VisitPlanRepository(db)
        rows = await repo.due_visit_reminders(today, t_from, t_to)
        if not rows:
            return
        service = NotificationService(db)
        for item, employee_id, farmer_name in rows:
            when = item.time_slot.strftime("%H:%M") if item.time_slot else ""
            await service.send_fcm(
                employee_id,
                title="Visit coming up",
                body=f"Visit {farmer_name or 'a customer'} at {when}.",
                type="VISIT_REMINDER",
                data=_visit_reminder_data(item.farmer_id),
                commit=False,
            )
            item.reminder_sent = True
            db.add(item)
        await db.commit()
        logger.info("VISIT reminders sent: %d", len(rows))


async def escalate_unacknowledged_followups() -> None:
    """Hourly — escalate to the manager any of today's follow-ups still
    PENDING (un-acknowledged) more than 2 hours past their time."""
    now = _business_now()
    today = now.date()
    if not await _claim(f"fu_escalate:{now.strftime('%Y%m%d%H')}"):
        return
    cutoff_dt = now - timedelta(hours=2)
    # If 2h ago was yesterday, nothing today qualifies — use time.min (no match).
    cutoff_time = cutoff_dt.time() if cutoff_dt.date() == today else time.min
    async with async_session_factory() as db:
        repo = FollowUpRepository(db)
        rows = await repo.escalation_candidates(today, cutoff_time)
        if not rows:
            return
        service = NotificationService(db)
        escalated = 0
        for fu, farmer_name, employee_name, manager_id in rows:
            if manager_id and manager_id != fu.employee_id:
                await service.send_fcm(
                    manager_id,
                    title="Missed follow-up",
                    body=f"{employee_name or 'An employee'} missed a follow-up "
                    f"with {farmer_name or 'a farmer'}.",
                    type="FOLLOW_UP_ESCALATED",
                    data=_fu_data(fu.farmer_id),
                    commit=False,
                )
            fu.status = "ESCALATED"
            db.add(fu)
            escalated += 1
        await db.commit()
        logger.info("FOLLOW_UP escalations: %d", escalated)


async def auto_checkout_job() -> None:
    """19:00 — force-end anyone still on the clock (STARTED/RESUMED/ON_BREAK/
    RE_CHECKED_IN) and auto-submit their DSR, exactly as if they'd tapped End
    with no work summary (mobile's existing logout-triggered auto-checkout —
    see AttendanceService.auto_checkout / generate_and_submit_dsr).

    Population comes from AttendanceRepository.all_for_date_with_sessions +
    a real current-state check per row, NOT
    NotificationRepository.users_started_not_ended_today — that heuristic
    (has a START, has no END anywhere in history) wrongly skips someone who
    already ended once today and re-checked in, which is exactly the case
    this job must still catch.

    Each user is force-ended in their OWN db session/commit so one failure
    (e.g. a bad row) never blocks the rest — this touches payroll-relevant
    attendance data, so partial success beats an all-or-nothing transaction.
    """
    today = _today_utc()
    if not await _claim(f"auto_checkout:{today}"):
        return

    async with async_session_factory() as db:
        rows = await AttendanceRepository(db).all_for_date_with_sessions(today)
        open_user_ids = [
            row.user_id
            for row in rows
            if AttendanceService._state_of(row)
            in ("STARTED", "RESUMED", "ON_BREAK", "RE_CHECKED_IN")
        ]
    if not open_user_ids:
        logger.info("AUTO_CHECKOUT: ran at the 19:00 cutoff, nobody was on the clock")
        return

    report_date = business_today()
    closed = 0
    for user_id in open_user_ids:
        try:
            async with async_session_factory() as db:
                latest = await LocationRepository(db).latest_for_user(user_id)
                lat = latest.lat if latest else None
                lng = latest.lng if latest else None
                attendance = await AttendanceService(db).auto_checkout(
                    user_id, today, lat=lat, lng=lng
                )
            if attendance is None:
                continue  # already closed by the time we got here (manual End raced us)
            await generate_and_submit_dsr(user_id, attendance.id, report_date)
            closed += 1
        except Exception:  # noqa: BLE001
            logger.exception("auto_checkout failed for user %s", user_id)
    if closed:
        logger.info("AUTO_CHECKOUT: force-ended %d user(s) at the 19:00 cutoff", closed)


async def late_dsr_check_job() -> None:
    """19:30 — mark DRAFT DSRs as is_late; notify each late employee's team
    manager(s) individually (checklist #53 — was previously one aggregate
    "N employees late" FCM broadcast to every active manager regardless of
    team; now a per-employee flag sent only to that employee's own team
    manager(s)).

    Business rule: DSRs that are still DRAFT after 19:30 in the business
    timezone are marked late.
    """
    today = _today_utc()
    if not await _claim(f"late_dsr_check:{today}"):
        return
    try:
        late_rows = await mark_late_reports(today)
        if not late_rows:
            return
        async with async_session_factory() as db:
            svc = NotificationService(db)
            # Cache team -> manager lookups since multiple late employees
            # commonly share a team.
            team_managers: dict[int, list[int]] = {}
            notified = 0
            for employee_id, employee_name, team_id in late_rows:
                manager_ids: list[int] = []
                if team_id is not None:
                    if team_id not in team_managers:
                        team_managers[team_id] = await _manager_ids_for_team(
                            db, team_id
                        )
                    manager_ids = team_managers[team_id]
                for manager_id in manager_ids:
                    await svc.send_fcm(
                        manager_id,
                        title="DSR Not Submitted",
                        body=f"{employee_name or 'An employee'} has not submitted their DSR.",
                        type="DSR_LATE_MANAGER",
                        data={"screen": "daily_reports", "employee_id": str(employee_id)},
                        commit=False,
                    )
                    notified += 1
            await db.commit()
            logger.info(
                "late_dsr_check: %d employee(s) late, %d individual notification(s) sent",
                len(late_rows), notified,
            )
    except Exception:  # noqa: BLE001
        logger.exception("late_dsr_check job failed")


async def refresh_gps_config_cache() -> None:
    """00:00 — re-cache all team GPS configs from DB into Redis.

    Each config is cached with a 24h TTL when first accessed via the API, but
    this job ensures the cache stays warm even after the TTL expires — so the
    first employee to START on any given day never hits the DB cold.
    """
    if not await _claim(f"refresh_gps_config_cache:{_today_utc()}"):
        return
    try:
        import json
        from app.models.crm import GpsConfig
        from app.api.v1.gps_config import _config_to_dict, _REDIS_TTL

        async with async_session_factory() as db:
            from sqlalchemy import select
            rows = (await db.execute(select(GpsConfig))).scalars().all()
        r = get_redis()
        cached = 0
        for row in rows:
            key = f"fieldtrack:gps_config:{row.team_id}"
            await r.set(key, json.dumps(_config_to_dict(row)), ex=_REDIS_TTL)
            cached += 1
        if cached:
            logger.info("refresh_gps_config_cache: cached %d team config(s)", cached)
    except Exception:  # noqa: BLE001
        logger.exception("refresh_gps_config_cache job failed")


# ── Wiring ──────────────────────────────────────────────────────────────────
async def absentee_alert_job() -> None:
    """09:30 — alert each manager about their team's executives who still have
    no attendance today (checklist #62/#7). One aggregate notification per team,
    mirroring the late-DSR fan-out. Distinct from the 09:00 self-nudge, which
    goes to the employee; this goes to the manager."""
    if not await _claim(f"absentee_alert:{_today_utc()}"):
        return
    async with async_session_factory() as db:
        repo = NotificationRepository(db)
        absentees = await repo.absent_field_users_today(_today_utc())
        if not absentees:
            return
        by_team: dict[int, list[str]] = defaultdict(list)
        for u in absentees:
            if u.team_id is not None:
                by_team[u.team_id].append(u.name)
        if not by_team:
            return
        svc = NotificationService(db)
        notified = 0
        for team_id, names in by_team.items():
            for sup_id in await _manager_ids_for_team(db, team_id):
                await svc.absentee_alert(sup_id, absent_names=names, commit=False)
                notified += 1
        await db.commit()
        logger.info(
            "ABSENTEE_ALERT: %d team(s), notified %d manager(s)",
            len(by_team), notified,
        )


async def stationary_alert_job() -> None:
    """Every 30 min during field hours — flag on-clock executives whose trailing
    ~90 min of GPS pings all sit within a small radius (checklist #21). Alerts
    the team manager once per employee per day (Redis cooldown), so a genuinely
    parked exec doesn't re-trigger every half hour."""
    now = _business_now()
    if not await _claim(f"stationary_alert:{now:%Y%m%d%H%M}"):
        return
    since = datetime.now(timezone.utc) - timedelta(minutes=_STATIONARY_MIN_MINUTES + 5)
    async with async_session_factory() as db:
        nrepo = NotificationRepository(db)
        lrepo = LocationRepository(db)
        on_clock = await nrepo.on_clock_field_users(_today_utc())
        if not on_clock:
            return
        svc = NotificationService(db)
        r = get_redis()
        alerted = 0
        for emp in on_clock:
            pts = await lrepo.points_since(emp.id, since)
            if len(pts) < 3:
                continue  # too little data to judge movement
            span_min = (pts[-1][2] - pts[0][2]).total_seconds() / 60.0
            if span_min < _STATIONARY_MIN_MINUTES - 5:
                continue  # window doesn't yet cover 90 min
            lat0, lng0, _ = pts[0]
            max_move = max(_haversine_m(lat0, lng0, la, ln) for la, ln, _ in pts)
            if max_move > _STATIONARY_RADIUS_M:
                continue  # they moved — not stationary
            if emp.team_id is None:
                continue
            # Cooldown: one alert per employee per day.
            cooldown_key = f"{Keys.PREFIX}:stationary_alerted:{emp.id}:{_today_utc()}"
            try:
                if not await r.set(cooldown_key, "1", nx=True, ex=7200):
                    continue
            except Exception:  # noqa: BLE001 — Redis down: still alert
                logger.warning("stationary cooldown check failed; alerting anyway")
            for sup_id in await _manager_ids_for_team(db, emp.team_id):
                await svc.stationary_alert(
                    sup_id,
                    employee_id=emp.id,
                    employee_name=emp.name,
                    minutes=int(span_min),
                    commit=False,
                )
                alerted += 1
        if alerted:
            await db.commit()
            logger.info("STATIONARY_ALERT: sent %d alert(s)", alerted)


async def _generate_and_notify_team_reports(
    start: date_type,
    end: date_type,
    label: str,
    *,
    weekly: bool,
    ttl_seconds: int,
) -> None:
    """Shared body for the weekly/monthly auto-report jobs: build one TEAM report
    per active team for [start, end] and notify that team's manager(s) with a
    download link. A failure for one team is logged and skipped."""
    async with async_session_factory() as db:
        rrepo = ReportRepository(db)
        team_ids = await rrepo.active_team_ids()
        if not team_ids:
            return
        svc = NotificationService(db)
        generated = 0
        for team_id in team_ids:
            sup_ids = await _manager_ids_for_team(db, team_id)
            if not sup_ids:
                continue  # no manager to send it to
            team = await rrepo.get_team(team_id)
            scope = f"Team: {team.name if team else team_id}"
            # owner = first manager (download authz); admins can always fetch.
            result = await generate_team_report_file(
                team_id=team_id,
                start=start,
                end=end,
                period_label=label,
                owner_id=sup_ids[0],
                scope_label=scope,
                fmt=ReportFormat.EXCEL,
                ttl_seconds=ttl_seconds,
            )
            if result is None:
                continue
            _, url = result
            for sup_id in sup_ids:
                await svc.report_ready(
                    sup_id, weekly=weekly, period_label=label,
                    download_url=url, commit=False,
                )
            generated += 1
        await db.commit()
        logger.info(
            "%s auto-report: generated %d team report(s)",
            "WEEKLY" if weekly else "MONTHLY", generated,
        )


async def weekly_report_job() -> None:
    """Monday 07:00 — generate each team's report for the prior week (checklist
    #60): Mon–Sun ending yesterday, with visits/orders/conversion per exec."""
    today = _business_now().date()
    if not await _claim(f"weekly_report:{today}"):
        return
    end = today - timedelta(days=1)
    start = end - timedelta(days=6)
    label = f"Week of {start:%d %b} – {end:%d %b %Y}"
    await _generate_and_notify_team_reports(
        start, end, label, weekly=True, ttl_seconds=_WEEKLY_REPORT_TTL
    )


async def monthly_report_job() -> None:
    """1st of month 06:00 — generate each team's report for the previous calendar
    month (checklist #61)."""
    today = _business_now().date()
    if not await _claim(f"monthly_report:{today:%Y%m}"):
        return
    end = today.replace(day=1) - timedelta(days=1)  # last day of previous month
    start = end.replace(day=1)
    label = start.strftime("%B %Y")
    await _generate_and_notify_team_reports(
        start, end, label, weekly=False, ttl_seconds=_MONTHLY_REPORT_TTL
    )


def build_reminder_scheduler() -> AsyncIOScheduler:
    """Construct (but don't start) the reminders scheduler. main.py starts it in
    the lifespan and shuts it down on exit."""
    settings = get_settings()
    scheduler = AsyncIOScheduler(timezone=settings.business_timezone)
    # CronTrigger defaults to the OS-local timezone (UTC in Docker) when no
    # `timezone=` is given — the scheduler's own `timezone=` above only sets
    # ITS default, it is NOT inherited by trigger objects constructed
    # explicitly like `CronTrigger(hour=19, minute=0)`. Every trigger below
    # must be passed `timezone=tz` explicitly, or these all silently run on
    # the container's OS clock instead of business_timezone.
    tz = scheduler.timezone
    scheduler.add_job(
        attendance_reminder_job,
        CronTrigger(hour=9, minute=0, timezone=tz),
        id="attendance_reminder",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        end_work_reminder_job,
        CronTrigger(hour=18, minute=0, timezone=tz),
        id="end_work_reminder",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        missed_visits_reminder_job,
        CronTrigger(hour=18, minute=30, timezone=tz),
        id="missed_visits_reminder",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        redis_cleanup_job,
        CronTrigger(hour=23, minute=0, timezone=tz),
        id="redis_cleanup",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        check_unsubmitted_plans,
        CronTrigger(hour=20, minute=0, timezone=tz),
        id="check_unsubmitted_plans",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        send_24h_followup_reminders,
        CronTrigger(hour=8, minute=0, timezone=tz),
        id="fu_24h_reminders",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        send_24h_followup_reminders_precise,
        CronTrigger(minute="0,30", timezone=tz),
        id="fu_24h_reminders_precise",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=600,
    )
    scheduler.add_job(
        send_1h_followup_reminders,
        CronTrigger(minute="0,30", timezone=tz),
        id="fu_1h_reminders",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=600,
    )
    scheduler.add_job(
        send_visit_reminders,
        CronTrigger(minute="0,30", timezone=tz),
        id="visit_reminders",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=600,
    )
    scheduler.add_job(
        escalate_unacknowledged_followups,
        CronTrigger(minute=15, timezone=tz),
        id="fu_escalation",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=1800,
    )
    scheduler.add_job(
        auto_checkout_job,
        CronTrigger(hour=12, minute=15, timezone=tz),
        id="auto_checkout",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        late_dsr_check_job,
        CronTrigger(hour=19, minute=30, timezone=tz),
        id="late_dsr_check",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        refresh_gps_config_cache,
        CronTrigger(hour=0, minute=0, timezone=tz),
        id="refresh_gps_config_cache",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        absentee_alert_job,
        CronTrigger(hour=9, minute=30, timezone=tz),
        id="absentee_alert",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        stationary_alert_job,
        # Every 30 min across field hours (10:00–17:30 business tz).
        CronTrigger(hour="10-17", minute="0,30", timezone=tz),
        id="stationary_alert",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=600,
    )
    scheduler.add_job(
        weekly_report_job,
        CronTrigger(day_of_week="mon", hour=7, minute=0, timezone=tz),
        id="weekly_report",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        monthly_report_job,
        CronTrigger(day=1, hour=6, minute=0, timezone=tz),
        id="monthly_report",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    return scheduler
