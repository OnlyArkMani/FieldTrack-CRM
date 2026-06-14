"""Daily housekeeping worker.

Runs once a day (APScheduler, wired in main.lifespan). Four jobs, each guarded
so one failing never aborts the others, and the whole run is wrapped so a bad
night never crashes the API process:

  1. Prune location_logs older than settings.location_retention_days (default
     31 — the hottest, highest-volume table; see models/location.py's volume
     math). 31 days keeps a full month of trails while staying cheap on disk.
  2. Delete DONE sync_queue rows older than 7 days (the server-side dead-letter
     landing zone; once processed they're noise).
  3. Archive attendance older than 1 year into a cold table WITH a JSON snapshot
     of its sessions, then delete the originals. Nothing is lost: the snapshot
     preserves the full timeline the cascade would otherwise drop.
  4. Write one audit_logs row summarizing what was removed.

IDEMPOTENT / RE-RUN SAFE: every step is a bounded DELETE/INSERT keyed on age,
so running twice (e.g. two uvicorn workers each holding a scheduler) just finds
nothing the second time. We still prefer a single scheduler — see main.py.
"""
import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import text

from app.core.config import get_settings
from app.core.database import async_session_factory

logger = logging.getLogger("fieldtrack.cleanup")

# Default; the actual value comes from settings.location_retention_days at run
# time (env-tunable). Kept as a module constant for the fallback/import compat.
LOCATION_RETENTION_DAYS = 31
SYNC_QUEUE_RETENTION_DAYS = 7
ATTENDANCE_ARCHIVE_AFTER_DAYS = 365

_ARCHIVE_DDL = """
CREATE TABLE IF NOT EXISTS attendance_archive (
    id                      BIGINT PRIMARY KEY,
    user_id                 BIGINT,
    date                    DATE NOT NULL,
    status                  VARCHAR(20) NOT NULL,
    total_duration_minutes  INTEGER NOT NULL DEFAULT 0,
    total_distance_meters   DOUBLE PRECISION NOT NULL DEFAULT 0,
    work_summary            TEXT,
    sessions_snapshot       JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at              TIMESTAMPTZ,
    archived_at             TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""


async def run_cleanup() -> dict[str, Any]:
    """Execute all cleanup steps. Returns a summary dict (also audit-logged)."""
    now = datetime.now(timezone.utc)
    summary: dict[str, Any] = {
        "locations_deleted": 0,
        "sync_queue_deleted": 0,
        "attendance_archived": 0,
        "errors": [],
    }

    async with async_session_factory() as db:
        # 1. Prune old location_logs.
        try:
            retention_days = getattr(
                get_settings(), "location_retention_days", LOCATION_RETENTION_DAYS
            )
            cutoff = now - timedelta(days=retention_days)
            res = await db.execute(
                text("DELETE FROM location_logs WHERE created_at < :cutoff"),
                {"cutoff": cutoff},
            )
            summary["locations_deleted"] = res.rowcount or 0
            await db.commit()
        except Exception as e:  # noqa: BLE001
            await db.rollback()
            summary["errors"].append(f"locations: {e}")
            logger.exception("cleanup: location prune failed")

        # 2. Delete old, completed sync_queue rows.
        try:
            cutoff = now - timedelta(days=SYNC_QUEUE_RETENTION_DAYS)
            res = await db.execute(
                text(
                    "DELETE FROM sync_queue "
                    "WHERE status = 'DONE' AND created_at < :cutoff"
                ),
                {"cutoff": cutoff},
            )
            summary["sync_queue_deleted"] = res.rowcount or 0
            await db.commit()
        except Exception as e:  # noqa: BLE001
            await db.rollback()
            summary["errors"].append(f"sync_queue: {e}")
            logger.exception("cleanup: sync_queue prune failed")

        # 3. Archive year-old attendance (snapshot sessions first, then move).
        try:
            cutoff_date = (now - timedelta(days=ATTENDANCE_ARCHIVE_AFTER_DAYS)).date()
            await db.execute(text(_ARCHIVE_DDL))
            # Copy with a JSON snapshot of each row's sessions. ON CONFLICT keeps
            # the archive idempotent if a prior run already moved some rows.
            res = await db.execute(
                text(
                    """
                    INSERT INTO attendance_archive (
                        id, user_id, date, status, total_duration_minutes,
                        total_distance_meters, work_summary, sessions_snapshot,
                        created_at
                    )
                    SELECT a.id, a.user_id, a.date, a.status,
                           a.total_duration_minutes, a.total_distance_meters,
                           a.work_summary,
                           COALESCE((
                               SELECT jsonb_agg(jsonb_build_object(
                                   'id', s.id, 'type', s.type,
                                   'timestamp', s.timestamp,
                                   'lat', s.lat, 'lng', s.lng, 'notes', s.notes
                               ) ORDER BY s.timestamp)
                               FROM attendance_sessions s
                               WHERE s.attendance_id = a.id
                           ), '[]'::jsonb),
                           a.created_at
                    FROM attendance a
                    WHERE a.date < :cutoff
                    ON CONFLICT (id) DO NOTHING
                    """
                ),
                {"cutoff": cutoff_date},
            )
            archived = res.rowcount or 0
            # Delete originals (attendance_sessions cascade — already snapshotted).
            await db.execute(
                text("DELETE FROM attendance WHERE date < :cutoff"),
                {"cutoff": cutoff_date},
            )
            summary["attendance_archived"] = archived
            await db.commit()
        except Exception as e:  # noqa: BLE001
            await db.rollback()
            summary["errors"].append(f"attendance_archive: {e}")
            logger.exception("cleanup: attendance archive failed")

        # 4. Audit the run (best-effort).
        try:
            await db.execute(
                text(
                    """
                    INSERT INTO audit_logs (action, entity_type, metadata, created_at)
                    VALUES ('SYNC_CLEANUP', 'system', CAST(:meta AS jsonb), now())
                    """
                ),
                {"meta": _json(summary)},
            )
            await db.commit()
        except Exception as e:  # noqa: BLE001
            await db.rollback()
            logger.exception("cleanup: audit write failed (%s)", e)

    logger.info("cleanup complete: %s", summary)
    return summary


def _json(value: dict[str, Any]) -> str:
    import json

    return json.dumps(value)
