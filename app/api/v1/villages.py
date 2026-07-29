"""Village lookup router.

POST /villages/seed        — admin: upload LGD CSV to seed/refresh the villages table
GET  /villages/districts   — all authenticated users: district dropdown
GET  /villages             — all authenticated users: search by name / district
"""
from typing import Annotated

from fastapi import APIRouter, Depends, File, Query, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_current_admin, get_db
from app.models.user import User
from app.schemas.village import VillageItem, VillageSeedResult
from app.services.village_service import VillageService

router = APIRouter(prefix="/villages", tags=["villages"])


@router.post("/seed", response_model=VillageSeedResult)
async def seed_villages(
    _admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
    file: UploadFile = File(..., description="LGD villages CSV export from data.gov.in"),
) -> VillageSeedResult:
    """Upload the LGD villages CSV and upsert all rows into the villages table.
    Safe to re-run — existing rows are skipped (ON CONFLICT DO NOTHING)."""
    content = await file.read()
    return await VillageService(db).seed_from_csv(content)


@router.get("/districts", response_model=list[str])
async def list_districts(
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[str]:
    """All distinct district names — for district dropdown."""
    return await VillageService(db).districts()


@router.get("", response_model=list[VillageItem])
async def search_villages(
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
    q: str | None = Query(default=None, min_length=2, description="Village name search"),
    district: str | None = Query(default=None, description="Filter by district name"),
    limit: int = Query(default=20, ge=1, le=100),
) -> list[VillageItem]:
    """Search villages by name with optional district filter."""
    return await VillageService(db).search(q=q, district=district, limit=limit)
