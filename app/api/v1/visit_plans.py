"""Visit Planning (pre-day) router — Module 2. Thin HTTP layer; logic + team
scope live in VisitPlanService.

AUTHZ:
- /my, POST, PATCH item: the caller's own plan (employee_id comes from the JWT,
  never the body).
- /team, /pending-submissions: manager or admin only.
"""
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_current_manager, get_db
from app.models.user import User
from app.schemas.crm import (
    CarryOverRequest,
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
    manager: Annotated[User, Depends(get_current_manager)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[PendingSubmissionView]:
    """Employees (in the caller's scope) with no SUBMITTED plan for tomorrow.
    Powers the 'plan not submitted' alert."""
    return await VisitPlanService(db).get_pending_submissions(manager)


@router.get("/team/{plan_date}", response_model=TeamPlansResponse)
async def team_plans(
    plan_date: date,
    manager: Annotated[User, Depends(get_current_manager)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TeamPlansResponse:
    """All in-scope employees' plans for a date — who submitted, who hasn't."""
    return await VisitPlanService(db).get_team_plans(manager, plan_date)


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


@router.post("/items/{item_id}/carry-over", response_model=MyPlanResponse)
async def carry_over_item(
    item_id: int,
    body: CarryOverRequest,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MyPlanResponse:
    """Reschedule a missed (carried-over) plan item onto a new date/time. The
    source item is marked SKIPPED and a fresh PLANNED item is created on
    body.target_date. Returns the target date's updated plan."""
    return await VisitPlanService(db).carry_over_item(
        user, item_id, body.target_date, body.time_slot
    )


@router.post("/items/{item_id}/skip", response_model=MyPlanResponse)
async def skip_missed_item(
    item_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> MyPlanResponse:
    """Drop a carried-over (missed) plan item — marks it SKIPPED. Returns the
    caller's plan for today."""
    return await VisitPlanService(db).skip_missed_item(user, item_id)
