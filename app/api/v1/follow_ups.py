"""Follow-ups router — Module 4. Thin HTTP layer; logic + scope in
FollowUpService.
"""
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_current_supervisor, get_db
from app.models.user import User
from app.schemas.crm import FollowUpCompleteRequest, FollowUpListItem
from app.services.follow_up_service import FollowUpService

router = APIRouter(prefix="/follow-ups", tags=["follow-ups"])


@router.get("/ping")
async def ping() -> dict:
    return {"status": "ok", "module": "follow_ups"}


@router.get("/my", response_model=list[FollowUpListItem])
async def my_follow_ups(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
    status: str | None = Query(default=None),
) -> list[FollowUpListItem]:
    """The caller's follow-ups, scheduled_date ASC."""
    return await FollowUpService(db).get_my(
        user,
        date_from=date_from,
        date_to=date_to,
        status=status.strip().upper() if status else None,
    )


@router.get("/team", response_model=list[FollowUpListItem])
async def team_follow_ups(
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
    employee_id: int | None = Query(default=None),
    date_from: date | None = Query(default=None),
    date_to: date | None = Query(default=None),
    status: str | None = Query(default=None),
) -> list[FollowUpListItem]:
    """Team's follow-ups (supervisor: their teams; admin: all)."""
    return await FollowUpService(db).get_team(
        supervisor,
        employee_id=employee_id,
        date_from=date_from,
        date_to=date_to,
        status=status.strip().upper() if status else None,
    )


@router.post("/{follow_up_id}/acknowledge", response_model=FollowUpListItem)
async def acknowledge(
    follow_up_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> FollowUpListItem:
    """Acknowledge a reminder — sets status ACKNOWLEDGED and stops escalation."""
    return await FollowUpService(db).acknowledge(user, follow_up_id)


@router.post("/{follow_up_id}/complete", response_model=FollowUpListItem)
async def complete(
    follow_up_id: int,
    body: FollowUpCompleteRequest,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> FollowUpListItem:
    """Mark a follow-up done, optionally linking the visit that closed it."""
    return await FollowUpService(db).complete(user, follow_up_id, body)
