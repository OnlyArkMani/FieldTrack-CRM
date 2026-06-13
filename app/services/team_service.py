"""Team business logic. Owns transactions; repositories do the SQL.

PERFORMANCE METRIC:
  performance_pct = present_today / member_count * 100  (1 dp; 0.0 if empty).
  "present_today" counts members with a PRESENT/HALF_DAY attendance row dated
  today — the team-card's at-a-glance health number.

SOFT DELETE:
  DELETE flips is_active=False and detaches members (team_id -> NULL) so they
  aren't stranded pointing at a dead team. The row survives for audit/history.
"""
from datetime import date

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import bad_request, conflict, not_found
from app.models.enums import UserRole
from app.models.user import Team, User
from app.repositories.team_repository import TeamRepository, TeamRow
from app.schemas.team import (
    AddMemberRequest,
    TeamCreate,
    TeamDetailOut,
    TeamMemberOut,
    TeamOut,
    TeamUpdate,
)


class TeamService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = TeamRepository(db)

    @staticmethod
    def _performance(present: int, members: int) -> float:
        return round(present / members * 100, 1) if members else 0.0

    def _to_out(self, row: TeamRow) -> TeamOut:
        return TeamOut(
            id=row.id,
            name=row.name,
            description=row.description,
            supervisor_id=row.supervisor_id,
            supervisor_name=row.supervisor_name,
            member_count=row.member_count,
            present_today=row.present_today,
            performance_pct=self._performance(row.present_today, row.member_count),
        )

    # ── List ──────────────────────────────────────────────────────────────
    async def list_teams(self) -> list[TeamOut]:
        rows = await self.repo.list_with_stats(today=date.today(), only_active=True)
        return [self._to_out(r) for r in rows]

    # ── Detail ────────────────────────────────────────────────────────────
    async def get_detail(self, team_id: int) -> TeamDetailOut:
        row = await self.repo.get_stats_for(team_id, today=date.today())
        if row is None or not row.is_active:
            raise not_found("Team not found")
        members = await self.repo.get_members(team_id)
        base = self._to_out(row)
        return TeamDetailOut(
            **base.model_dump(),
            members=[
                TeamMemberOut(
                    id=m.id,
                    name=m.name,
                    email=m.email,
                    role=m.role.value,
                    profile_photo_url=m.profile_photo_url,
                    is_active=m.is_active,
                )
                for m in members
            ],
        )

    # ── Create (admin) ───────────────────────────────────────────────────
    async def create(
        self, payload: TeamCreate, *, actor: User, ip: str | None
    ) -> TeamDetailOut:
        if await self.repo.name_exists(payload.name):
            raise conflict("A team with this name already exists")
        if payload.supervisor_id is not None:
            await self._validate_supervisor(payload.supervisor_id)

        team = Team(
            name=payload.name,
            description=payload.description,
            supervisor_id=payload.supervisor_id,
        )
        self.repo.add(team)
        await self.db.flush()
        self.repo.add_audit_log(
            user_id=actor.id,
            action="TEAM_CREATED",
            entity_id=team.id,
            ip_address=ip,
            metadata={"name": team.name},
        )
        await self.db.commit()
        return await self.get_detail(team.id)

    # ── Update ───────────────────────────────────────────────────────────
    async def update(
        self, team_id: int, payload: TeamUpdate, *, actor: User, ip: str | None
    ) -> TeamDetailOut:
        team = await self.repo.get_by_id(team_id)
        if team is None or not team.is_active:
            raise not_found("Team not found")

        fields = payload.model_dump(exclude_unset=True)
        if "name" in fields and fields["name"]:
            if fields["name"].lower() != team.name.lower() and await self.repo.name_exists(
                fields["name"], exclude_id=team_id
            ):
                raise conflict("A team with this name already exists")
            team.name = fields["name"]
        if "description" in fields:
            team.description = fields["description"]
        if "supervisor_id" in fields:
            sid = fields["supervisor_id"]
            if sid is not None:
                await self._validate_supervisor(sid)
            team.supervisor_id = sid

        self.repo.add(team)
        self.repo.add_audit_log(
            user_id=actor.id,
            action="TEAM_UPDATED",
            entity_id=team.id,
            ip_address=ip,
            metadata={"fields": sorted(fields.keys())},
        )
        await self.db.commit()
        return await self.get_detail(team.id)

    # ── Soft delete ──────────────────────────────────────────────────────
    async def soft_delete(
        self, team_id: int, *, actor: User, ip: str | None
    ) -> None:
        team = await self.repo.get_by_id(team_id)
        if team is None or not team.is_active:
            raise not_found("Team not found")

        # Detach members so none point at an inactive team.
        for member in await self.repo.get_members(team_id):
            member.team_id = None
            self.db.add(member)
        team.is_active = False
        self.repo.add(team)
        self.repo.add_audit_log(
            user_id=actor.id,
            action="TEAM_DELETED",
            entity_id=team.id,
            ip_address=ip,
        )
        await self.db.commit()

    # ── Membership ───────────────────────────────────────────────────────
    async def add_member(
        self, team_id: int, payload: AddMemberRequest, *, actor: User, ip: str | None
    ) -> TeamDetailOut:
        team = await self.repo.get_by_id(team_id)
        if team is None or not team.is_active:
            raise not_found("Team not found")
        user = await self.repo.user_by_id(payload.user_id)
        if user is None:
            raise not_found("Employee not found")
        if user.team_id == team_id:
            raise conflict("Employee is already in this team")

        user.team_id = team_id
        self.db.add(user)
        self.repo.add_audit_log(
            user_id=actor.id,
            action="TEAM_MEMBER_ADDED",
            entity_id=team_id,
            ip_address=ip,
            metadata={"member_id": user.id},
        )
        await self.db.commit()
        return await self.get_detail(team_id)

    async def remove_member(
        self, team_id: int, user_id: int, *, actor: User, ip: str | None
    ) -> TeamDetailOut:
        team = await self.repo.get_by_id(team_id)
        if team is None or not team.is_active:
            raise not_found("Team not found")
        user = await self.repo.user_by_id(user_id)
        if user is None or user.team_id != team_id:
            raise not_found("Employee is not a member of this team")

        user.team_id = None
        self.db.add(user)
        self.repo.add_audit_log(
            user_id=actor.id,
            action="TEAM_MEMBER_REMOVED",
            entity_id=team_id,
            ip_address=ip,
            metadata={"member_id": user.id},
        )
        await self.db.commit()
        return await self.get_detail(team_id)

    # ── Helpers ──────────────────────────────────────────────────────────
    async def _validate_supervisor(self, supervisor_id: int) -> None:
        sup = await self.repo.user_by_id(supervisor_id)
        if sup is None:
            raise not_found("Supervisor not found")
        if sup.role not in (UserRole.SUPERVISOR, UserRole.ADMIN):
            raise bad_request("Assigned supervisor must have SUPERVISOR or ADMIN role")
