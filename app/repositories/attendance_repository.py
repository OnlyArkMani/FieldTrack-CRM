"""Attendance DB access. DB-only — no business rules, no commits, no Redis,
no HTTP errors. The state-machine logic lives in attendance_service.
"""
from datetime import date as date_type

from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.attendance import Attendance, AttendanceSession
from app.models.enums import SessionType
from app.models.misc import AuditLog
from app.models.user import User


class AttendanceRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    # ── Reads ─────────────────────────────────────────────────────────────
    async def get_for_user_date(
        self, user_id: int, day: date_type
    ) -> Attendance | None:
        """Today's (or any day's) attendance with its sessions eager-loaded.
        sessions come back ordered by timestamp (relationship order_by)."""
        stmt = (
            select(Attendance)
            .where(and_(Attendance.user_id == user_id, Attendance.date == day))
            .options(selectinload(Attendance.sessions))
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def get_by_id(
        self, attendance_id: int, *, with_sessions: bool = True
    ) -> Attendance | None:
        if not with_sessions:
            return await self.db.get(Attendance, attendance_id)
        stmt = (
            select(Attendance)
            .where(Attendance.id == attendance_id)
            .options(selectinload(Attendance.sessions))
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def history(
        self,
        user_id: int,
        *,
        start: date_type,
        end: date_type,
        cursor_id: int | None,
        limit: int,
    ) -> tuple[list[Attendance], int]:
        """Keyset page over a date range, newest first. Cursor walks DOWN the
        id space (id < cursor) since the order is id DESC."""
        base = and_(
            Attendance.user_id == user_id,
            Attendance.date >= start,
            Attendance.date <= end,
        )
        stmt = (
            select(Attendance)
            .where(base)
            .options(selectinload(Attendance.sessions))
        )
        if cursor_id is not None:
            stmt = stmt.where(Attendance.id < cursor_id)
        stmt = stmt.order_by(Attendance.id.desc()).limit(limit + 1)
        rows = list((await self.db.execute(stmt)).scalars().all())

        total = (
            await self.db.execute(select(func.count(Attendance.id)).where(base))
        ).scalar_one()
        return rows, int(total)

    async def team_for_date(
        self, team_id: int, day: date_type
    ) -> list[tuple[User, Attendance | None]]:
        """Every member of a team paired with their attendance for `day`
        (None if they have none yet). Left-join keeps absentees in the list —
        a supervisor needs to see who HASN'T checked in too."""
        stmt = (
            select(User, Attendance)
            .outerjoin(
                Attendance,
                and_(
                    Attendance.user_id == User.id,
                    Attendance.date == day,
                ),
            )
            .where(User.team_id == team_id)
            .order_by(User.name.asc())
            .options(selectinload(Attendance.sessions))
        )
        result = await self.db.execute(stmt)
        return [(row[0], row[1]) for row in result.all()]

    async def all_for_date(
        self, day: date_type, *, cursor_id: int | None, limit: int
    ) -> tuple[list[tuple[Attendance, User]], int]:
        """Admin: all attendance rows for a date paired with the employee,
        keyset paged by id ASC. Attendance has no User relationship, so we
        join explicitly and hand back (attendance, user) tuples."""
        base = Attendance.date == day
        stmt = (
            select(Attendance, User)
            .join(User, User.id == Attendance.user_id)
            .where(base)
            .options(selectinload(Attendance.sessions))
        )
        if cursor_id is not None:
            stmt = stmt.where(Attendance.id > cursor_id)
        stmt = stmt.order_by(Attendance.id.asc()).limit(limit + 1)
        result = await self.db.execute(stmt)
        rows = [(row[0], row[1]) for row in result.all()]

        total = (
            await self.db.execute(select(func.count(Attendance.id)).where(base))
        ).scalar_one()
        return rows, int(total)

    async def last_session_type(self, attendance_id: int) -> SessionType | None:
        stmt = (
            select(AttendanceSession.type)
            .where(AttendanceSession.attendance_id == attendance_id)
            .order_by(AttendanceSession.timestamp.desc(), AttendanceSession.id.desc())
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def user_ref(self, user_id: int) -> User | None:
        return await self.db.get(User, user_id)

    # ── Writes (no commit) ───────────────────────────────────────────────
    def add_attendance(self, attendance: Attendance) -> None:
        self.db.add(attendance)

    def add_session(self, session: AttendanceSession) -> None:
        self.db.add(session)

    def add_audit_log(
        self,
        *,
        user_id: int | None,
        action: str,
        entity_id: int | None = None,
        ip_address: str | None = None,
        metadata: dict | None = None,
    ) -> None:
        self.db.add(
            AuditLog(
                user_id=user_id,
                action=action,
                entity_type="attendance",
                entity_id=entity_id,
                metadata_=metadata,
                ip_address=ip_address,
            )
        )
