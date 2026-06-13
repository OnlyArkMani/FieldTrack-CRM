"""Notification + device-token DB access. Repositories do DB access ONLY —
no business rules, no commits (services own transactions), no HTTP, no Redis.
"""
from datetime import date, datetime

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.attendance import Attendance, AttendanceSession
from app.models.enums import SessionType, UserRole
from app.models.misc import DeviceInfo, Notification
from app.models.user import User


class NotificationRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    # ── Notification rows ────────────────────────────────────────────────
    def add(self, notification: Notification) -> Notification:
        self.db.add(notification)
        return notification

    async def list_for_user(
        self, user_id: int, *, cursor_id: int | None, limit: int
    ) -> tuple[list[Notification], int]:
        """Newest-first page. Keyset on id DESC (id is monotonic with
        created_at), fetching limit+1 to derive has_more in the service."""
        stmt = select(Notification).where(Notification.user_id == user_id)
        if cursor_id is not None:
            stmt = stmt.where(Notification.id < cursor_id)
        stmt = stmt.order_by(Notification.id.desc()).limit(limit + 1)
        rows = (await self.db.execute(stmt)).scalars().all()

        total = (
            await self.db.execute(
                select(func.count(Notification.id)).where(
                    Notification.user_id == user_id
                )
            )
        ).scalar_one()
        return list(rows), int(total)

    async def unread_count(self, user_id: int) -> int:
        stmt = select(func.count(Notification.id)).where(
            Notification.user_id == user_id, Notification.is_read.is_(False)
        )
        return int((await self.db.execute(stmt)).scalar_one())

    async def mark_read(self, user_id: int, notification_id: int) -> int:
        """Flip one row to read IFF it belongs to this user and is unread.
        Returns rows affected (0 = not theirs / already read)."""
        stmt = (
            update(Notification)
            .where(
                Notification.id == notification_id,
                Notification.user_id == user_id,
                Notification.is_read.is_(False),
            )
            .values(is_read=True)
        )
        result = await self.db.execute(stmt)
        return int(result.rowcount or 0)

    async def mark_all_read(self, user_id: int) -> int:
        stmt = (
            update(Notification)
            .where(
                Notification.user_id == user_id,
                Notification.is_read.is_(False),
            )
            .values(is_read=True)
        )
        result = await self.db.execute(stmt)
        return int(result.rowcount or 0)

    # ── Device tokens (FCM target resolution) ────────────────────────────
    async def tokens_for_user(self, user_id: int) -> list[str]:
        stmt = select(DeviceInfo.fcm_token).where(
            DeviceInfo.user_id == user_id, DeviceInfo.fcm_token.is_not(None)
        )
        return [t for t in (await self.db.execute(stmt)).scalars().all() if t]

    async def tokens_for_users(self, user_ids: list[int]) -> list[str]:
        if not user_ids:
            return []
        stmt = select(DeviceInfo.fcm_token).where(
            DeviceInfo.user_id.in_(user_ids), DeviceInfo.fcm_token.is_not(None)
        )
        return [t for t in (await self.db.execute(stmt)).scalars().all() if t]

    async def mark_token_stale(self, token: str) -> None:
        """A push said this token is gone (UNREGISTERED / invalid). Null it so
        we stop targeting it; the device re-registers a fresh one on next open.
        NULL (not delete) keeps the device_info row's identity/last_seen."""
        await self.db.execute(
            update(DeviceInfo)
            .where(DeviceInfo.fcm_token == token)
            .values(fcm_token=None)
        )

    async def get_device_by_token(self, token: str) -> DeviceInfo | None:
        stmt = select(DeviceInfo).where(DeviceInfo.fcm_token == token)
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def get_device_for_user(self, user_id: int) -> DeviceInfo | None:
        """One representative device per user (latest seen). FieldTrack is a
        one-device-per-user product (see refresh-token single-session note);
        the newest row wins on the rare double-login."""
        stmt = (
            select(DeviceInfo)
            .where(DeviceInfo.user_id == user_id)
            .order_by(DeviceInfo.last_seen.desc().nullslast(), DeviceInfo.id.desc())
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    def add_device(self, device: DeviceInfo) -> DeviceInfo:
        self.db.add(device)
        return device

    # ── Reminder population queries (scheduler) ──────────────────────────
    async def users_without_attendance_today(self, day: date) -> list[User]:
        """Active field users (non-admin) with NO attendance row for `day`.
        These get the 9AM ATTENDANCE_REMINDER. Admins are web-only and never
        carry a device, so they're excluded."""
        has_today = (
            select(Attendance.user_id)
            .where(Attendance.date == day)
            .scalar_subquery()
        )
        stmt = (
            select(User)
            .where(
                User.is_active.is_(True),
                User.role != UserRole.ADMIN,
                User.id.not_in(has_today),
            )
            .order_by(User.id.asc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def users_started_not_ended_today(self, day: date) -> list[User]:
        """Active field users whose attendance for `day` has a START/RESUME but
        no END session — i.e. still 'on the clock' at 6PM. These get the
        END_WORK_REMINDER. One row/user/day (uq_attendance_user_date), so a
        correlated EXISTS on session type is enough."""
        started = (
            select(Attendance.user_id)
            .join(AttendanceSession, AttendanceSession.attendance_id == Attendance.id)
            .where(
                Attendance.date == day,
                AttendanceSession.type.in_([SessionType.START, SessionType.RESUME]),
            )
            .scalar_subquery()
        )
        ended = (
            select(Attendance.user_id)
            .join(AttendanceSession, AttendanceSession.attendance_id == Attendance.id)
            .where(
                Attendance.date == day,
                AttendanceSession.type == SessionType.END,
            )
            .scalar_subquery()
        )
        stmt = (
            select(User)
            .where(
                User.is_active.is_(True),
                User.role != UserRole.ADMIN,
                User.id.in_(started),
                User.id.not_in(ended),
            )
            .order_by(User.id.asc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def active_field_user_ids(self) -> list[int]:
        """All active non-admin user ids — the broadcast announcement audience."""
        stmt = select(User.id).where(
            User.is_active.is_(True), User.role != UserRole.ADMIN
        )
        return [int(i) for i in (await self.db.execute(stmt)).scalars().all()]

    async def active_team_member_ids(self, team_id: int) -> list[int]:
        stmt = select(User.id).where(
            User.team_id == team_id,
            User.is_active.is_(True),
            User.role != UserRole.ADMIN,
        )
        return [int(i) for i in (await self.db.execute(stmt)).scalars().all()]
