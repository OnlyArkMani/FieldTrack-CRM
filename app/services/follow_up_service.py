"""Follow-up (CRM Module 4) business logic. Routers stay thin."""
import logging
from datetime import date as date_type

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import forbidden, not_found
from app.models.crm import FollowUp
from app.models.enums import UserRole
from app.models.user import User
from app.repositories.follow_up_repository import FollowUpRepository
from app.schemas.crm import FollowUpCompleteRequest, FollowUpListItem

logger = logging.getLogger("fieldtrack.follow_up")


class FollowUpService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = FollowUpRepository(db)

    @staticmethod
    def _item(
        fu: FollowUp, farmer_name: str | None, employee_name: str | None = None
    ) -> FollowUpListItem:
        return FollowUpListItem(
            id=fu.id,
            farmer_id=fu.farmer_id,
            farmer_name=farmer_name,
            employee_id=fu.employee_id,
            employee_name=employee_name,
            scheduled_date=fu.scheduled_date,
            scheduled_time=fu.scheduled_time,
            purpose=fu.purpose,
            status=fu.status,
            reminder_sent_24h=fu.reminder_sent_24h,
            reminder_sent_1h=fu.reminder_sent_1h,
        )

    async def get_my(
        self,
        user: User,
        *,
        date_from: date_type | None,
        date_to: date_type | None,
        status: str | None,
    ) -> list[FollowUpListItem]:
        rows = await self.repo.list_for_employee(
            user.id, date_from=date_from, date_to=date_to, status=status
        )
        return [self._item(fu, name) for (fu, name) in rows]

    async def get_team(
        self,
        user: User,
        *,
        employee_id: int | None,
        date_from: date_type | None,
        date_to: date_type | None,
        status: str | None,
    ) -> list[FollowUpListItem]:
        if user.role == UserRole.ADMIN:
            team_ids = None  # all teams
        elif user.role == UserRole.SUPERVISOR:
            team_ids = await self.repo.supervised_team_ids(user.id)
        else:
            raise forbidden("Team follow-ups are supervisor/admin only")
        rows = await self.repo.list_for_team(
            team_ids,
            employee_id=employee_id,
            date_from=date_from,
            date_to=date_to,
            status=status,
        )
        return [self._item(fu, name, emp) for (fu, name, emp) in rows]

    async def acknowledge(self, user: User, follow_up_id: int) -> FollowUpListItem:
        fu = await self._load_owned(follow_up_id, user)
        if fu.status == "PENDING":
            fu.status = "ACKNOWLEDGED"
            self.repo.db.add(fu)
            await self.db.commit()
            await self.db.refresh(fu)
        return self._item(fu, None)

    async def complete(
        self, user: User, follow_up_id: int, payload: FollowUpCompleteRequest
    ) -> FollowUpListItem:
        fu = await self._load_owned(follow_up_id, user)
        fu.status = "COMPLETED"
        if payload.completed_visit_id is not None:
            fu.completed_visit_id = payload.completed_visit_id
        self.repo.db.add(fu)
        await self.db.commit()
        await self.db.refresh(fu)
        return self._item(fu, None)

    async def _load_owned(self, follow_up_id: int, user: User) -> FollowUp:
        fu = await self.repo.get(follow_up_id)
        if fu is None:
            raise not_found("Follow-up not found")
        privileged = user.role in (UserRole.ADMIN, UserRole.SUPERVISOR)
        if fu.employee_id != user.id and not privileged:
            raise forbidden("This follow-up isn't yours")
        return fu
