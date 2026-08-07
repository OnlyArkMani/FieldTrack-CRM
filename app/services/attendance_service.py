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
from zoneinfo import ZoneInfo

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
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
    SessionType.RE_CHECKIN: "RE_CHECKED_IN",
}

# Which prior states each action is allowed from.
_ALLOWED_FROM: dict[SessionType, set[str]] = {
    SessionType.START: {"NULL"},
    SessionType.BREAK: {"STARTED", "RESUMED", "RE_CHECKED_IN"},
    SessionType.RESUME: {"ON_BREAK"},
    SessionType.END: {"STARTED", "RESUMED", "RE_CHECKED_IN"},
    SessionType.RE_CHECKIN: {"ENDED"},
}

_INVALID_MESSAGE: dict[SessionType, str] = {
    SessionType.START: "Attendance already started today",
    SessionType.BREAK: "Can only take a break while working",
    SessionType.RESUME: "Can only resume from a break",
    SessionType.END: "Can only end while working or re-checked in",
    SessionType.RE_CHECKIN: "Can only re-check in after ending attendance",
}


def _seconds_to_midnight(now: datetime) -> int:
    """Seconds until the next UTC midnight (>=1 so SET EX never gets 0)."""
    tomorrow = (now + timedelta(days=1)).date()
    midnight = datetime.combine(tomorrow, time.min, tzinfo=timezone.utc)
    return max(1, int((midnight - now).total_seconds()))


# START and RE_CHECKIN close at noon business-tz wall clock — BREAK/RESUME/END
# are never gated by this. Missing the window leaves the day in NULL state;
# the employee can still apply for leave (mark_leave has no time gate).
_CHECKIN_CUTOFF_HOUR = 12


def _checkin_cutoff_passed() -> bool:
    """True once the business-timezone wall clock is at/past the noon
    check-in/re-check-in cutoff. Business-tz (not UTC, not server-local),
    matching how DSR "day" boundaries are defined — see dsr_service.business_today.
    """
    settings = get_settings()
    try:
        tz = ZoneInfo(settings.business_timezone)
    except Exception:
        tz = timezone.utc
    return datetime.now(tz).hour >= _CHECKIN_CUTOFF_HOUR


