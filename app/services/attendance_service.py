"""Attendance state-machine service. Owns transactions, validation, the Redis
state cache, and duration math. Routers stay thin.

STATE MACHINE
    NULL → START → (BREAK ⇄ RESUME)* → END
  Each tap appends an immutable AttendanceSession row; the "current state" is
  the last session's type, mapped:
    START|RESUME → working   (STARTED / RESUMED)
    BREAK        → ON_BREAK
    END          → ENDED
  Postgres is the source of truth (sessions are the event log). Redis caches
  the current state so the hot validation path doesn't hit the DB on every
  tap; on a cache miss we rebuild it from the last session.

TRANSITION RULES (invalid ⇒ 409 with a specific message):
    START   only from NULL  (one attendance per user per day; the
            UNIQUE(user_id, date) index is the race backstop)
    BREAK   only from STARTED or RESUMED
    RESUME  only from ON_BREAK
    END     only from STARTED or RESUMED; work_summary (10–500) required

DURATION (calculate_duration): worked minutes = Σ intervals from a
  START/RESUME to the next BREAK/END. Break gaps are excluded by construction.

REDIS state key: fieldtrack:attendance:state:{user_id}
  HASH {state, attendance_id, since}; TTL = seconds to next UTC midnight
  (self-cleaning — a forgotten END never leaks into tomorrow).
"""
import logging
from datetime import datetime, time, timedelta, timezone
from datetime import date as date_type

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import bad_request, conflict, forbidden, not_found
from app.core.redis import Keys, get_redis
from app.models.attendance import Attendance, AttendanceSession
from app.models.enums import AttendanceStatus, SessionType, UserRole
from app.models.user import User
from app.repositories.attendance_repository import AttendanceRepository
from app.schemas.attendance import (
    AttendanceEmployeeRef,
    AttendanceOut,
    SessionOut,
    TodayAttendanceOut,
)

logger = logging.getLogger("fieldtrack.attendance")

# Session type → machine state label stored in Redis / returned as current_state
_STATE_FOR_TYPE: dict[SessionType, str] = {
    SessionType.START: "STARTED",
    SessionType.RESUME: "RESUMED",
    SessionType.BREAK: "ON_BREAK",
    SessionType.END: "ENDED",
}

# Which prior states each action is allowed from.
_ALLOWED_FROM: dict[SessionType, set[str]] = {
    SessionType.START: {"NULL"},
    SessionType.BREAK: {"STARTED", "RESUMED"},
    SessionType.RESUME: {"ON_BREAK"},
    SessionType.END: {"STARTED", "RESUMED"},
}

_INVALID_MESSAGE: dict[SessionType, str] = {
    SessionType.START: "Attendance already started today",
    SessionType.BREAK: "Can only take a break while working",
    SessionType.RESUME: "Can only resume from a break",
    SessionType.END: "Can only end while working",
}


def _seconds_to_midnight(now: datetime) -> int:
    """Seconds until the next UTC midnight (>=1 so SET EX never gets 0)."""
    tomorrow = (now + timedelta(days=1)).date()
    midnight = datetime.combine(tomorrow, time.min, tzinfo=timezone.utc)
    return max(1, int((midnight - now).total_seconds()))


