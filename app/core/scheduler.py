"""Daily notification & maintenance jobs (in-process APScheduler).

WHY HERE (not Celery): single VPS, a handful of cron jobs — see ARCHITECTURE.md.
The existing housekeeping scheduler lives in main.py's lifespan; this module
owns the *human-facing* daily jobs and is wired in alongside it.

SCHEDULE (business-local wall clock — settings.business_timezone, default
Asia/Kolkata):
  09:00  ATTENDANCE_REMINDER  -> active field users with no attendance today
  18:00  END_WORK_REMINDER    -> active field users started-but-not-ended today
  23:00  redis cleanup        -> defensive TTL sweep of live keys

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
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

from app.core.config import get_settings
from app.core.database import async_session_factory
from app.core.redis import Keys, get_redis
from app.repositories.follow_up_repository import FollowUpRepository
from app.repositories.notification_repository import NotificationRepository
from app.repositories.visit_plan_repository import VisitPlanRepository
from app.services.dsr_service import mark_late_reports
from app.services.notification_service import NotificationService

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
    employee to plan, and alert their team's supervisor that it's outstanding.

    Idempotent-ish: a duplicate run would create a second notification row, so
    the cross-worker claim lock guards it (keyed by tomorrow's date)."""
    tomorrow = _business_tomorrow()
    if not await _claim(f"unsubmitted_plans:{tomorrow}"):
        return
    async with async_session_factory() as db:
        repo = VisitPlanRepository(db)
        employees = await repo.all_active_employees_with_supervisor()
        submitted = await repo.submitted_employee_ids(tomorrow)
        service = NotificationService(db)

        notified = 0
        for emp_id, emp_name, _team_name, supervisor_id in employees:
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
            # Alert the supervisor (never the employee themselves).
            if supervisor_id and supervisor_id != emp_id:
                await service.send_fcm(
                    supervisor_id,
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


def _fu_data(farmer_id: int | None) -> dict[str, str]:
    """Deep-link payload: a follow-up reminder opens the farmer's detail."""
    data = {"screen": "farmer"}
    if farmer_id is not None:
        data["farmer_id"] = str(farmer_id)
    return data


async def send_24h_followup_reminders() -> None:
    """08:00 — remind employees of follow-ups scheduled for tomorrow."""
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
            when = fu.scheduled_time.strftime("%H:%M") if fu.scheduled_time else "the day"
            await service.send_fcm(
                fu.employee_id,
                title="Follow-up tomorrow",
                body=f"Visit {farmer_name or 'a farmer'} tomorrow at {when}.",
                type="FOLLOW_UP_REMINDER",
                data=_fu_data(fu.farmer_id),
                commit=False,
            )
            fu.reminder_sent_24h = True
            db.add(fu)
        await db.commit()
        logger.info("FOLLOW_UP 24h reminders sent: %d", len(rows))


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


async def escalate_unacknowledged_followups() -> None:
    """Hourly — escalate to the supervisor any of today's follow-ups still
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
        for fu, farmer_name, employee_name, supervisor_id in rows:
            if supervisor_id and supervisor_id != fu.employee_id:
                await service.send_fcm(
                    supervisor_id,
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


async def late_dsr_check_job() -> None:
    """19:30 — mark DRAFT DSRs as is_late; notify each team supervisor of the
    count of employees who haven't submitted yet.

    Business rule: DSRs that are still DRAFT after 19:30 in the business
    timezone are marked late. The supervisor gets one aggregate FCM per team.
    """
    today = _today_utc()
    if not await _claim(f"late_dsr_check:{today}"):
        return
    try:
        late_count = await mark_late_reports(today)
        if late_count == 0:
            return
        # Notify supervisors. We do a simple broadcast to all active supervisors
        # and let the message convey the count. A per-team count would require
        # joining users → teams → supervisors; the aggregate count is sufficient.
        async with async_session_factory() as db:
            from app.models.enums import UserRole
            from app.models.user import User
            from sqlalchemy import select

            sup_q = await db.execute(
                select(User.id).where(
                    User.role == UserRole.SUPERVISOR,
                    User.is_active.is_(True),
                )
            )
            sup_ids = list(sup_q.scalars().all())
            if not sup_ids:
                return
            svc = NotificationService(db)
            for sup_id in sup_ids:
                await svc.send_fcm(
                    sup_id,
                    title="DSR Reminder",
                    body=f"{late_count} employee(s) have not submitted their DSR.",
                    type="DSR_LATE_SUPERVISOR",
                    data={"screen": "daily_reports"},
                    commit=False,
                )
            await db.commit()
            logger.info(
                "late_dsr_check: notified %d supervisor(s) about %d late DSR(s)",
                len(sup_ids), late_count,
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
def build_reminder_scheduler() -> AsyncIOScheduler:
    """Construct (but don't start) the reminders scheduler. main.py starts it in
    the lifespan and shuts it down on exit."""
    settings = get_settings()
    scheduler = AsyncIOScheduler(timezone=settings.business_timezone)
    scheduler.add_job(
        attendance_reminder_job,
        CronTrigger(hour=9, minute=0),
        id="attendance_reminder",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        end_work_reminder_job,
        CronTrigger(hour=18, minute=0),
        id="end_work_reminder",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        redis_cleanup_job,
        CronTrigger(hour=23, minute=0),
        id="redis_cleanup",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        check_unsubmitted_plans,
        CronTrigger(hour=20, minute=0),
        id="check_unsubmitted_plans",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        send_24h_followup_reminders,
        CronTrigger(hour=8, minute=0),
        id="fu_24h_reminders",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        send_1h_followup_reminders,
        CronTrigger(minute="0,30"),
        id="fu_1h_reminders",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=600,
    )
    scheduler.add_job(
        escalate_unacknowledged_followups,
        CronTrigger(minute=15),
        id="fu_escalation",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=1800,
    )
    scheduler.add_job(
        late_dsr_check_job,
        CronTrigger(hour=19, minute=30),
        id="late_dsr_check",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    scheduler.add_job(
        refresh_gps_config_cache,
        CronTrigger(hour=0, minute=0),
        id="refresh_gps_config_cache",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,
    )
    return scheduler
