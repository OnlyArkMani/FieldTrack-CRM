"""Order review (checklist #34 — manager approval) + farmer order history
(checklist #35). Routers stay thin."""
import logging
from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import bad_request, forbidden, not_found
from app.models.crm import VisitOrder
from app.models.enums import UserRole
from app.models.user import Team, User
from app.repositories.order_repository import OrderRepository
from app.schemas.crm import OrderReviewRequest, VisitOrderResponse

logger = logging.getLogger("fieldtrack.order")


class OrderService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = OrderRepository(db)

    # ── scope helpers ────────────────────────────────────────────────────
    async def _managed_team_ids(self, manager_id: int) -> set[int]:
        from sqlalchemy import select

        stmt = select(Team.id).where(Team.manager_id == manager_id)
        return set((await self.db.execute(stmt)).scalars().all())

    @staticmethod
    def _to_response(
        row: tuple[VisitOrder, str | None, str | None]
    ) -> VisitOrderResponse:
        order, farmer_name, employee_name = row
        resp = VisitOrderResponse.model_validate(order)
        resp.farmer_name = farmer_name
        resp.employee_name = employee_name
        return resp

    # ── pending list (admin/manager) ───────────────────────────────────
    async def list_pending(
        self, actor: User, *, team_id: int | None
    ) -> list[VisitOrderResponse]:
        if actor.role == UserRole.EMPLOYEE:
            raise forbidden("Employees cannot review orders")

        if actor.role == UserRole.MANAGER:
            managed = await self._managed_team_ids(actor.id)
            if not managed:
                return []
            if team_id is not None and team_id not in managed:
                raise forbidden("You don't manage this team")
            # No explicit team_id: a manager with exactly one team gets it
            # for free; with several, they see all of their own teams' orders
            # (list_pending already accepts one team_id, so loop when >1).
            if team_id is None and len(managed) > 1:
                rows: list[tuple[VisitOrder, str | None, str | None]] = []
                for tid in managed:
                    rows.extend(await self.repo.list_pending(team_id=tid))
                rows.sort(key=lambda r: r[0].created_at, reverse=True)
                return [self._to_response(r) for r in rows]
            team_id = team_id or next(iter(managed))

        rows = await self.repo.list_pending(team_id=team_id)
        return [self._to_response(r) for r in rows]

    # ── approve / reject ─────────────────────────────────────────────────
    async def review(
        self, actor: User, order_id: int, payload: OrderReviewRequest
    ) -> VisitOrderResponse:
        if actor.role == UserRole.EMPLOYEE:
            raise forbidden("Employees cannot review orders")

        order = await self.repo.get_by_id(order_id)
        if order is None:
            raise not_found("Order not found")
        if order.status != "SUBMITTED":
            raise bad_request(f"Order is already {order.status.lower()}")

        if actor.role == UserRole.MANAGER:
            managed = await self._managed_team_ids(actor.id)
            employee = await self.db.get(User, order.employee_id)
            if employee is None or employee.team_id not in managed:
                raise forbidden("This order isn't from your team")

        if payload.action == "REJECT":
            reason = (payload.rejection_reason or "").strip()
            if len(reason) < 10:
                raise bad_request(
                    "A rejection reason (min 10 characters) is required"
                )
            order.status = "REJECTED"
            order.rejection_reason = reason
        else:
            order.status = "APPROVED"

        order.approved_by = actor.id
        order.approved_at = datetime.now(timezone.utc)
        self.db.add(order)
        await self.db.flush()

        # Notify the employee who captured the order — best-effort, never
        # blocks the review (same pattern as ORDER_CAPTURED in visit_service).
        try:
            if order.employee_id is not None:
                from app.services.notification_service import NotificationService

                notif = NotificationService(self.db)
                if order.status == "APPROVED":
                    title, body = "Order approved", (
                        f"Your order of {order.bags_count} bags has been approved."
                    )
                    ntype = "ORDER_APPROVED"
                else:
                    title, body = "Order rejected", (
                        f"Your order of {order.bags_count} bags was rejected: "
                        f"{order.rejection_reason}"
                    )
                    ntype = "ORDER_REJECTED"
                await notif.send_fcm(
                    order.employee_id,
                    title=title,
                    body=body,
                    type=ntype,
                    data={
                        "screen": "farmer",
                        "farmer_id": str(order.farmer_id),
                    },
                    commit=False,
                )
        except Exception:  # noqa: BLE001 — notification must never break review
            logger.exception("%s notification failed", order.status)

        await self.db.commit()
        await self.db.refresh(order)
        return VisitOrderResponse.model_validate(order)

    # ── farmer order history (checklist #35) ─────────────────────────────
    async def history_for_farmer(
        self, farmer_id: int, *, user: User
    ) -> list[VisitOrderResponse]:
        from app.services.farmer_service import FarmerService

        farmers = FarmerService(self.db)
        farmer = await farmers.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        await farmers._assert_can_view(farmer, user)  # noqa: SLF001 — shared scoping rule

        rows = await self.repo.orders_for_farmer(farmer_id)
        return [VisitOrderResponse.model_validate(o) for o in rows]
