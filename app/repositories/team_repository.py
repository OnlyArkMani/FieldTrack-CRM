"""Team DB access. DB-only — no business rules, no commits, no HTTP errors.

The list query is the interesting one: team card needs member_count,
manager_name, and present_today in a single grouped pass rather than
N+1 per-team lookups.
"""
from datetime import date

from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.models.attendance import Attendance
from app.models.crm import Visit, VisitOrder, VisitPlan, VisitPlanItem
from app.models.enums import AttendanceStatus
from app.models.misc import AuditLog
from app.models.user import Team, User


class TeamOrdersSummaryRow:
    """Plain carrier for one team's target-vs-completed order bags for a day."""

    def __init__(
        self, *, team_id: int, team_name: str, target_order_bags: int, completed_order_bags: int
    ) -> None:
        self.team_id = team_id
        self.team_name = team_name
        self.target_order_bags = target_order_bags
        self.completed_order_bags = completed_order_bags


class TeamRow:
    """Plain carrier for an aggregated team row (keeps the service free of
    SQLAlchemy Row tuples)."""

    def __init__(
        self,
        team: Team,
        *,
        manager_name: str | None,
        member_count: int,
        present_today: int,
    ) -> None:
        self.id = team.id
        self.name = team.name
        self.description = team.description
        self.manager_id = team.manager_id
        self.manager_name = manager_name
        self.member_count = member_count
        self.present_today = present_today
        self.is_active = team.is_active


class TeamRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    # ── Reads ─────────────────────────────────────────────────────────────
    async def list_with_stats(
        self, *, today: date, only_active: bool = True, manager_id: int | None = None
    ) -> list[TeamRow]:
        """One pass: team + manager name + member count + present-today
        count. Members are users with team_id = team.id (role-agnostic).

        present_today = members with an attendance row dated `today` whose
        status is PRESENT or HALF_DAY (ABSENT rows don't count as present).
        """
        manager = aliased(User)
        member = aliased(User)

        # Correlated subquery for present-today avoids fanning the member join
        # out across the attendance join.
        present_sq = (
            select(func.count(func.distinct(Attendance.user_id)))
            .select_from(Attendance)
            .join(member, member.id == Attendance.user_id)
            .where(
                and_(
                    member.team_id == Team.id,
                    Attendance.date == today,
                    Attendance.status.in_(
                        (AttendanceStatus.PRESENT, AttendanceStatus.HALF_DAY)
                    ),
                )
            )
            .correlate(Team)
            .scalar_subquery()
        )
        member_count_sq = (
            select(func.count(member.id))
            .select_from(member)
            .where(member.team_id == Team.id)
            .correlate(Team)
            .scalar_subquery()
        )

        stmt = (
            select(
                Team,
                manager.name.label("manager_name"),
                member_count_sq.label("member_count"),
                present_sq.label("present_today"),
            )
            .outerjoin(manager, manager.id == Team.manager_id)
            .order_by(Team.name.asc())
        )
        if only_active:
            stmt = stmt.where(Team.is_active.is_(True))
        if manager_id is not None:
            stmt = stmt.where(Team.manager_id == manager_id)

        result = await self.db.execute(stmt)
        return [
            TeamRow(
                row[0],
                manager_name=row[1],
                member_count=int(row[2] or 0),
                present_today=int(row[3] or 0),
            )
            for row in result.all()
        ]

    async def orders_summary(
        self, *, target_date: date, manager_id: int | None
    ) -> list[TeamOrdersSummaryRow]:
        """One row per active team: bags targeted for `target_date` (from
        visit plans, plus ad-hoc same-day targets set at check-in) vs bags
        actually captured via orders on visits checked in that day.
        manager_id scopes to teams that manager owns; None = every active
        team (admin)."""
        teams_stmt = select(Team.id, Team.name).where(Team.is_active.is_(True))
        if manager_id is not None:
            teams_stmt = teams_stmt.where(Team.manager_id == manager_id)
        teams = (await self.db.execute(teams_stmt)).all()
        if not teams:
            return []
        team_ids = [t[0] for t in teams]

        # Target bags, source 1: items on a submitted plan for the day.
        planned_rows = (
            await self.db.execute(
                select(
                    User.team_id,
                    func.coalesce(func.sum(VisitPlanItem.target_order_bags), 0),
                )
                .select_from(VisitPlanItem)
                .join(VisitPlan, VisitPlan.id == VisitPlanItem.plan_id)
                .join(User, User.id == VisitPlan.employee_id)
                .where(VisitPlan.plan_date == target_date, User.team_id.in_(team_ids))
                .group_by(User.team_id)
            )
        ).all()

        # Target bags, source 2: ad-hoc visits (no VisitPlan) with a target
        # set at check-in, scoped by the visit's own date. Deduplicated to
        # one row per plan item first — a plan item can have more than one
        # Visit row against it (revisits), which would otherwise double-count
        # the same target (see employees.py::crm_performance for the same fix).
        adhoc_items = (
            select(
                User.team_id.label("team_id"),
                VisitPlanItem.id.label("id"),
                VisitPlanItem.target_order_bags.label("target_order_bags"),
            )
            .select_from(VisitPlanItem)
            .join(Visit, Visit.plan_item_id == VisitPlanItem.id)
            .join(User, User.id == Visit.employee_id)
            .where(
                VisitPlanItem.plan_id.is_(None),
                func.date(Visit.check_in_at) == target_date,
                User.team_id.in_(team_ids),
            )
            .distinct()
            .subquery()
        )
        adhoc_rows = (
            await self.db.execute(
                select(
                    adhoc_items.c.team_id,
                    func.coalesce(func.sum(adhoc_items.c.target_order_bags), 0),
                ).group_by(adhoc_items.c.team_id)
            )
        ).all()

        target_by_team: dict[int, int] = {}
        for team_id, total in [*planned_rows, *adhoc_rows]:
            target_by_team[team_id] = target_by_team.get(team_id, 0) + int(total)

        # Completed bags: orders captured via visits checked in that day.
        completed_rows = (
            await self.db.execute(
                select(User.team_id, func.coalesce(func.sum(VisitOrder.bags_count), 0))
                .select_from(VisitOrder)
                .join(Visit, Visit.id == VisitOrder.visit_id)
                .join(User, User.id == Visit.employee_id)
                .where(
                    func.date(Visit.check_in_at) == target_date,
                    User.team_id.in_(team_ids),
                )
                .group_by(User.team_id)
            )
        ).all()
        completed_by_team = {team_id: int(total) for team_id, total in completed_rows}

        return [
            TeamOrdersSummaryRow(
                team_id=team_id,
                team_name=team_name,
                target_order_bags=target_by_team.get(team_id, 0),
                completed_order_bags=completed_by_team.get(team_id, 0),
            )
            for team_id, team_name in teams
        ]

    async def get_stats_for(
        self, team_id: int, *, today: date
    ) -> TeamRow | None:
        rows = await self.list_with_stats(today=today, only_active=False)
        return next((r for r in rows if r.id == team_id), None)

    async def get_by_id(self, team_id: int) -> Team | None:
        return await self.db.get(Team, team_id)

    async def get_members(self, team_id: int) -> list[User]:
        stmt = (
            select(User)
            .where(User.team_id == team_id)
            .order_by(User.name.asc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def name_exists(self, name: str, *, exclude_id: int | None = None) -> bool:
        stmt = select(func.count(Team.id)).where(func.lower(Team.name) == name.lower())
        if exclude_id is not None:
            stmt = stmt.where(Team.id != exclude_id)
        return bool((await self.db.execute(stmt)).scalar_one())

    async def user_by_id(self, user_id: int) -> User | None:
        return await self.db.get(User, user_id)

    # ── Writes (no commit) ───────────────────────────────────────────────
    def add(self, team: Team) -> None:
        self.db.add(team)

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
                entity_type="team",
                entity_id=entity_id,
                metadata_=metadata,
                ip_address=ip_address,
            )
        )