def calculate_duration(sessions: list[AttendanceSession]) -> int:
    """Worked minutes across a day: sum each START/RESUME/RE_CHECKIN → next BREAK/END
    interval. Order-independent input is sorted defensively."""
    ordered = sorted(sessions, key=lambda s: s.timestamp)
    total = timedelta()
    open_start: datetime | None = None
    for s in ordered:
        if s.type in (SessionType.START, SessionType.RESUME, SessionType.RE_CHECKIN):
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
        """STARTED|ON_BREAK|RESUMED|ENDED|ON_LEAVE|NULL. DB is the source of
        truth. When an attendance row is loaded, compute state from its
        sessions. When no DB row exists, the state is definitively NULL —
        any Redis entry is stale (DB was cleaned up, or the row was never
        committed) and is deleted on the spot so future calls are fast."""
        if attendance is not None:
            return self._state_of(attendance)
        # No DB row for today → state is NULL regardless of what Redis holds.
        key = Keys.attendance_state(user_id)
        cached = await self.redis.hget(key, "state")
        if cached:
            # Stale Redis entry: DB row no longer exists. Remove it so the
            # user isn't stuck and future reads skip the delete round-trip.
            await self.redis.delete(key)
            logger.warning(
                "Cleared stale Redis attendance state '%s' for user %s "
                "(no DB row for today)",
                cached,
                user_id,
            )
        return "NULL"

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
        late_checkout_reason: str | None = None,
        ip: str | None = None,
    ) -> AttendanceOut:
        day = self._today()
        attendance = await self.repo.get_for_user_date(user.id, day)
        state = await self._current_state(user.id, attendance)

        if state == "ON_LEAVE":
            raise conflict("Marked as on leave today — cannot check in")
        if state not in _ALLOWED_FROM[action]:
            raise conflict(_INVALID_MESSAGE[action])
        if action in (SessionType.START, SessionType.RE_CHECKIN) and _checkin_cutoff_passed():
            raise conflict(
                "Check-in closes at 12:00 PM. You can still apply for leave for today."
            )

        if action == SessionType.RE_CHECKIN:
            if not notes or not notes.strip():
                notes = "Re-checked in"

        if action == SessionType.END:
            if not work_summary or not work_summary.strip():
                work_summary = "Day completed."

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
                if late_checkout_reason is not None:
                    attendance.late_checkout_reason = late_checkout_reason
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

    # ── System-triggered auto-checkout (19:00 IST scheduler job) ──────────
    async def auto_checkout(
        self,
        user_id: int,
        day: date_type,
        *,
        lat: float | None,
        lng: float | None,
    ) -> Attendance | None:
        """Force-close whoever's still open (STARTED/RESUMED/ON_BREAK/
        RE_CHECKED_IN) at the 19:00 cutoff. Bypasses transition_state's
        _ALLOWED_FROM gate on purpose: ON_BREAK can't reach END through the
        normal self-service path (it must RESUME first), and there's no user
        behind this call to do that — it mirrors add_manual_session's admin
        override in that sense, just system-triggered instead of an admin
        action. work_summary is set to a distinguishing marker (not "Day
        completed.", the manual-End default) so the employee and any DSR
        viewer can tell this wasn't a manual End. Returns None if the row is
        no longer open by the time this runs (race with a manual End, or
        already ON_LEAVE/NULL) — the caller should treat that as a no-op,
        not an error.
        """
        attendance = await self.repo.get_for_user_date(user_id, day)
        if attendance is None:
            return None
        if self._state_of(attendance) not in (
            "STARTED",
            "RESUMED",
            "ON_BREAK",
            "RE_CHECKED_IN",
        ):
            return None

        now = datetime.now(timezone.utc)
        self.repo.add_session(
            AttendanceSession(
                attendance_id=attendance.id,
                type=SessionType.END,
                timestamp=now,
                lat=lat,
                lng=lng,
                notes="Auto-checkout: 7:00 PM cutoff",
            )
        )
        await self.db.flush()
        await self.db.refresh(attendance, attribute_names=["sessions"])
        attendance.work_summary = "Auto-checked-out at 7:00 PM — no manual entry."
        attendance.total_duration_minutes = calculate_duration(attendance.sessions)
        attendance.total_distance_meters = await self._day_distance(user_id, day)

        await self._write_redis_state(user_id, "ENDED", attendance.id, now)
        self.repo.add_audit_log(
            user_id=user_id,
            action="ATTENDANCE_AUTO_CHECKOUT",
            entity_id=attendance.id,
            metadata={"lat": lat, "lng": lng},
        )
        await self.db.commit()
        return await self.repo.get_for_user_date(user_id, day)

    # ── Reads ─────────────────────────────────────────────────────────────
    async def current_state_today(self, user_id: int) -> str:
        """STARTED|ON_BREAK|RESUMED|ENDED|ON_LEAVE|NULL for today. Used to
        gate field-work actions (checklist A15) for employees —
        managers/admins are exempt."""
        day = self._today()
        attendance = await self.repo.get_for_user_date(user_id, day)
        return await self._current_state(user_id, attendance)

    async def get_today(self, user_id: int) -> TodayAttendanceOut:
        day = self._today()
        attendance = await self.repo.get_for_user_date(user_id, day)
        state = await self._current_state(user_id, attendance)
        if attendance is None:
            return TodayAttendanceOut(
                has_attendance=False, current_state=state, attendance=None
            )
        return TodayAttendanceOut(
            has_attendance=True,
            current_state=state,  # type: ignore[arg-type]
            attendance=self._to_out(attendance, state),
        )

    async def mark_leave(
        self, *, user: User, ip: str | None, leave_date: date_type | None = None
    ) -> AttendanceOut:
        """Self-service: mark today (default) or a future `leave_date` as
        leave. Only valid before any attendance row exists for that day —
        once STARTED/ON_LEAVE/ENDED exists, the UNIQUE(user_id, date) row is
        already claimed. A future date already carrying PLANNED visit-plan
        items is rejected until the employee reschedules or skips them
        (VisitPlanService.carry_over_item / skip_missed_item) — leave can't
        silently strand a planned visit."""
        day = leave_date if leave_date is not None else self._today()
        if day < self._today():
            raise bad_request("Cannot mark leave for a past date")

        from app.repositories.visit_plan_repository import VisitPlanRepository

        pending = await VisitPlanRepository(self.db).planned_farmer_names_for_date(
            user.id, day
        )
        if pending:
            raise conflict(
                f"Reschedule or skip {len(pending)} planned visit(s) for "
                f"{day.isoformat()} before requesting leave: {', '.join(pending)}"
            )

        existing = await self.repo.get_for_user_date(user.id, day)
        if existing is not None:
            raise conflict("Attendance already recorded for that date")

        attendance = Attendance(
            user_id=user.id,
            date=day,
            status=AttendanceStatus.ON_LEAVE,
            total_duration_minutes=0,
            total_distance_meters=0.0,
        )
        self.repo.add_attendance(attendance)
        await self.db.flush()
        self.repo.add_audit_log(
            user_id=user.id,
            action="ATTENDANCE_ON_LEAVE",
            entity_id=attendance.id,
            ip_address=ip,
            metadata={},
        )
        try:
            await self.db.commit()
        except IntegrityError:
            # UNIQUE(user_id, date) lost the race — someone else claimed today.
            await self.db.rollback()
            raise conflict("Attendance already recorded today")

        refreshed = await self.repo.get_for_user_date(user.id, day)
        return self._to_out(refreshed, "ON_LEAVE")

    async def revoke_leave(self, user_id: int, attendance_id: int) -> None:
        attendance = await self.repo.get_by_id(attendance_id)
        if attendance is None or attendance.user_id != user_id:
            raise not_found("Leave record not found")
        if attendance.status != AttendanceStatus.ON_LEAVE:
            raise bad_request("Only leaves can be revoked")
        if attendance.date < self._today():
            raise bad_request("Cannot revoke past leaves")

        await self.db.delete(attendance)
        await self.db.commit()

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
        self, *, manager: User, team_id: int, day: date_type
    ) -> list[AttendanceOut]:
        # Managers are scoped to their own team; admins see any.
        if manager.role == UserRole.MANAGER and manager.team_id != team_id:
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
        if attendance is None:
            return "NULL"
        if attendance.status == AttendanceStatus.ON_LEAVE:
            return "ON_LEAVE"
        if not attendance.sessions:
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
            late_checkout_reason=attendance.late_checkout_reason,
            current_state=state,  # type: ignore[arg-type]
            sessions=[
                SessionOut.model_validate(s)
                for s in sorted(attendance.sessions, key=lambda s: s.timestamp)
            ],
        )
