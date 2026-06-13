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
from datetime import datetime, timezone

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

from app.core.config import get_settings
from app.core.database import async_session_factory
from app.core.redis import Keys, get_redis
from app.repositories.notification_repository import NotificationRepository
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
    return scheduler
