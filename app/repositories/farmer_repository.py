"""Farmer (CRM) DB access. Repositories do DB access ONLY — no business rules,
no commits (services own transactions), no HTTP exceptions, no Redis.

The list query enriches each farmer with two correlated scalar subqueries that
work identically on Postgres and SQLite (no DISTINCT ON / window functions):
  - current lead status = latest leads row for the farmer
  - last visit timestamp = max(check_in_at) over the farmer's visits
"""
from datetime import datetime

from sqlalchemy import Select, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.crm import (
    Farmer,
    FollowUp,
    Lead,
    LivestockProfile,
    Visit,
    VisitOrder,
)
from app.models.user import Team


class FarmerRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    # ── correlated scalar subqueries (PG + SQLite safe) ──────────────────
    @staticmethod
    def _latest_lead_status_sq():
        return (
            select(Lead.status)
            .where(Lead.farmer_id == Farmer.id)
            .order_by(Lead.created_at.desc(), Lead.id.desc())
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

    def _apply_list_filters(
        self,
        stmt: Select,
        *,
        team_id: int | None,
        created_by: int | None,
        search: str | None,
        lead_status: str | None,
    ) -> Select:
        if team_id is not None:
            stmt = stmt.where(Farmer.team_id == team_id)
        if created_by is not None:
            stmt = stmt.where(Farmer.created_by == created_by)
        if search and search.strip():
            like = f"%{search.strip()}%"
            stmt = stmt.where(
                or_(Farmer.name.ilike(like), Farmer.village.ilike(like))
            )
        if lead_status:
            stmt = stmt.where(self._latest_lead_status_sq() == lead_status)
        return stmt

    async def list_farmers(
        self,
        *,
        cursor_id: int | None,
        limit: int,
        team_id: int | None = None,
        created_by: int | None = None,
        search: str | None = None,
        lead_status: str | None = None,
    ) -> tuple[list[tuple], int]:
        """Keyset page (Farmer.id ASC). Returns rows of
        (Farmer, team_name, lead_status, last_visit_at) + total count.

        Fetches limit+1 to detect has_more without a second query.
        """
        lead_sq = self._latest_lead_status_sq()
        visit_sq = self._last_visit_sq()
        stmt = select(
            Farmer,
            Team.name.label("team_name"),
            lead_sq.label("lead_status"),
            visit_sq.label("last_visit_at"),
        ).outerjoin(Team, Team.id == Farmer.team_id)
        stmt = self._apply_list_filters(
            stmt,
            team_id=team_id,
            created_by=created_by,
            search=search,
            lead_status=lead_status,
        )
        if cursor_id is not None:
            stmt = stmt.where(Farmer.id > cursor_id)
        stmt = stmt.order_by(Farmer.id.asc()).limit(limit + 1)
        rows = (await self.db.execute(stmt)).all()

        count_stmt = self._apply_list_filters(
            select(func.count(Farmer.id)),
            team_id=team_id,
            created_by=created_by,
            search=search,
            lead_status=lead_status,
        )
        total = (await self.db.execute(count_stmt)).scalar_one()
        return list(rows), int(total)

    # ── single-farmer reads ──────────────────────────────────────────────
    async def get_by_id(self, farmer_id: int) -> Farmer | None:
        return await self.db.get(Farmer, farmer_id)

    async def get_with_team(self, farmer_id: int) -> tuple[Farmer, str | None] | None:
        stmt = (
            select(Farmer, Team.name)
            .outerjoin(Team, Team.id == Farmer.team_id)
            .where(Farmer.id == farmer_id)
        )
        row = (await self.db.execute(stmt)).first()
        if row is None:
            return None
        return row[0], row[1]

    async def latest_lead(self, farmer_id: int) -> Lead | None:
        stmt = (
            select(Lead)
            .where(Lead.farmer_id == farmer_id)
            .order_by(Lead.created_at.desc(), Lead.id.desc())
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def lead_history(self, farmer_id: int) -> list[Lead]:
        stmt = (
            select(Lead)
            .where(Lead.farmer_id == farmer_id)
            .order_by(Lead.created_at.desc(), Lead.id.desc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def recent_visits(self, farmer_id: int, *, limit: int) -> list[Visit]:
        stmt = (
            select(Visit)
            .where(Visit.farmer_id == farmer_id)
            .order_by(Visit.check_in_at.desc().nullslast(), Visit.id.desc())
            .limit(limit)
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def list_visits(
        self, farmer_id: int, *, cursor_id: int | None, limit: int
    ) -> tuple[list[Visit], int]:
        """Full visit history, newest first. Keyset by id DESC (visits are
        append-only; id order matches chronological order closely enough and is
        a stable unique total order)."""
        stmt = select(Visit).where(Visit.farmer_id == farmer_id)
        if cursor_id is not None:
            stmt = stmt.where(Visit.id < cursor_id)
        stmt = stmt.order_by(Visit.id.desc()).limit(limit + 1)
        rows = list((await self.db.execute(stmt)).scalars().all())

        total = int(
            (
                await self.db.execute(
                    select(func.count(Visit.id)).where(Visit.farmer_id == farmer_id)
                )
            ).scalar_one()
        )
        return rows, total

    async def visit_count(self, farmer_id: int) -> int:
        return int(
            (
                await self.db.execute(
                    select(func.count(Visit.id)).where(Visit.farmer_id == farmer_id)
                )
            ).scalar_one()
        )

    async def order_count(self, farmer_id: int) -> int:
        return int(
            (
                await self.db.execute(
                    select(func.count(VisitOrder.id)).where(
                        VisitOrder.farmer_id == farmer_id
                    )
                )
            ).scalar_one()
        )

    async def latest_livestock(self, farmer_id: int) -> LivestockProfile | None:
        stmt = (
            select(LivestockProfile)
            .where(LivestockProfile.farmer_id == farmer_id)
            .order_by(
                LivestockProfile.recorded_at.desc(), LivestockProfile.id.desc()
            )
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def livestock_history(self, farmer_id: int) -> list[LivestockProfile]:
        stmt = (
            select(LivestockProfile)
            .where(LivestockProfile.farmer_id == farmer_id)
            .order_by(
                LivestockProfile.recorded_at.desc(), LivestockProfile.id.desc()
            )
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def pending_follow_ups(self, farmer_id: int) -> list[FollowUp]:
        stmt = (
            select(FollowUp)
            .where(
                FollowUp.farmer_id == farmer_id,
                FollowUp.status.in_(("PENDING", "ACKNOWLEDGED")),
            )
            .order_by(FollowUp.scheduled_date.asc(), FollowUp.id.asc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def active_team_exists(self, team_id: int) -> bool:
        stmt = select(func.count(Team.id)).where(
            Team.id == team_id, Team.is_active.is_(True)
        )
        return bool((await self.db.execute(stmt)).scalar_one())

    # ── writes (no commit — service owns the transaction) ────────────────
    def add(self, obj) -> None:
        self.db.add(obj)

    def add_lead(self, lead: Lead) -> None:
        self.db.add(lead)