def calculate_duration(sessions: list[AttendanceSession]) -> int:
    """Worked minutes across a day: sum each START/RESUME → next BREAK/END
    interval. Order-independent input is sorted defensively."""
    ordered = sorted(sessions, key=lambda s: s.timestamp)
    total = timedelta()
    open_start: datetime | None = None
    for s in ordered:
        if s.type in (SessionType.START, SessionType.RESUME):
            open_start = s.timestamp
        elif s.type in (SessionType.BREAK, SessionType.END):
            if open_start is not None:
                total += s.timestamp - open_start
                open_start = None
    return max(0, int(total.total_seconds() // 60))


class AttendanceService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = AttendanceRepository(db)
        self.redis = get_redis()

    # ── Current-state resolution (Redis fast-path, DB fallback) ──────────
    @staticmethod
    def _today() -> date_type:
        return datetime.now(timezone.utc).date()

    async def _day_distance(self, user_id: int, day: date_type) -> float:
        """Real-world distance covered today (metres), from location_logs via
        PostGIS — see LocationRepository.day_distance_meters. Best-effort: a
        GPS query failure must never block clocking out."""
        from app.repositories.location_repository import LocationRepository

        day_start = datetime.combine(day, time.min, tzinfo=timezone.utc)
        day_end = datetime.combine(day, time.max, tzinfo=timezone.utc)
        try:
            meters = await LocationRepository(self.db).day_distance_meters(
                user_id, day_start, day_end
            )
            return round(meters, 1)
        except Exception:  # noqa: BLE001
            logger.exception("distance calc failed for user %s on %s", user_id, day)
            return 0.0

    async def _current_state(
        self, user_id: int, attendance: Attendance | None
    ) -> str:
        """STARTED|ON_BREAK|RESUMED|ENDED|NULL. Trusts the DB (last session)
        when an attendance row is in hand; Redis is only the no-DB-row fast
        path used before we've loaded today's row."""
        if attendance is not None:
            if not attendance.sessions:
                return "NULL"
            last = max(attendance.sessions, key=lambda s: s.timestamp)
            return _STATE_FOR_TYPE.get(last.type, "NULL")
        # No row loaded: peek Redis, else NULL (no attendance today).
        cached = await self.redis.hget(Keys.attendance_state(user_id), "state")
        return cached or "NULL"

    async def _write_redis_state(
        self, user_id: int, state: str, attendance_id: int, since: datetime
    ) -> None:
        key = Keys.attendance_state(user_id)
        await self.redis.hset(
            key,
            mapping={
                "state": state,
                "attendance_id": str(attendance_id),
                "since": since.isoformat(),
            },
        )
        await self.redis.expire(key, _seconds_to_midnight(datetime.now(timezone.utc)))

    # ── Transition ───────────────────────────────────────────────────────
    async def transition_state(
        self,
        *,
        user: User,
        action: SessionType,
        lat: float,
        lng: float,
        notes: str | None = None,
        work_summary: str | None = None,
        ip: str | None = None,
    ) -> AttendanceOut:
        day = self._today()
        attendance = await self.repo.get_for_user_date(user.id, day)
        state = await self._current_state(user.id, attendance)

        if state not in _ALLOWED_FROM[action]:
            raise conflict(_INVALID_MESSAGE[action])

        # END requires a work summary (the schema enforces 10–500 at the edge;
        # this is the defensive backstop for any non-HTTP caller).
        if action == SessionType.END and (
            not work_summary or not (10 <= len(work_summary) <= 500)
        ):
            raise bad_request("Work summary must be 10–500 characters")

        now = datetime.now(timezone.utc)

        if action == SessionType.START:
            attendance = await self._do_start(user.id, day, now, lat, lng, notes)
        else:
            # Defensive: states other than START require an existing row.
            if attendance is None:
                raise conflict("No attendance to update today")
            await self._append_session(attendance, action, now, lat, lng, notes)
            if action == SessionType.END:
                attendance.work_summary = work_summary
                attendance.total_duration_minutes = calculate_duration(
                    attendance.sessions
                )
                attendance.total_distance_meters = await self._day_distance(
                    user.id, day
                )

        new_state = _STATE_FOR_TYPE[action]
        await self._write_redis_state(user.id, new_state, attendance.id, now)

        self.repo.add_audit_log(
            user_id=user.id,
            action=f"ATTENDANCE_{action.value}",
            entity_id=attendance.id,
            ip_address=ip,
            metadata={"lat": lat, "lng": lng},
        )

        try:
            await self.db.commit()
        except IntegrityError:
            # UNIQUE(user_id, date) lost a START race — someone started first.
            await self.db.rollback()
            raise conflict("Attendance already started today")

        refreshed = await self.repo.get_for_user_date(user.id, day)
        return self._to_out(refreshed, new_state)

    async def _do_start(
        self,
        user_id: int,
        day: date_type,
        now: datetime,
        lat: float,
        lng: float,
        notes: str | None,
    ) -> Attendance:
        attendance = Attendance(
            user_id=user_id,
            date=day,
            status=AttendanceStatus.PRESENT,
            total_duration_minutes=0,
            total_distance_meters=0.0,
        )
        self.repo.add_attendance(attendance)
        await self.db.flush()  # need attendance.id for the session FK
        self.repo.add_session(
            AttendanceSession(
                attendance_id=attendance.id,
                type=SessionType.START,
                timestamp=now,
                lat=lat,
                lng=lng,
                notes=notes,
            )
        )
        await self.db.flush()
        await self.db.refresh(attendance, attribute_names=["sessions"])
        return attendance

    async def _append_session(
        self,
        attendance: Attendance,
        action: SessionType,
        now: datetime,
        lat: float,
        lng: float,
        notes: str | None,
    ) -> None:
        self.repo.add_session(
            AttendanceSession(
                attendance_id=attendance.id,
                type=action,
                timestamp=now,
                lat=lat,
                lng=lng,
                notes=notes,
            )
        )
        await self.db.flush()
        await self.db.refresh(attendance, attribute_names=["sessions"])

    # ── Reads ─────────────────────────────────────────────────────────────
    async def get_today(self, user_id: int) -> TodayAttendanceOut:
        day = self._today()
        attendance = await self.repo.get_for_user_date(user_id, day)
        state = await self._current_state(user_id, attendance)
        if attendance is None:
            return TodayAttendanceOut(
                has_attendance=False, current_state="NULL", attendance=None
            )
        return TodayAttendanceOut(
            has_attendance=True,
            current_state=state,  # type: ignore[arg-type]
            attendance=self._to_out(attendance, state),
        )

    async def get_history(
        self,
        user_id: int,
        *,
        start: date_type,
        end: date_type,
        cursor_id: int | None,
        limit: int,
    ) -> tuple[list[AttendanceOut], int]:
        if start > end:
            raise bad_request("start_date must be on or before end_date")
        rows, total = await self.repo.history(
            user_id, start=start, end=end, cursor_id=cursor_id, limit=limit
        )
        return [self._to_out(a, self._state_of(a)) for a in rows], total

    async def get_team_for_date(
        self, *, supervisor: User, team_id: int, day: date_type
    ) -> list[AttendanceOut]:
        # Supervisors are scoped to their own team; admins see any.
        if supervisor.role == UserRole.SUPERVISOR and supervisor.team_id != team_id:
            raise forbidden("You can only view your own team's attendance")

        pairs = await self.repo.team_for_date(team_id, day)
        out: list[AttendanceOut] = []
        for member, attendance in pairs:
            if attendance is None:
                # Synthesize a NULL-state placeholder so absentees are visible.
                out.append(
                    AttendanceOut(
                        id=0,
                        user_id=member.id,
                        date=day,
                        status=AttendanceStatus.ABSENT,
                        total_duration_minutes=0,
                        total_distance_meters=0.0,
                        work_summary=None,
                        current_state="NULL",
                        sessions=[],
                        employee=AttendanceEmployeeRef.model_validate(member),
                    )
                )
            else:
                ao = self._to_out(attendance, self._state_of(attendance))
                ao.employee = AttendanceEmployeeRef.model_validate(member)
                out.append(ao)
        return out

    async def get_all_for_date(
        self, *, day: date_type, cursor_id: int | None, limit: int
    ) -> tuple[list[AttendanceOut], int]:
        rows, total = await self.repo.all_for_date(
            day, cursor_id=cursor_id, limit=limit
        )
        out: list[AttendanceOut] = []
        for attendance, member in rows:
            ao = self._to_out(attendance, self._state_of(attendance))
            ao.employee = AttendanceEmployeeRef.model_validate(member)
            out.append(ao)
        return out, total

    # ── Admin overrides ──────────────────────────────────────────────────
    async def override_status(
        self,
        attendance_id: int,
        *,
        status: AttendanceStatus,
        reason: str | None,
        actor: User,
        ip: str | None,
    ) -> AttendanceOut:
        attendance = await self.repo.get_by_id(attendance_id)
        if attendance is None:
            raise not_found("Attendance not found")
        previous = attendance.status
        attendance.status = status
        self.repo.add_audit_log(
            user_id=actor.id,
            action="ATTENDANCE_STATUS_OVERRIDE",
            entity_id=attendance.id,
            ip_address=ip,
            metadata={
                "from": previous.value,
                "to": status.value,
                "reason": reason,
                "target_user_id": attendance.user_id,
            },
        )
        await self.db.commit()
        refreshed = await self.repo.get_by_id(attendance_id)
        return self._to_out(refreshed, self._state_of(refreshed))

    async def add_manual_session(
        self,
        attendance_id: int,
        *,
        action: SessionType,
        timestamp: datetime,
        lat: float | None,
        lng: float | None,
        reason: str,
        actor: User,
        ip: str | None,
    ) -> AttendanceOut:
        attendance = await self.repo.get_by_id(attendance_id)
        if attendance is None:
            raise not_found("Attendance not found")

        self.repo.add_session(
            AttendanceSession(
                attendance_id=attendance.id,
                type=action,
                timestamp=timestamp,
                lat=lat,
                lng=lng,
                notes=f"[manual:{actor.id}] {reason}",
            )
        )
        await self.db.flush()
        await self.db.refresh(attendance, attribute_names=["sessions"])
        # Recompute the rollup so a corrected log yields a corrected total.
        attendance.total_duration_minutes = calculate_duration(attendance.sessions)

        new_state = self._state_of(attendance)
        # Keep Redis consistent with the corrected timeline for the rest of day.
        await self._write_redis_state(
            attendance.user_id, new_state, attendance.id, timestamp
        )
        self.repo.add_audit_log(
            user_id=actor.id,
            action="ATTENDANCE_MANUAL_SESSION",
            entity_id=attendance.id,
            ip_address=ip,
            metadata={
                "type": action.value,
                "reason": reason,
                "target_user_id": attendance.user_id,
            },
        )
        await self.db.commit()
        refreshed = await self.repo.get_by_id(attendance_id)
        return self._to_out(refreshed, self._state_of(refreshed))

    # ── Mapping helpers ──────────────────────────────────────────────────
    @staticmethod
    def _state_of(attendance: Attendance | None) -> str:
        if attendance is None or not attendance.sessions:
            return "NULL"
        last = max(attendance.sessions, key=lambda s: s.timestamp)
        return _STATE_FOR_TYPE.get(last.type, "NULL")

    def _to_out(self, attendance: Attendance, state: str) -> AttendanceOut:
        return AttendanceOut(
            id=attendance.id,
            user_id=attendance.user_id,
            date=attendance.date,
            status=attendance.status,
            total_duration_minutes=attendance.total_duration_minutes,
            total_distance_meters=attendance.total_distance_meters,
            work_summary=attendance.work_summary,
            current_state=state,  # type: ignore[arg-type]
            sessions=[
                SessionOut.model_validate(s)
                for s in sorted(attendance.sessions, key=lambda s: s.timestamp)
            ],
        )
