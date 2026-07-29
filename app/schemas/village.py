from pydantic import BaseModel


class VillageItem(BaseModel):
    village_code: int
    village_name: str
    village_name_local: str | None
    subdistrict_name: str | None
    district_name: str
    state_name: str


class VillageSeedResult(BaseModel):
    inserted: int
    total_rows: int


