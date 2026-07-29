"""Village reference data — search + CSV seed service."""
import csv
import io
import logging

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.repositories.village_repository import VillageRepository
from app.schemas.village import VillageItem, VillageSeedResult

logger = logging.getLogger("fieldtrack.village")

_BATCH_SIZE = 1000

_UPSERT_SQL = text("""
    INSERT INTO villages (
        village_code, village_name, village_name_local,
        subdistrict_code, subdistrict_name,
        district_code, district_name,
        state_code, state_name
    ) VALUES (
        :village_code, :village_name, :village_name_local,
        :subdistrict_code, :subdistrict_name,
        :district_code, :district_name,
        :state_code, :state_name
    )
    ON CONFLICT (village_code) DO NOTHING
""")


def _int(val: str) -> int | None:
    v = str(val).strip()
    if not v:
        return None
    try:
        return int(float(v))
    except (ValueError, TypeError):
        return None


def _parse_row(row: dict) -> dict | None:
    village_code = _int(row.get("villageCode", ""))
    village_name = row.get("villageNameEnglish", "").strip()
    district_name = row.get("districtNameEnglish", "").strip()

    if not village_code or not village_name or not district_name:
        return None

    return {
        "village_code": village_code,
        "village_name": village_name,
        "village_name_local": row.get("villageNameLocal", "").strip() or None,
        "subdistrict_code": _int(row.get("subdistrictCode", "")),
        "subdistrict_name": row.get("subdistrictNameEnglish", "").strip() or None,
        "district_code": _int(row.get("districtCode", "")),
        "district_name": district_name,
        "state_code": _int(row.get("stateCode", "")),
        "state_name": row.get("stateNameEnglish", "").strip(),
    }


class VillageService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = VillageRepository(db)

    async def seed_from_csv(self, content: bytes) -> VillageSeedResult:
        reader = csv.DictReader(io.StringIO(content.decode("utf-8")))
        total = 0
        inserted = 0
        batch: list[dict] = []

        for raw in reader:
            total += 1
            row = _parse_row(raw)
            if row is None:
                continue
            batch.append(row)

            if len(batch) >= _BATCH_SIZE:
                await self.db.execute(_UPSERT_SQL, batch)
                await self.db.commit()
                inserted += len(batch)
                batch = []

        if batch:
            await self.db.execute(_UPSERT_SQL, batch)
            await self.db.commit()
            inserted += len(batch)

        logger.info("Village CSV seed complete: %d / %d rows inserted", inserted, total)
        return VillageSeedResult(inserted=inserted, total_rows=total)

    async def search(
        self, *, q: str | None, district: str | None, limit: int
    ) -> list[VillageItem]:
        rows = await self.repo.search(q=q, district=district, limit=limit)
        return [
            VillageItem(
                village_code=r.village_code,
                village_name=r.village_name,
                village_name_local=r.village_name_local,
                subdistrict_name=r.subdistrict_name,
                district_name=r.district_name,
                state_name=r.state_name,
            )
            for r in rows
        ]

    async def districts(self) -> list[str]:
        return await self.repo.districts()
