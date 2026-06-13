"""Sync business logic — replaying offline attendance sessions.

CONTRACT: every submitted record lands in exactly one bucket —
  processed  inserted now
  skipped    a near-identical session already exists (idempotent replay)
  errors     couldn't be applied (bad attendance ref, etc.) — the device keeps
             it and surfaces it, rather than silently dropping it.
Nothing is ever silently lost: that's the whole point of the sync layer.

DUPLICATE RULE: same (attendance_id, type) with timestamps within 30s. Offline
queues replay the exact bytes, so timestamps match to the millisecond; the 30s
window also absorbs a double-tap the user made by accident on a laggy device.

Each record's attendance is resolved as:
  - explicit attendance_id  → must exist AND belong to the caller
  - null attendance_id      → find-or-create the caller's attendance for the
                              record's (UTC) date, so a fully-offline START
                              still has a home. status defaults to PRESENT.
Durations are recomputed for every touched attendance from its full session
set (reusing the attendance state-machine's calculator).
"""
import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.attendance import Attendance, AttendanceSession
from app.models.enums import AttendanceStatus, SessionType
from app.models.user import User
from app.repositories.attendance_repository import AttendanceRepository
from app.schemas.sync import (
    AttendanceSessionSyncIn,
    AttendanceSessionSyncResult,
    ServerStatusOut,
    SessionSyncRecord,
    SyncError,
)
from app.services.attendance_service import calculate_duration

logger = logging.getLogger("fieldtrack.sync")

DUPLICATE_WINDOW = timedelta(seconds=30)


class SyncService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = AttendanceRepository(db)

    async def server_status(self) -> ServerStatusOut:
        return ServerStatusOut(server_time=datetime.now(timezone.utc))

    # ── Attendance-session replay ────────────────────────────────────────
    async def sync_attendance_sessions(
        self, user: User, batch: AttendanceSessionSyncIn
    ) -> AttendanceSessionSyncResult:
        processed = skipped = 0
        errors: list[SyncError] = []

        # Cache resolved attendances + a (type, ts) seen-list per attendance so
        # dedup sees both the DB's existing sessions AND ones added earlier in
        # THIS batch (without a DB round-trip per record).
        attendances: dict[int, Attendance] = {}
        seen: dict[int, list[tuple[SessionType, datetime]]] = {}
        touched: set[int] = set()

        for i, rec in enumerate(batch.sessions):
            try:
                attendance = await self._resolve_attendance(user, rec, attendances)
            except _ResolveError as e:
                errors.append(SyncError(index=i, reason=e.reason))
                continue

            if attendance.id not in seen:
                seen[attendance.id] = [
                    (s.type, _aware(s.timestamp)) for s in attendance.sessions
                ]

            ts = _aware(rec.timestamp)
            if self._is_duplicate(seen[attendance.id], rec.type, ts):
                skipped += 1
                continue

            self.repo.add_session(
                AttendanceSession(
                    attendance_id=attendance.id,
                    type=rec.type,
                    timestamp=ts,
                    lat=rec.lat,
                    lng=rec.lng,
                    notes=rec.notes,
                )
            )
            seen[attendance.id].append((rec.type, ts))
            touched.add(attendance.id)
            processed += 1

        if processed:
            await self.db.flush()
            # Recompute the denormalized duration for every touched day.
            for aid in touched:
                att = await self.repo.get_by_id(aid)
                if att is not None:
                    att.total_duration_minutes = calculate_duration(att.sessions)
            self.repo.add_audit_log(
                user_id=user.id,
                action="SYNC_ATTENDANCE_SESSIONS",
                metadata={"processed": processed, "skipped": skipped,
                          "errors": len(errors)},
            )
            await self.db.commit()

        return AttendanceSessionSyncResult(
            processed=processed, skipped=skipped, errors=errors
        )

    # ── Helpers ──────────────────────────────────────────────────────────
    async def _resolve_attendance(
        self,
        user: User,
        rec: SessionSyncRecord,
        cache: dict[int, Attendance],
    ) -> Attendance:
        if rec.attendance_id is not None:
            if rec.attendance_id in cache:
                return cache[rec.attendance_id]
            att = await self.repo.get_by_id(rec.attendance_id)
            if att is None:
                raise _ResolveError("unknown attendance_id")
            if att.user_id != user.id:
                raise _ResolveError("attendance does not belong to you")
            cache[att.id] = att
            return att

        # No id: find-or-create the caller's attendance for the record's day.
        day = _aware(rec.timestamp).date()
        att = await self.repo.get_for_user_date(user.id, day)
        if att is None:
            att = Attendance(
                user_id=user.id,
                date=day,
                status=AttendanceStatus.PRESENT,
                total_duration_minutes=0,
                total_distance_meters=0.0,
            )
            self.repo.add_attendance(att)
            await self.db.flush()  # need att.id
            await self.db.refresh(att, attribute_names=["sessions"])
        cache[att.id] = att
        return att

    @staticmethod
    def _is_duplicate(
        seen: list[tuple[SessionType, datetime]],
        type_: SessionType,
        ts: datetime,
    ) -> bool:
        for existing_type, existing_ts in seen:
            if existing_type == type_ and abs(existing_ts - ts) <= DUPLICATE_WINDOW:
                return True
        return False


def _aware(ts: datetime) -> datetime:
    """Treat naive timestamps as UTC (device sends UTC ISO8601)."""
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


class _ResolveError(Exception):
    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(reason)
