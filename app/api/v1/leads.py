"""Lead Management (Hot/Warm/Cold) router — Module 4. Thin HTTP layer; logic +
team scope live in LeadService.
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import (
    CurrentUser,
    get_current_admin,
    get_current_supervisor,
    get_db,
)
from app.models.user import User
from app.schemas.crm import (
    LeadListItem,
    LeadResponse,
    LeadStatusUpdateRequest,
    PipelineResponse,
    TeamLeadsResponse,
)
from app.services.lead_service import LeadService

router = APIRouter(prefix="/leads", tags=["leads"])


@router.get("/ping")
async def ping() -> dict:
    return {"status": "ok", "module": "leads"}


def _norm_status(s: str | None) -> str | None:
    return s.strip().upper() if s else None


@router.get("/my", response_model=list[LeadListItem])
async def my_leads(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    status: str | None = Query(default=None, description="HOT | WARM | COLD"),
) -> list[LeadListItem]:
    """The caller's farmers with their current lead status, HOT→WARM→COLD."""
    return await LeadService(db).get_my_leads(user, status=_norm_status(status))


@router.get("/team", response_model=TeamLeadsResponse)
async def team_leads(
    supervisor: Annotated[User, Depends(get_current_supervisor)],
    db: Annotated[AsyncSession, Depends(get_db)],
    status: str | None = Query(default=None, description="HOT | WARM | COLD"),
    employee_id: int | None = Query(default=None),
) -> TeamLeadsResponse:
    """Team farmers with lead status, grouped counts + a filterable list."""
    return await LeadService(db).get_team_leads(
        supervisor, status=_norm_status(status), employee_id=employee_id
    )


@router.get("/pipeline", response_model=PipelineResponse)
async def pipeline(
    _admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> PipelineResponse:
    """Full pipeline summary: totals + breakdown by team and by employee."""
    return await LeadService(db).get_pipeline()


@router.post("/update-status", response_model=LeadResponse, status_code=201)
async def update_status(
    body: LeadStatusUpdateRequest,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> LeadResponse:
    """Change a farmer's lead status without a visit (reason required, min 10
    chars). Optionally schedules a follow-up for WARM/COLD. History preserved."""
    return await LeadService(db).update_status(user, body)
