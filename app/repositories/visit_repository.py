"""Visit (CRM Module 3) DB access. DB access ONLY — no business rules, no
commits, no HTTP (services own those)."""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from sqlalchemy import func

from app.models.crm import (
    Farmer,
    Lead,
    LivestockProfile,
    Visit,
    VisitNote,
    VisitOrder,
    VisitPhoto,
    VisitPlanItem,
)


class VisitRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    # ── lookups ──────────────────────────────────────────────────────────
    async def get_farmer(self, farmer_id: int) -> Farmer | None:
        return await self.db.get(Farmer, farmer_id)

    async def get_visit(self, visit_id: int) -> Visit | None:
        return await self.db.get(Visit, visit_id)

    async def get_plan_item(self, item_id: int) -> VisitPlanItem | None:
        return await self.db.get(VisitPlanItem, item_id)

    async def farmer_name(self, farmer_id: int) -> str | None:
        return (
            await self.db.execute(
                select(Farmer.name).where(Farmer.id == farmer_id)
            )
        ).scalar_one_or_none()

    async def active_visit(self, employee_id: int) -> Visit | None:
        """The employee's currently open (CHECKED_IN) visit, newest first."""
        stmt = (
            select(Visit)
            .where(
                Visit.employee_id == employee_id,
                Visit.status == "CHECKED_IN",
            )
            .order_by(Visit.check_in_at.desc().nullslast(), Visit.id.desc())
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    # ── step data ────────────────────────────────────────────────────────
    async def notes_for(self, visit_id: int) -> VisitNote | None:
        stmt = select(VisitNote).where(VisitNote.visit_id == visit_id).limit(1)
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def livestock_for_visit(self, visit_id: int) -> LivestockProfile | None:
        """Most recent livestock snapshot captured during this visit."""
        stmt = (
            select(LivestockProfile)
            .where(LivestockProfile.visit_id == visit_id)
            .order_by(
                LivestockProfile.recorded_at.desc(), LivestockProfile.id.desc()
            )
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def latest_livestock_for_farmer(
        self, farmer_id: int
    ) -> LivestockProfile | None:
        """Newest snapshot across all visits — the 'last recorded' reference."""
        stmt = (
            select(LivestockProfile)
            .where(LivestockProfile.farmer_id == farmer_id)
            .order_by(
                LivestockProfile.recorded_at.desc(), LivestockProfile.id.desc()
            )
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    async def orders_for(self, visit_id: int) -> list[VisitOrder]:
        stmt = (
            select(VisitOrder)
            .where(VisitOrder.visit_id == visit_id)
            .order_by(VisitOrder.id.asc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def lead_for_visit(self, visit_id: int) -> Lead | None:
        stmt = (
            select(Lead)
            .where(Lead.visit_id == visit_id)
            .order_by(Lead.created_at.desc(), Lead.id.desc())
            .limit(1)
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    # ── photos (checklist #24) ───────────────────────────────────────────
    async def photos_for(self, visit_id: int) -> list[VisitPhoto]:
        stmt = (
            select(VisitPhoto)
            .where(VisitPhoto.visit_id == visit_id)
            .order_by(VisitPhoto.id.asc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def photo_count(self, visit_id: int) -> int:
        stmt = select(func.count(VisitPhoto.id)).where(
            VisitPhoto.visit_id == visit_id
        )
        return int((await self.db.execute(stmt)).scalar_one())

    async def get_photo(self, photo_id: int) -> VisitPhoto | None:
        return await self.db.get(VisitPhoto, photo_id)

    async def delete_photo(self, photo: VisitPhoto) -> None:
        await self.db.delete(photo)

    # ── writes (no commit — service owns the transaction) ────────────────
    def add(self, obj) -> None:
        self.db.add(obj)
