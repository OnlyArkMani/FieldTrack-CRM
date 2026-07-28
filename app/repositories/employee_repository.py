"""Employee (users) DB access. Repositories do DB access ONLY — no business
rules, no commits (services own transactions), no HTTP exceptions, no Redis.
"""
from datetime import date, datetime

from sqlalchemy import Select, and_, case, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.attendance import Attendance
from app.models.location import LocationLog
from app.models.misc import AuditLog
from app.models.user import Team, User


class EmployeeRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    # ── Reads ─────────────────────────────────────────────────────────────
    def _apply_list_filters(
        self,
        stmt: Select,
        *,
        team_id: int | None,
        is_active: bool | None,
        search: str | None,
        managed_by: int | None,
    ) -> Select:
        if team_id is not None:
            stmt = stmt.where(User.team_id == team_id)
        if is_active is not None:
            stmt = stmt.where(User.is_active == is_active)
        if search and search.strip():
            like = f"%{search.strip()}%"
            stmt = stmt.where(or_(User.name.ilike(like), User.email.ilike(like)))
        if managed_by is not None:
            # Managers only see the employees on team(s) they manage — never
            # themselves, other managers, or the admin.
            stmt = stmt.where(
                User.team_id.in_(
                    select(Team.id).where(Team.manager_id == managed_by)
                ),
                User.id != managed_by,
            )
        return stmt

    async def list_employees(
        self,
        *,
        cursor_id: int | None,
        limit: int,
        team_id: int | None = None,
        is_active: bool | None = None,
        search: str | None = None,
        managed_by: int | None = None,
    ) -> tuple[list[User], int]:
        """Keyset page (id ASC) + a total count for the filtered set.

        Fetches limit+1 to detect has_more without a second query — the
        service slices the sentinel off and derives the next cursor.
        """
        stmt = self._apply_list_filters(
            select(User),
            team_id=team_id,
            is_active=is_active,
            search=search,
            managed_by=managed_by,
        )
        if cursor_id is not None:
            stmt = stmt.where(User.id > cursor_id)
        stmt = stmt.order_by(User.name.asc(), User.id.asc()).limit(limit + 1)
        rows = (await self.db.execute(stmt)).scalars().all()

        count_stmt = self._apply_list_filters(
            select(func.count(User.id)),
            team_id=team_id,
            is_active=is_active,
            search=search,
            managed_by=managed_by,
        )
        total = (await self.db.execute(count_stmt)).scalar_one()
        return list(rows), int(total)

    async def get_by_id(self, user_id: int) -> User | None:
        return await self.db.get(User, user_id)

    async def get_with_team(self, user_id: int) -> User | None:
        stmt = (
            select(User)
            .where(User.id == user_id)
            .options(selectinload(User.team))
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def email_exists(self, email: str, *, exclude_id: int | None = None) -> bool:
        stmt = select(func.count(User.id)).where(User.email == email)
        if exclude_id is not None:
            stmt = stmt.where(User.id != exclude_id)
        return bool((await self.db.execute(stmt)).scalar_one())

    async def phone_exists(self, phone: str, *, exclude_id: int | None = None) -> bool:
        stmt = select(func.count(User.id)).where(User.phone == phone)
        if exclude_id is not None:
            stmt = stmt.where(User.id != exclude_id)
        return bool((await self.db.execute(stmt)).scalar_one())

    async def active_team_exists(self, team_id: int) -> bool:
        stmt = select(func.count(Team.id)).where(
            and_(Team.id == team_id, Team.is_active.is_(True))
        )
        return bool((await self.db.execute(stmt)).scalar_one())

    # ── Writes (no commit — service owns the transaction) ────────────────
    def add(self, user: User) -> None:
        self.db.add(user)

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
                entity_type="employee",
                entity_id=entity_id,
                metadata_=metadata,
                ip_address=ip_address,
            )
        )

    # ── Attendance summary (monthly) ─────────────────────────────────────
    async def attendance_for_month(
        self, user_id: int, year: int, month: int
    ) -> list[Attendance]:
        start = date(year, month, 1)
        end = date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)
        stmt = (
            select(Attendance)
            .where(
                and_(
                    Attendance.user_id == user_id,
                    Attendance.date >= start,
                    Attendance.date < end,
                )
            )
            .order_by(Attendance.date.asc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    # ── Mock GPS integrity (anti-gaming visibility) ──────────────────────
    async def mock_gps_count(self, user_id: int, *, since: datetime) -> int:
        """How many flagged (is_mock_gps) pings for this user since `since`."""
        stmt = select(func.count(LocationLog.id)).where(
            LocationLog.user_id == user_id,
            LocationLog.is_mock_gps.is_(True),
            LocationLog.timestamp >= since,
        )
        return int((await self.db.execute(stmt)).scalar_one())

    async def mock_gps_points(
        self, user_id: int, *, since: datetime, limit: int
    ) -> list[LocationLog]:
        """Flagged points since `since`, newest first — the integrity timeline.
        Capped (a determined spoofer could generate many; the UI only needs a
        recent window)."""
        stmt = (
            select(LocationLog)
            .where(
                LocationLog.user_id == user_id,
                LocationLog.is_mock_gps.is_(True),
                LocationLog.timestamp >= since,
            )
            .order_by(LocationLog.timestamp.desc())
            .limit(limit)
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def mock_gps_user_ids_since(self, since: datetime) -> set[int]:
        """User ids with at least one flagged ping since `since` — one query
        powering the 'mock GPS today' warning dot across a whole list page."""
        stmt = (
            select(LocationLog.user_id)
            .where(
                LocationLog.is_mock_gps.is_(True),
                LocationLog.timestamp >= since,
            )
            .distinct()
        )
        return set((await self.db.execute(stmt)).scalars().all())

    # ── Location history (date-filtered) ─────────────────────────────────
    async def location_history(
        self,
        user_id: int,
        *,
        date_from: date,
        date_to: date,
        limit: int,
    ) -> list[LocationLog]:
        """Inclusive [date_from, date_to] by ping timestamp, ordered ascending
        (track order). Fetches limit+1 so the service can flag truncation.

        func.date() casts the timestamptz to a date in the SESSION timezone;
        the server runs UTC (see base.py), so this compares UTC calendar days
        — consistent with how attendance.date is stored.
        """
        stmt = (
            select(LocationLog)
            .where(LocationLog.user_id == user_id)
            .where(func.date(LocationLog.timestamp) >= date_from)
            .where(func.date(LocationLog.timestamp) <= date_to)
            .order_by(LocationLog.timestamp.asc())
            .limit(limit + 1)
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def order_counts_by_user_ids(
        self, user_ids: list[int]
    ) -> dict[int, dict[str, int]]:
        if not user_ids:
            return {}
        from app.models.crm import VisitOrder, VisitPlan, VisitPlanItem

        out = {uid: {"target": 0, "captured": 0, "approved": 0} for uid in user_ids}

        # 1. Target bags from planned visits
        target_stmt = (
            select(
                VisitPlan.employee_id,
                func.coalesce(func.sum(VisitPlanItem.target_order_bags), 0).label("target_bags"),
            )
            .join(VisitPlanItem, VisitPlanItem.plan_id == VisitPlan.id)
            .where(VisitPlan.employee_id.in_(user_ids))
            .group_by(VisitPlan.employee_id)
        )
        target_res = await self.db.execute(target_stmt)
        for uid, target_bags in target_res.all():
            if uid in out:
                out[uid]["target"] = int(target_bags or 0)

        # 2. Captured and Approved bags from visit orders
        orders_stmt = (
            select(
                VisitOrder.employee_id,
                func.coalesce(func.sum(VisitOrder.bags_count), 0).label("captured_bags"),
                func.coalesce(
                    func.sum(
                        case((VisitOrder.status == "APPROVED", VisitOrder.bags_count), else_=0)
                    ),
                    0,
                ).label("approved_bags"),
            )
            .where(VisitOrder.employee_id.in_(user_ids))
            .group_by(VisitOrder.employee_id)
        )
        orders_res = await self.db.execute(orders_stmt)
        for uid, captured_bags, approved_bags in orders_res.all():
            if uid in out:
                out[uid]["captured"] = int(captured_bags or 0)
                out[uid]["approved"] = int(approved_bags or 0)

        return out
