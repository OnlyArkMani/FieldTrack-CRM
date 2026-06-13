"""Team DB access. DB-only — no business rules, no commits, no HTTP errors.

The list query is the interesting one: team card needs member_count,
supervisor_name, and present_today in a single grouped pass rather than
N+1 per-team lookups.
"""
from datetime import date

from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.models.attendance import Attendance
from app.models.enums import AttendanceStatus
from app.models.misc import AuditLog
from app.models.user import Team, User


class TeamRow:
    """Plain carrier for an aggregated team row (keeps the service free of
    SQLAlchemy Row tuples)."""

    def __init__(
        self,
        team: Team,
        *,
        supervisor_name: str | None,
        member_count: int,
        present_today: int,
    ) -> None:
        self.id = team.id
        self.name = team.name
        self.description = team.description
        self.supervisor_id = team.supervisor_id
        self.supervisor_name = supervisor_name
        self.member_count = member_count
        self.present_today = present_today
        self.is_active = team.is_active


class TeamRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    # ── Reads ─────────────────────────────────────────────────────────────
    async def list_with_stats(
        self, *, today: date, only_active: bool = True
    ) -> list[TeamRow]:
        """One pass: team + supervisor name + member count + present-today
        count. Members are users with team_id = team.id (role-agnostic).

        present_today = members with an attendance row dated `today` whose
        status is PRESENT or HALF_DAY (ABSENT rows don't count as present).
        """
        supervisor = aliased(User)
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
                supervisor.name.label("supervisor_name"),
                member_count_sq.label("member_count"),
                present_sq.label("present_today"),
            )
            .outerjoin(supervisor, supervisor.id == Team.supervisor_id)
            .order_by(Team.name.asc())
        )
        if only_active:
            stmt = stmt.where(Team.is_active.is_(True))

        result = await self.db.execute(stmt)
        return [
            TeamRow(
                row[0],
                supervisor_name=row[1],
                member_count=int(row[2] or 0),
                present_today=int(row[3] or 0),
            )
            for row in result.all()
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
