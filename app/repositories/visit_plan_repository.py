"""Visit-plan (CRM Module 2) DB access. DB access ONLY — no business rules, no
commits, no HTTP, no Redis (services own those).

The plan-item and follow-up queries enrich each row with the farmer's name +
village and three correlated scalar subqueries (current lead, last visit time,
last meeting note) so the planning cards render in one round-trip. All three
subqueries are PG + SQLite safe (no DISTINCT ON / window functions).
"""
from datetime import date as date_type

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.crm import (
    Farmer,
    FollowUp,
    Lead,
    Visit,
    VisitNote,
    VisitPlan,
    VisitPlanItem,
)
from app.models.enums import UserRole
from app.models.user import Team, User


class VisitPlanRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    # ── correlated scalar subqueries (farmer-context enrichment) ─────────
    @staticmethod
    def _lead_sq():
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

    @staticmethod
    def _last_note_sq():
        return (
            select(VisitNote.meeting_highlights)
            .join(Visit, Visit.id == VisitNote.visit_id)
            .where(Visit.farmer_id == Farmer.id)
            .order_by(VisitNote.created_at.desc(), VisitNote.id.desc())
            .limit(1)
            .correlate(Farmer)
            .scalar_subquery()
        )

    # ── single plan ──────────────────────────────────────────────────────
    async def get_plan(
        self, employee_id: int, plan_date: date_type
    ) -> VisitPlan | None:
        stmt = select(VisitPlan).where(
            VisitPlan.employee_id == employee_id,
            VisitPlan.plan_date == plan_date,
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def get_plan_by_id(self, plan_id: int) -> VisitPlan | None:
        return await self.db.get(VisitPlan, plan_id)

    async def plan_items_joined(self, plan_id: int) -> list:
        """Rows of (VisitPlanItem, farmer_name, village, lead, last_visit,
        last_note) ordered by sequence."""
        stmt = (
            select(
                VisitPlanItem,
                Farmer.name,
                Farmer.village,
                Farmer.lat,
                Farmer.lng,
                self._lead_sq().label("lead"),
                self._last_visit_sq().label("last_visit"),
                self._last_note_sq().label("last_note"),
            )
            .outerjoin(Farmer, Farmer.id == VisitPlanItem.farmer_id)
            .where(VisitPlanItem.plan_id == plan_id)
            .order_by(VisitPlanItem.sequence_order.asc(), VisitPlanItem.id.asc())
        )
        return list((await self.db.execute(stmt)).all())

    async def pending_follow_ups_joined(
        self, employee_id: int, plan_date: date_type
    ) -> list:
        """Pending follow-ups due on `plan_date`, enriched like plan items."""
        stmt = (
            select(
                FollowUp,
                Farmer.name,
                Farmer.village,
                Farmer.lat,
                Farmer.lng,
                self._lead_sq().label("lead"),
                self._last_visit_sq().label("last_visit"),
                self._last_note_sq().label("last_note"),
            )
            .outerjoin(Farmer, Farmer.id == FollowUp.farmer_id)
            .where(
                FollowUp.employee_id == employee_id,
                FollowUp.scheduled_date == plan_date,
                FollowUp.status == "PENDING",
            )
            .order_by(FollowUp.scheduled_time.asc().nullsfirst(), FollowUp.id.asc())
        )
        return list((await self.db.execute(stmt)).all())

    async def get_item(self, item_id: int) -> VisitPlanItem | None:
        return await self.db.get(VisitPlanItem, item_id)

    async def farmer_ids_in_plan(self, plan_id: int) -> set[int]:
        stmt = select(VisitPlanItem.farmer_id).where(
            VisitPlanItem.plan_id == plan_id
        )
        return {r for r in (await self.db.execute(stmt)).scalars().all() if r}

    # ── writes (no commit — service owns the transaction) ────────────────
    def add(self, obj) -> None:
        self.db.add(obj)

    async def delete_items(self, plan_id: int) -> None:
        await self.db.execute(
            delete(VisitPlanItem).where(VisitPlanItem.plan_id == plan_id)
        )

    async def farmer_exists(self, farmer_id: int) -> bool:
        return (await self.db.get(Farmer, farmer_id)) is not None

    # ── team / admin views ───────────────────────────────────────────────
    async def supervised_team_ids(self, supervisor_id: int) -> list[int]:
        stmt = select(Team.id).where(Team.supervisor_id == supervisor_id)
        return list((await self.db.execute(stmt)).scalars().all())

    async def list_employees(
        self, *, team_ids: list[int] | None
    ) -> list[tuple[User, str | None]]:
        """Active EMPLOYEE-role users, optionally restricted to `team_ids`.
        team_ids None == all (admin). Returns (User, team_name)."""
        stmt = (
            select(User, Team.name)
            .outerjoin(Team, Team.id == User.team_id)
            .where(User.role == UserRole.EMPLOYEE, User.is_active.is_(True))
        )
        if team_ids is not None:
            if not team_ids:
                return []
            stmt = stmt.where(User.team_id.in_(team_ids))
        stmt = stmt.order_by(User.name.asc())
        return [(row[0], row[1]) for row in (await self.db.execute(stmt)).all()]

    async def plans_for_employees(
        self, employee_ids: list[int], plan_date: date_type
    ) -> dict[int, VisitPlan]:
        if not employee_ids:
            return {}
        stmt = select(VisitPlan).where(
            VisitPlan.employee_id.in_(employee_ids),
            VisitPlan.plan_date == plan_date,
        )
        rows = (await self.db.execute(stmt)).scalars().all()
        return {p.employee_id: p for p in rows}

    # ── scheduler (global, no requesting user) ───────────────────────────
    async def all_active_employees_with_supervisor(
        self,
    ) -> list[tuple[int, str, str | None, int | None]]:
        """(employee_id, employee_name, team_name, supervisor_id) for every
        active EMPLOYEE-role user. Used by the 8 PM unsubmitted-plan job."""
        stmt = (
            select(User.id, User.name, Team.name, Team.supervisor_id)
            .outerjoin(Team, Team.id == User.team_id)
            .where(User.role == UserRole.EMPLOYEE, User.is_active.is_(True))
        )
        return [
            (row[0], row[1], row[2], row[3])
            for row in (await self.db.execute(stmt)).all()
        ]

    async def submitted_employee_ids(self, plan_date: date_type) -> set[int]:
        stmt = select(VisitPlan.employee_id).where(
            VisitPlan.plan_date == plan_date,
            VisitPlan.status == "SUBMITTED",
        )
        return {r for r in (await self.db.execute(stmt)).scalars().all() if r}
