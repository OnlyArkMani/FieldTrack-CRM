"""Order review (checklist #34) + farmer order history (checklist #35) DB
access. DB access ONLY — no business rules, no commits, no HTTP."""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession



from app.models.crm import Farmer, Visit, VisitOrder, VisitPlanItem
from app.models.user import User


class OrderRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    async def get_by_id(self, order_id: int) -> VisitOrder | None:
        return await self.db.get(VisitOrder, order_id)

    async def list_pending(
        self, *, team_id: int | None = None
    ) -> list[tuple[VisitOrder, str | None, str | None, str | None, int | None]]:
        """SUBMITTED orders, newest first, with farmer/employee name, the
        farmer's customer type, and the bags targeted by the originating
        visit plan item attached (list view — the review UI needs these, not
        just ids). VisitOrder has no team_id of its own — scope via the
        capturing employee's team."""
        stmt = (
            select(
                VisitOrder,
                Farmer.name.label("farmer_name"),
                User.name.label("employee_name"),
                Farmer.customer_type.label("customer_type"),
                VisitPlanItem.target_order_bags.label("target_order_bags"),
            )
            .outerjoin(Farmer, Farmer.id == VisitOrder.farmer_id)
            .outerjoin(User, User.id == VisitOrder.employee_id)
            .outerjoin(Visit, Visit.id == VisitOrder.visit_id)
            .outerjoin(VisitPlanItem, VisitPlanItem.id == Visit.plan_item_id)
            .where(VisitOrder.status == "SUBMITTED")
        )
        if team_id is not None:
            stmt = stmt.where(User.team_id == team_id)
        stmt = stmt.order_by(VisitOrder.created_at.desc())
        return [tuple(row) for row in (await self.db.execute(stmt)).all()]

    async def orders_for_farmer(self, farmer_id: int) -> list[VisitOrder]:
        stmt = (
            select(VisitOrder)
            .where(VisitOrder.farmer_id == farmer_id)
            .order_by(VisitOrder.created_at.desc())
        )
        return list((await self.db.execute(stmt)).scalars().all())
