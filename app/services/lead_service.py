"""Lead (CRM Module 4) business logic. Routers stay thin.

Team scope mirrors the farmer module: ADMIN sees everything, SUPERVISOR sees the
teams they supervise, EMPLOYEE sees their own team (or, with no team, the farmers
they created)."""
import logging
from collections import defaultdict

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import forbidden, not_found
from app.models.crm import FollowUp, Lead
from app.models.enums import UserRole
from app.models.user import User
from app.repositories.lead_repository import LeadRepository
from app.schemas.crm import (
    LeadListItem,
    LeadResponse,
    LeadStatusUpdateRequest,
    PipelineEmployeeRow,
    PipelineResponse,
    PipelineTeamRow,
    TeamLeadsResponse,
)

logger = logging.getLogger("fieldtrack.lead")

_WARM_COLD = ("WARM", "COLD")


class LeadService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = LeadRepository(db)

    # ── row -> LeadListItem ──────────────────────────────────────────────
    @staticmethod
    def _item(row, *, team_view: bool) -> LeadListItem:
        lead, name, village, _team_id, last_visit, fu_date, fu_time, emp_name = row
        warm_cold = lead.status in _WARM_COLD
        return LeadListItem(
            farmer_id=lead.farmer_id,
            farmer_name=name or "Unknown",
            village=village,
            lead_status=lead.status,
            last_visit_at=last_visit,
            follow_up_date=fu_date if warm_cold else None,
            follow_up_time=fu_time if warm_cold else None,
            reason_note=lead.reason_note,
            employee_id=lead.employee_id,
            employee_name=emp_name if team_view else None,
        )

    # ── my leads ─────────────────────────────────────────────────────────
    async def get_my_leads(
        self, user: User, *, status: str | None
    ) -> list[LeadListItem]:
        if user.team_id is not None:
            scope = {"team_ids": [user.team_id]}
        else:
            scope = {"created_by": user.id}
        rows = await self.repo.latest_lead_rows(status=status, **scope)
        return [self._item(r, team_view=False) for r in rows]

    # ── team leads (supervisor/admin) ────────────────────────────────────
    async def get_team_leads(
        self, user: User, *, status: str | None, employee_id: int | None
    ) -> TeamLeadsResponse:
        team_ids = await self._scope_team_ids(user)
        rows = await self.repo.latest_lead_rows(
            team_ids=team_ids, employee_id=employee_id, status=status
        )
        items = [self._item(r, team_view=True) for r in rows]
        hot = sum(1 for i in items if i.lead_status == "HOT")
        warm = sum(1 for i in items if i.lead_status == "WARM")
        cold = sum(1 for i in items if i.lead_status == "COLD")
        return TeamLeadsResponse(
            hot_count=hot, warm_count=warm, cold_count=cold, items=items
        )

    async def _scope_team_ids(self, user: User) -> list[int] | None:
        if user.role == UserRole.ADMIN:
            return None
        if user.role == UserRole.SUPERVISOR:
            return await self.repo.supervised_team_ids(user.id)
        raise forbidden("Team leads are supervisor/admin only")

    # ── pipeline (admin) ─────────────────────────────────────────────────
    async def get_pipeline(self) -> PipelineResponse:
        rows = await self.repo.pipeline_rows()
        hot = warm = cold = 0
        by_team: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0])
        by_emp: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0])
        for status, team_name, emp_name in rows:
            idx = {"HOT": 0, "WARM": 1, "COLD": 2}.get(status)
            if idx is None:
                continue
            if idx == 0:
                hot += 1
            elif idx == 1:
                warm += 1
            else:
                cold += 1
            by_team[team_name or "Unassigned"][idx] += 1
            by_emp[emp_name or "Unknown"][idx] += 1
        return PipelineResponse(
            hot_count=hot,
            warm_count=warm,
            cold_count=cold,
            by_team=[
                PipelineTeamRow(team_name=t, hot=v[0], warm=v[1], cold=v[2])
                for t, v in sorted(by_team.items())
            ],
            by_employee=[
                PipelineEmployeeRow(name=n, hot=v[0], warm=v[1], cold=v[2])
                for n, v in sorted(by_emp.items())
            ],
        )

    # ── update status (no visit) ─────────────────────────────────────────
    async def update_status(
        self, user: User, payload: LeadStatusUpdateRequest
    ) -> LeadResponse:
        farmer = await self.repo.get_farmer(payload.farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        self._assert_can_access(farmer, user)

        lead = Lead(
            farmer_id=payload.farmer_id,
            employee_id=user.id,
            visit_id=None,
            status=payload.status,
            reason_note=payload.reason_note.strip(),
        )
        self.repo.add(lead)

        # Optionally schedule a follow-up for WARM/COLD.
        if payload.status in _WARM_COLD and payload.follow_up_date is not None:
            self.repo.add(
                FollowUp(
                    farmer_id=payload.farmer_id,
                    employee_id=user.id,
                    visit_id=None,
                    scheduled_date=payload.follow_up_date,
                    scheduled_time=payload.follow_up_time,
                    purpose=payload.follow_up_purpose,
                    status="PENDING",
                )
            )

        await self.db.commit()
        await self.db.refresh(lead)
        return LeadResponse.model_validate(lead)

    def _assert_can_access(self, farmer, user: User) -> None:
        if user.role in (UserRole.ADMIN, UserRole.SUPERVISOR):
            return
        if user.team_id is not None and farmer.team_id == user.team_id:
            return
        if farmer.created_by == user.id:
            return
        raise forbidden("You don't have access to this farmer")
