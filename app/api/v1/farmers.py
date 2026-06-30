"""Farmers (Customer/Farmer DB) router — Module 1. Thin HTTP layer; all logic
and team-scope authorization live in FarmerService.

AUTHZ:
- All endpoints require an authenticated active user. Team scoping is enforced
  inside the service (ADMIN sees all; supervisor/employee see their team).
- Create/update/lead-status are available to any field user for their own
  team's farmers; the service decides what team a new farmer lands in.
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_db
from app.schemas.common import CursorPage
from app.schemas.crm import (
    FarmerCreate,
    FarmerDetailResponse,
    FarmerListItem,
    FarmerResponse,
    FarmerUpdate,
    LeadHistoryItem,
    LeadResponse,
    LeadStatusUpdate,
    LivestockProfileResponse,
    VisitSummary,
)
from app.services.farmer_service import FarmerService

router = APIRouter(prefix="/farmers", tags=["farmers"])


@router.get("/ping")
async def ping() -> dict:
    return {"status": "ok", "module": "farmers"}


@router.get("", response_model=CursorPage[FarmerListItem])
async def list_farmers(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    cursor: str | None = Query(default=None, description="Opaque forward cursor"),
    limit: int = Query(default=20, ge=1, le=100),
    team_id: int | None = Query(default=None, description="Admin-only team filter"),
    lead_status: str | None = Query(
        default=None, description="Filter by current lead status: HOT | WARM | COLD"
    ),
    search: str | None = Query(
        default=None, max_length=200, description="Match name or village"
    ),
) -> CursorPage[FarmerListItem]:
    """Paginated farmer list with the CURRENT lead status joined per row.
    Supervisor/employee see only their team's farmers; admin sees all."""
    return await FarmerService(db).list_farmers(
        user=user,
        cursor=cursor,
        limit=limit,
        team_id=team_id,
        lead_status=lead_status.strip().upper() if lead_status else None,
        search=search,
    )


@router.get("/{farmer_id}", response_model=FarmerDetailResponse)
async def get_farmer(
    farmer_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> FarmerDetailResponse:
    """Full profile: base info, current lead, last 3 visits, latest livestock,
    pending follow-ups, and total orders/visits."""
    return await FarmerService(db).get_farmer_with_full_profile(farmer_id, user)


@router.post("", response_model=FarmerResponse, status_code=201)
async def create_farmer(
    body: FarmerCreate,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> FarmerResponse:
    """Create a farmer. Employees are pinned to their own team; admin/supervisor
    may set team_id explicitly."""
    return await FarmerService(db).create_farmer(body, user=user)


@router.put("/{farmer_id}", response_model=FarmerResponse)
async def update_farmer(
    farmer_id: int,
    body: FarmerUpdate,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> FarmerResponse:
    """Update base info only (livestock is captured per visit, not here)."""
    return await FarmerService(db).update_farmer(farmer_id, body, user=user)


@router.get("/{farmer_id}/visits", response_model=CursorPage[VisitSummary])
async def farmer_visits(
    farmer_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    cursor: str | None = Query(default=None, description="Opaque forward cursor"),
    limit: int = Query(default=20, ge=1, le=100),
) -> CursorPage[VisitSummary]:
    """Full visit history, paginated, newest first."""
    return await FarmerService(db).list_visits(
        farmer_id, user=user, cursor=cursor, limit=limit
    )


@router.get(
    "/{farmer_id}/livestock-history",
    response_model=list[LivestockProfileResponse],
)
async def farmer_livestock_history(
    farmer_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[LivestockProfileResponse]:
    """Every livestock snapshot for this farmer, newest first — shows how the
    herd/feed data evolved across visits."""
    return await FarmerService(db).livestock_history(farmer_id, user=user)


@router.get("/{farmer_id}/lead-history", response_model=list[LeadHistoryItem])
async def farmer_lead_history(
    farmer_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[LeadHistoryItem]:
    """All lead status changes with timestamps and reasons, newest first."""
    return await FarmerService(db).lead_history(farmer_id, user=user)


@router.post("/{farmer_id}/lead-status", response_model=LeadResponse, status_code=201)
async def update_lead_status(
    farmer_id: int,
    body: LeadStatusUpdate,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> LeadResponse:
    """Record a lead status change (Hot/Warm/Cold) with a required reason. One
    row per change — full history is preserved (see /lead-history)."""
    return await FarmerService(db).update_lead_status(farmer_id, body, user=user)
