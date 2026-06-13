"""Location queries. DB access only — no business rules, no commits."""
from datetime import date as date_type
from datetime import datetime, time, timezone
from typing import Any

from sqlalchemy import insert, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.location import LocationLog
from app.models.user import Team, User


class LocationRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    async def bulk_insert(self, mappings: list[dict[str, Any]]) -> None:
        """executemany-style bulk insert — the SQLAlchemy 2.0/async
        equivalent of the legacy (sync-only) bulk_insert_mappings."""
        if not mappings:
            return
        await self.db.execute(insert(LocationLog), mappings)

    async def latest_for_user(self, user_id: int) -> LocationLog | None:
        result = await self.db.execute(
            select(LocationLog)
            .where(LocationLog.user_id == user_id)
            .order_by(LocationLog.timestamp.desc())
            .limit(1)
        )
        return result.scalar_one_or_none()

    async def history(
        self,
        user_id: int,
        day: date_type,
        start: time | None = None,
        end: time | None = None,
        limit: int = 5000,
    ) -> list[LocationLog]:
        """Ordered points for route rendering. Window is [day+start, day+end]
        in UTC; defaults to the full day. Capped — a full worst-case day is
        ~480 points, so 5000 is pure safety."""
        day_start = datetime.combine(day, start or time.min, tzinfo=timezone.utc)
        day_end = datetime.combine(day, end or time.max, tzinfo=timezone.utc)
        result = await self.db.execute(
            select(LocationLog)
            .where(
                LocationLog.user_id == user_id,
                LocationLog.timestamp >= day_start,
                LocationLog.timestamp <= day_end,
            )
            .order_by(LocationLog.timestamp.asc())
            .limit(limit)
        )
        return list(result.scalars().all())

    async def supervised_team_ids(self, supervisor_id: int) -> set[int]:
        result = await self.db.execute(
            select(Team.id).where(Team.supervisor_id == supervisor_id)
        )
        return set(result.scalars().all())

    async def members_of_teams(self, team_ids: set[int]) -> list[User]:
        if not team_ids:
            return []
        result = await self.db.execute(
            select(User)
            .where(User.team_id.in_(team_ids))
            .order_by(User.name.asc())
        )
        return list(result.scalars().all())

    async def get_user(self, user_id: int) -> User | None:
        return await self.db.get(User, user_id)

    async def active_field_employees(self) -> list[User]:
        """Active non-admin users — the population the admin live map tracks
        (admins are web-only and never carry a tracked device)."""
        from app.models.enums import UserRole

        result = await self.db.execute(
            select(User)
            .where(User.is_active.is_(True), User.role != UserRole.ADMIN)
            .order_by(User.name.asc())
        )
        return list(result.scalars().all())

    async def simplified_route(
        self,
        user_id: int,
        day_start: datetime,
        day_end: datetime,
        tolerance: float,
    ) -> list[tuple[float, float]]:
        """Server-side Douglas–Peucker via PostGIS.

        location_logs stores plain lat/lng (no geometry column — see the model
        notes), so we build a LINESTRING on the fly, ST_Simplify it (tolerance
        in degrees, SRID 4326), then dump the surviving vertices back to
        ordered (lat, lng) pairs. Called only when the raw track is large
        enough to be worth thinning."""
        sql = text(
            """
            WITH pts AS (
                SELECT lat, lng, timestamp
                FROM location_logs
                WHERE user_id = :uid
                  AND timestamp >= :start AND timestamp <= :end
            ),
            line AS (
                SELECT ST_MakeLine(
                    ST_SetSRID(ST_MakePoint(lng, lat), 4326) ORDER BY timestamp
                ) AS geom
                FROM pts
            ),
            simp AS (
                SELECT ST_Simplify(geom, :tol) AS geom FROM line
            )
            SELECT ST_Y(d.geom) AS lat, ST_X(d.geom) AS lng
            FROM simp, LATERAL ST_DumpPoints(simp.geom) AS d
            ORDER BY d.path[1]
            """
        )
        result = await self.db.execute(
            sql,
            {"uid": user_id, "start": day_start, "end": day_end, "tol": tolerance},
        )
        return [(row.lat, row.lng) for row in result.all()]
