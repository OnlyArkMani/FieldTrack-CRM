"""Order review (checklist #34) + farmer order history (checklist #35)
router — Module 3 extension. Thin HTTP layer; logic lives in OrderService.

Separate from visits.py: these are flat queries independent of a specific
visit (all pending orders across a team, or a farmer's full order history),
the same reasoning leads.py and daily_reports.py are their own routers
rather than nested under visits.py.
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_current_manager, get_db
from app.models.user import User
from app.schemas.crm import OrderReviewRequest, VisitOrderResponse
from app.services.order_service import OrderService

router = APIRouter(prefix="/orders", tags=["orders"])


@router.get("/pending", response_model=list[VisitOrderResponse])
async def pending_orders(
    manager: Annotated[User, Depends(get_current_manager)],
    db: Annotated[AsyncSession, Depends(get_db)],
    team_id: int | None = Query(default=None),
) -> list[VisitOrderResponse]:
    """SUBMITTED orders awaiting approval. Admin sees all (optionally
    filtered by team_id); managers are locked to their own team(s)."""
    return await OrderService(db).list_pending(manager, team_id=team_id)


@router.post("/{order_id}/review", response_model=VisitOrderResponse)
async def review_order(
    order_id: int,
    body: OrderReviewRequest,
    manager: Annotated[User, Depends(get_current_manager)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> VisitOrderResponse:
    """Approve or reject a SUBMITTED order. Notifies the capturing employee
    (best-effort) either way."""
    return await OrderService(db).review(manager, order_id, body)


@router.get("/farmer/{farmer_id}", response_model=list[VisitOrderResponse])
async def farmer_order_history(
    farmer_id: int,
    user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[VisitOrderResponse]:
    """Full order history for one farmer (checklist #35) — any authorized
    viewer; the service enforces the same visibility rule as the rest of the
    farmer module (own team / created-by / admin sees all)."""
    return await OrderService(db).history_for_farmer(farmer_id, user=user)
