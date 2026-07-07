"""Vet-requirement dashboard router (July 2026 CRM revamp, Feature 4).

Lists visits where a veterinary visit was requested during the meeting, and
lets a manager/employee advance the request status. Scope handled in the
service (employee=own, supervisor=team, admin=all)."""
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_db
from app.schemas.crm import VetRequestItem, VetStatusUpdate
from app.services.vet_service import VetService

router = APIRouter(prefix="/vet-requests", tags=["vet"])


@router.get("", response_model=list[VetRequestItem])
async def list_vet_requests(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    status: str | None = Query(
        default=None, description="Filter: REQUESTED / SCHEDULED / DONE"
    ),
    team_id: int | None = Query(default=None, description="Admin-only team filter"),
    employee_id: int | None = Query(
        default=None,
        description="Supervisor/admin filter — a single employee's vet requests",
    ),
) -> list[VetRequestItem]:
    """Customers who requested a vet, newest first. Employee sees their own,
    supervisor their team, admin everything."""
    return await VetService(db).list_requests(
        user, status=status, team_id=team_id, employee_id=employee_id
    )


@router.patch("/{visit_id}/status", response_model=VetRequestItem)
async def update_vet_status(
    visit_id: int,
    body: VetStatusUpdate,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> VetRequestItem:
    """Advance a vet request: REQUESTED → SCHEDULED → DONE."""
    return await VetService(db).update_status(user, visit_id, body.vet_status)
