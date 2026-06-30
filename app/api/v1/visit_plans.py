"""Visit Planning (pre-day) router — Module 2. Thin HTTP layer; logic + team
scope live in VisitPlanService.

AUTHZ:
- /my, POST, PATCH item: the caller's own plan (employee_id comes from the JWT,
  never the body).
- /team, /pending-submissions: supervisor or admin only.
"""
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_current_supervisor, get_db
from app.models.user import User
from app.schemas.crm import (
    MyPlanResponse,
    PendingSubmissionView,
    PlanItemStatusUpdate,
    TeamPlansResponse,
    VisitPlanCreate,
)
from app.services.visit_plan_service import VisitPlanService

router = APIRouter(prefix="/visit-plans", tags=["visit-plans"])


@router.get("/ping")
async def ping() -> dict:
    return {"status": "ok", "module": "visit_plans"}


@router.get("/pending-submissions", response_model=list[PendingSubmissionView])
async def pending_submissions(
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[PendingSubmissionView]:
    """Employees (in the caller's scope) with no SUBMITTED plan for tomorrow.
    Powers the 'plan not submitted' alert."""
    return await VisitPlanService(db).get_pending_submissions(supervisor)


@router.get("/team/{plan_date}", response_model=TeamPlansResponse)
async def team_plans(
    plan_date: date,
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TeamPlansResponse:
    """All in-scope employees' plans for a date — who submitted, who hasn't."""
    return await VisitPlanService(db).get_team_plans(supervisor, plan_date)


@router.get("/my/{plan_date}", response_model=MyPlanResponse)
async def my_plan(
    plan_date: date,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MyPlanResponse:
    """The caller's plan for a date. Returns an empty (DRAFT) plan rather than
    404 when none exists; pending follow-ups due that day are merged in."""
    return await VisitPlanService(db).get_my_plan(user, plan_date)


@router.post("", response_model=MyPlanResponse, status_code=201)
async def upsert_plan(
    body: VisitPlanCreate,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MyPlanResponse:
    """Create or update (upsert) the caller's plan for body.plan_date. Saving
    sets status to SUBMITTED; existing items are replaced, not duplicated."""
    return await VisitPlanService(db).upsert_plan(user, body)


@router.patch(
    "/{plan_id}/items/{item_id}", response_model=MyPlanResponse
)
async def update_item_status(
    plan_id: int,
    item_id: int,
    body: PlanItemStatusUpdate,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MyPlanResponse:
    """Update a single plan item's status (PLANNED -> COMPLETED / SKIPPED).
    Called when the employee checks in to (or skips) a visit."""
    return await VisitPlanService(db).update_item_status(
        user, plan_id, item_id, body
    )
