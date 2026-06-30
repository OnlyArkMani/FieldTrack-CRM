"""Visit Execution (Field Visit + Notes + Livestock + Orders + Lead) router —
Module 3. Thin HTTP layer; all logic + authorization live in VisitService.

Route order matters: the static /active and /check-in paths are declared before
the dynamic /{visit_id} so they're never swallowed by the id matcher.
"""
from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_db
from app.schemas.crm import (
    CheckInRequest,
    CheckInResponse,
    LivestockProfileResponse,
    LivestockUpsert,
    LocationRemarkRequest,
    OrderCreate,
    VisitCompleteRequest,
    VisitDetailResponse,
    VisitNoteResponse,
    VisitNotesUpsert,
    VisitOrderResponse,
)
from app.services.visit_service import VisitService

router = APIRouter(prefix="/visits", tags=["visits"])


@router.get("/ping")
async def ping() -> dict:
    return {"status": "ok", "module": "visits"}


@router.get("/active", response_model=VisitDetailResponse | None)
async def active_visit(
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> VisitDetailResponse | None:
    """The caller's currently open (CHECKED_IN) visit, or null. Used on app
    launch to restore an in-progress visit."""
    return await VisitService(db).get_active(user)


@router.post("/check-in", response_model=CheckInResponse, status_code=201)
async def check_in(
    body: CheckInRequest,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> CheckInResponse:
    """Start a visit. Never blocks: a >200 m gap sets location_warning and
    returns warning_required=true so the app collects a remark."""
    return await VisitService(db).check_in(user, body)


@router.post("/{visit_id}/location-remark", response_model=VisitDetailResponse)
async def location_remark(
    visit_id: int,
    body: LocationRemarkRequest,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> VisitDetailResponse:
    """Attach the employee's explanation for an out-of-range check-in. Only
    valid when the visit was flagged with a location warning."""
    return await VisitService(db).set_location_remark(user, visit_id, body.remark)


@router.patch("/{visit_id}/notes", response_model=VisitNoteResponse)
async def upsert_notes(
    visit_id: int,
    body: VisitNotesUpsert,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> VisitNoteResponse:
    """Upsert the guided meeting-notes form. step_completed tracks progress."""
    return await VisitService(db).upsert_notes(user, visit_id, body)


@router.patch("/{visit_id}/livestock", response_model=LivestockProfileResponse)
async def upsert_livestock(
    visit_id: int,
    body: LivestockUpsert,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> LivestockProfileResponse:
    """Capture a new livestock snapshot for this visit (history preserved) and
    denormalize total_cattle / feed brand / feed price onto the farmer."""
    return await VisitService(db).upsert_livestock(user, visit_id, body)


@router.post("/{visit_id}/orders", response_model=VisitOrderResponse, status_code=201)
async def create_order(
    visit_id: int,
    body: OrderCreate,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> VisitOrderResponse:
    """Capture an order. delivery_date must be at least 7 days out (400 else)."""
    return await VisitService(db).create_order(user, visit_id, body)


@router.post("/{visit_id}/complete", response_model=VisitDetailResponse)
async def complete_visit(
    visit_id: int,
    body: VisitCompleteRequest,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> VisitDetailResponse:
    """Finish the visit: set the lead, create a follow-up for Warm/Cold (date
    required), mark a linked plan item complete, and check out."""
    return await VisitService(db).complete_visit(user, visit_id, body)


@router.get("/{visit_id}", response_model=VisitDetailResponse)
async def visit_detail(
    visit_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> VisitDetailResponse:
    """Full visit detail: base info + notes + livestock + orders + lead."""
    return await VisitService(db).get_detail(user, visit_id)
