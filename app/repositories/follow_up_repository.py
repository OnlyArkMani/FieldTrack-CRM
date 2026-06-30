"""Follow-up (CRM Module 4) DB access. DB access ONLY. The scheduler-facing
methods return ORM FollowUp objects so the jobs can flip reminder flags / status
and commit within their own unit of work."""
from datetime import date as date_type
from datetime import time as time_type

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.crm import Farmer, FollowUp
from app.models.user import Team, User


class FollowUpRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    async def get(self, follow_up_id: int) -> FollowUp | None:
        return await self.db.get(FollowUp, follow_up_id)

    async def supervised_team_ids(self, supervisor_id: int) -> list[int]:
        stmt = select(Team.id).where(Team.supervisor_id == supervisor_id)
        return list((await self.db.execute(stmt)).scalars().all())

    # ── list views ───────────────────────────────────────────────────────
    async def list_for_employee(
        self,
        employee_id: int,
        *,
        date_from: date_type | None,
        date_to: date_type | None,
        status: str | None,
    ) -> list:
        """Rows of (FollowUp, farmer_name), scheduled_date ASC."""
        stmt = (
            select(FollowUp, Farmer.name)
            .outerjoin(Farmer, Farmer.id == FollowUp.farmer_id)
            .where(FollowUp.employee_id == employee_id)
        )
        stmt = self._date_status(stmt, date_from, date_to, status)
        stmt = stmt.order_by(
            FollowUp.scheduled_date.asc(),
            FollowUp.scheduled_time.asc().nullsfirst(),
            FollowUp.id.asc(),
        )
        return list((await self.db.execute(stmt)).all())

    async def list_for_team(
        self,
        team_ids: list[int] | None,
        *,
        employee_id: int | None,
        date_from: date_type | None,
        date_to: date_type | None,
        status: str | None,
    ) -> list:
        """Rows of (FollowUp, farmer_name, employee_name) for employees on the
        given teams. team_ids None == all teams (admin); an empty list == none."""
        if team_ids is not None and not team_ids:
            return []
        stmt = (
            select(FollowUp, Farmer.name, User.name)
            .outerjoin(Farmer, Farmer.id == FollowUp.farmer_id)
            .join(User, User.id == FollowUp.employee_id)
        )
        if team_ids is not None:
            stmt = stmt.where(User.team_id.in_(team_ids))
        if employee_id is not None:
            stmt = stmt.where(FollowUp.employee_id == employee_id)
        stmt = self._date_status(stmt, date_from, date_to, status)
        stmt = stmt.order_by(
            FollowUp.scheduled_date.asc(),
            FollowUp.scheduled_time.asc().nullsfirst(),
            FollowUp.id.asc(),
        )
        return list((await self.db.execute(stmt)).all())

    @staticmethod
    def _date_status(stmt, date_from, date_to, status):
        if date_from is not None:
            stmt = stmt.where(FollowUp.scheduled_date >= date_from)
        if date_to is not None:
            stmt = stmt.where(FollowUp.scheduled_date <= date_to)
        if status is not None:
            stmt = stmt.where(FollowUp.status == status)
        return stmt

    # ── scheduler queries (return ORM objects to mutate) ─────────────────
    async def due_24h(self, target_date: date_type) -> list:
        """(FollowUp, farmer_name) due on target_date, PENDING, no 24h sent."""
        stmt = (
            select(FollowUp, Farmer.name)
            .outerjoin(Farmer, Farmer.id == FollowUp.farmer_id)
            .where(
                FollowUp.scheduled_date == target_date,
                FollowUp.status == "PENDING",
                FollowUp.reminder_sent_24h.is_(False),
            )
        )
        return list((await self.db.execute(stmt)).all())

    async def due_1h(
        self, today: date_type, t_from: time_type, t_to: time_type
    ) -> list:
        """(FollowUp, farmer_name) today with a time in [t_from, t_to], still
        PENDING/ACKNOWLEDGED, no 1h sent."""
        stmt = (
            select(FollowUp, Farmer.name)
            .outerjoin(Farmer, Farmer.id == FollowUp.farmer_id)
            .where(
                FollowUp.scheduled_date == today,
                FollowUp.scheduled_time.is_not(None),
                FollowUp.scheduled_time >= t_from,
                FollowUp.scheduled_time <= t_to,
                FollowUp.status.in_(("PENDING", "ACKNOWLEDGED")),
                FollowUp.reminder_sent_1h.is_(False),
            )
        )
        return list((await self.db.execute(stmt)).all())

    async def escalation_candidates(
        self, today: date_type, cutoff_time: time_type
    ) -> list:
        """(FollowUp, farmer_name, employee_name, supervisor_id) today, still
        PENDING, 24h sent, whose time is >2h past (scheduled_time < cutoff)."""
        stmt = (
            select(FollowUp, Farmer.name, User.name, Team.supervisor_id)
            .outerjoin(Farmer, Farmer.id == FollowUp.farmer_id)
            .outerjoin(User, User.id == FollowUp.employee_id)
            .outerjoin(Team, Team.id == User.team_id)
            .where(
                FollowUp.scheduled_date == today,
                FollowUp.status == "PENDING",
                FollowUp.reminder_sent_24h.is_(True),
                FollowUp.scheduled_time.is_not(None),
                FollowUp.scheduled_time < cutoff_time,
            )
        )
        return list((await self.db.execute(stmt)).all())
