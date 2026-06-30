"""Lead (CRM Module 4) DB access. DB access ONLY.

Current lead status = the latest leads row per farmer. Leads are append-only and
`id` is monotonic, so max(id) per farmer identifies the newest row — a portable
"latest per group" that works on both Postgres and SQLite (no DISTINCT ON / no
window functions, matching the rest of the codebase)."""
from datetime import date as date_type

from sqlalchemy import Select, case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.crm import Farmer, FollowUp, Lead, Visit
from app.models.user import Team, User

# HOT first, then WARM, then COLD.
_STATUS_ORDER = case(
    (Lead.status == "HOT", 0),
    (Lead.status == "WARM", 1),
    else_=2,
)


class LeadRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    @staticmethod
    def _latest_ids():
        """Subquery of the newest lead id per farmer."""
        return (
            select(func.max(Lead.id).label("mid"))
            .group_by(Lead.farmer_id)
            .subquery()
        )

    @staticmethod
    def _next_fu_date_sq():
        return (
            select(FollowUp.scheduled_date)
            .where(FollowUp.farmer_id == Farmer.id, FollowUp.status == "PENDING")
            .order_by(FollowUp.scheduled_date.asc(), FollowUp.id.asc())
            .limit(1)
            .correlate(Farmer)
            .scalar_subquery()
        )

    @staticmethod
    def _next_fu_time_sq():
        return (
            select(FollowUp.scheduled_time)
            .where(FollowUp.farmer_id == Farmer.id, FollowUp.status == "PENDING")
            .order_by(FollowUp.scheduled_date.asc(), FollowUp.id.asc())
            .limit(1)
            .correlate(Farmer)
            .scalar_subquery()
        )

    @staticmethod
    def _last_visit_sq():
        return (
            select(func.max(Visit.check_in_at))
            .where(Visit.farmer_id == Farmer.id)
            .correlate(Farmer)
            .scalar_subquery()
        )

    def _scope(
        self,
        stmt: Select,
        *,
        team_ids: list[int] | None,
        created_by: int | None,
        employee_id: int | None,
        status: str | None,
    ) -> Select:
        if team_ids is not None:
            stmt = stmt.where(Farmer.team_id.in_(team_ids))
        if created_by is not None:
            stmt = stmt.where(Farmer.created_by == created_by)
        if employee_id is not None:
            stmt = stmt.where(Lead.employee_id == employee_id)
        if status is not None:
            stmt = stmt.where(Lead.status == status)
        return stmt

    async def latest_lead_rows(
        self,
        *,
        team_ids: list[int] | None = None,
        created_by: int | None = None,
        employee_id: int | None = None,
        status: str | None = None,
    ) -> list:
        """Rows of (Lead, farmer_name, village, team_id, last_visit, fu_date,
        fu_time, employee_name) — one per farmer, current status, HOT→WARM→COLD."""
        if team_ids is not None and not team_ids:
            return []
        latest = self._latest_ids()
        stmt = (
            select(
                Lead,
                Farmer.name,
                Farmer.village,
                Farmer.team_id,
                self._last_visit_sq().label("last_visit"),
                self._next_fu_date_sq().label("fu_date"),
                self._next_fu_time_sq().label("fu_time"),
                User.name.label("employee_name"),
            )
            .join(latest, Lead.id == latest.c.mid)
            .join(Farmer, Farmer.id == Lead.farmer_id)
            .outerjoin(User, User.id == Lead.employee_id)
        )
        stmt = self._scope(
            stmt,
            team_ids=team_ids,
            created_by=created_by,
            employee_id=employee_id,
            status=status,
        )
        stmt = stmt.order_by(_STATUS_ORDER.asc(), Lead.created_at.desc())
        return list((await self.db.execute(stmt)).all())

    async def pipeline_rows(self) -> list[tuple[str, str | None, str | None]]:
        """(status, team_name, employee_name) for every farmer's current lead —
        the admin pipeline source, aggregated in the service."""
        latest = self._latest_ids()
        stmt = (
            select(Lead.status, Team.name, User.name)
            .join(latest, Lead.id == latest.c.mid)
            .join(Farmer, Farmer.id == Lead.farmer_id)
            .outerjoin(Team, Team.id == Farmer.team_id)
            .outerjoin(User, User.id == Lead.employee_id)
        )
        return [
            (row[0], row[1], row[2]) for row in (await self.db.execute(stmt)).all()
        ]

    # ── writes ───────────────────────────────────────────────────────────
    def add(self, obj) -> None:
        self.db.add(obj)

    async def get_farmer(self, farmer_id: int) -> Farmer | None:
        return await self.db.get(Farmer, farmer_id)

    async def supervised_team_ids(self, supervisor_id: int) -> list[int]:
        stmt = select(Team.id).where(Team.supervisor_id == supervisor_id)
        return list((await self.db.execute(stmt)).scalars().all())
