"""Village reference table — DB access only."""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.misc import Village


class VillageRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    async def search(
        self,
        *,
        q: str | None,
        district: str | None,
        limit: int,
    ) -> list[Village]:
        stmt = select(Village)

        if q:
            stmt = stmt.where(Village.village_name.ilike(f"%{q}%"))
        if district:
            stmt = stmt.where(Village.district_name.ilike(f"%{district}%"))

        stmt = stmt.order_by(Village.village_name).limit(limit)
        result = await self.db.execute(stmt)
        return list(result.scalars().all())

    async def districts(self, *, state_name: str = "Uttar Pradesh") -> list[str]:
        """Distinct district names for a state — used to populate district dropdowns."""
        stmt = (
            select(Village.district_name)
            .where(Village.state_name == state_name)
            .distinct()
            .order_by(Village.district_name)
        )
        result = await self.db.execute(stmt)
        return list(result.scalars().all())
