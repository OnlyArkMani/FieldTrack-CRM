"""Geofence business logic: CRUD + the server-side ENTER/EXIT engine.

WHY SERVER-SIDE: geofence evaluation runs here on each location-batch upload,
NOT on the device. That keeps the (expensive, continuous) point-in-polygon work
off the battery, and makes the boundary logic impossible to spoof from a
modified client — the device only reports raw GPS.

EVENT DETECTION (per the spec):
  inside_now  = geofences containing the new point
  inside_prev = geofences containing the previous point
  ENTER = inside_now - inside_prev
  EXIT  = inside_prev - inside_now
Because `previous` is the user's actual prior ping, a person standing still
inside a zone yields inside_now == inside_prev ⇒ no repeated ENTER spam.
"""
import json
import logging
from datetime import date as date_type
from datetime import datetime, time, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import not_found
from app.models.enums import GeofenceEventType
from app.models.geofence import GeofenceEvent
from app.models.misc import DeviceInfo, Notification
from app.models.user import Team, User
from app.repositories.geofence_repository import (
    GeofenceRepository,
    build_polygon_wkt,
)
from app.schemas.geofence import (
    EmployeeVisitOut,
    GeofenceCreate,
    GeofenceDetailOut,
    GeofenceEventOut,
    GeofenceOut,
    GeofenceUpdate,
    PresenceOut,
)
from app.services.fcm_service import FCMService

logger = logging.getLogger("fieldtrack.geofence")


def _day_bounds(day: date_type) -> tuple[datetime, datetime]:
    start = datetime.combine(day, time.min, tzinfo=timezone.utc)
    end = datetime.combine(day, time.max, tzinfo=timezone.utc)
    return start, end


def _outer_ring(geojson_str: str) -> list[list[float]]:
    """Extract the outer ring [[lng,lat], ...] from a PostGIS GeoJSON string."""
    try:
        gj = json.loads(geojson_str)
        if gj.get("type") == "Polygon":
            return gj["coordinates"][0]
    except (ValueError, KeyError, IndexError):
        pass
    return []


class GeofenceService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = GeofenceRepository(db)

    def _to_out(self, row: dict) -> GeofenceOut:
        area = row.get("area_sq_meters")
        return GeofenceOut(
            id=row["id"],
            name=row["name"],
            description=row["description"],
            shape_type=row.get("shape_type") or "POLYGON",
            coordinates=_outer_ring(row["geojson"]),
            center_lat=row.get("center_lat"),
            center_lng=row.get("center_lng"),
            radius_meters=row.get("radius_meters"),
            area_sq_meters=round(float(area), 2) if area is not None else None,
            is_active=row["is_active"],
            created_at=row["created_at"],
        )

    # ── CRUD ──────────────────────────────────────────────────────────────
    async def create(
        self, payload: GeofenceCreate, *, actor: User
    ) -> GeofenceDetailOut:
        if payload.shape_type == "CIRCLE":
            gid = await self.create_circle_geofence(
                name=payload.name,
                description=payload.description,
                center_lat=payload.center_lat,
                center_lng=payload.center_lng,
                radius_meters=payload.radius_meters,
                created_by=actor.id,
            )
        else:
            gid = await self.create_polygon_geofence(
                name=payload.name,
                description=payload.description,
                coordinates=payload.coordinates,
                created_by=actor.id,
            )
        return await self.get_detail(gid)

    async def create_circle_geofence(
        self,
        *,
        name: str,
        description: str | None,
        center_lat: float,
        center_lng: float,
        radius_meters: float,
        created_by: int | None,
    ) -> int:
        """Store center/radius + a 64-point ST_Buffer polygon in `zone`."""
        gid = await self.repo.create_circle(
            name=name,
            description=description,
            center_lat=center_lat,
            center_lng=center_lng,
            radius_meters=radius_meters,
            created_by=created_by,
        )
        await self.db.commit()
        return gid

    async def create_polygon_geofence(
        self,
        *,
        name: str,
        description: str | None,
        coordinates: list[list[float]],
        created_by: int | None,
    ) -> int:
        wkt = build_polygon_wkt(coordinates)
        gf = self.repo.create(
            name=name, description=description, wkt=wkt, created_by=created_by
        )
        await self.db.flush()
        gid = gf.id
        await self.db.commit()
        return gid

    async def list_active(self) -> list[GeofenceOut]:
        return [self._to_out(r) for r in await self.repo.list_active()]

    async def get_detail(self, geofence_id: int) -> GeofenceDetailOut:
        row = await self.repo.get_with_geojson(geofence_id)
        if row is None or not row["is_active"]:
            raise not_found("Geofence not found")
        events = await self.repo.recent_events(geofence_id)
        base = self._to_out(row)
        return GeofenceDetailOut(
            **base.model_dump(),
            recent_events=[GeofenceEventOut(**e) for e in events],
        )

    async def update(
        self, geofence_id: int, payload: GeofenceUpdate, *, actor: User
    ) -> GeofenceDetailOut:
        gf = await self.repo.get(geofence_id)
        if gf is None or not gf.is_active:
            raise not_found("Geofence not found")
        fields = payload.model_dump(exclude_unset=True)
        if "name" in fields and fields["name"]:
            gf.name = fields["name"]
        if "description" in fields:
            gf.description = fields["description"]
        if "coordinates" in fields and fields["coordinates"]:
            from geoalchemy2 import WKTElement

            gf.zone = WKTElement(build_polygon_wkt(fields["coordinates"]), srid=4326)
        self.db.add(gf)
        await self.db.commit()
        return await self.get_detail(geofence_id)

    async def soft_delete(self, geofence_id: int, *, actor: User) -> None:
        gf = await self.repo.get(geofence_id)
        if gf is None or not gf.is_active:
            raise not_found("Geofence not found")
        gf.is_active = False
        self.db.add(gf)
        await self.db.commit()

    # ── Presence reads ───────────────────────────────────────────────────
    async def presence(
        self, geofence_id: int, day: date_type
    ) -> list[PresenceOut]:
        if await self.repo.get(geofence_id) is None:
            raise not_found("Geofence not found")
        start, end = _day_bounds(day)
        rows = await self.repo.presence(geofence_id, start, end)
        return [
            PresenceOut(
                user_id=r["user_id"],
                employee_name=r["employee_name"],
                entered_at=r["entered_at"],
                exited_at=r["exited_at"],
                duration_minutes=(
                    round(r["duration_minutes"], 1)
                    if r["duration_minutes"] is not None
                    else None
                ),
            )
            for r in rows
        ]

    async def employee_today(
        self, user_id: int, day: date_type
    ) -> list[EmployeeVisitOut]:
        start, end = _day_bounds(day)
        rows = await self.repo.employee_visits(user_id, start, end)
        return [
            EmployeeVisitOut(
                geofence_id=r["geofence_id"],
                geofence_name=r["geofence_name"],
                visits=int(r["visits"]),
                total_minutes=round(float(r["total_minutes"]), 1),
            )
            for r in rows
        ]

    # ── ENTER/EXIT engine (called from location ingestion) ───────────────
    async def check_geofence_events(
        self,
        user_id: int,
        lat: float,
        lng: float,
        previous_lat: float | None,
        previous_lng: float | None,
    ) -> list[GeofenceEvent]:
        """Detect boundary crossings between the previous and current point and
        record + notify them. Best-effort by contract — callers wrap this so a
        geofence failure never blocks location ingestion."""
        inside_now = await self.repo.geofences_containing(lat, lng)
        inside_prev: set[int] = set()
        if previous_lat is not None and previous_lng is not None:
            inside_prev = await self.repo.geofences_containing(
                previous_lat, previous_lng
            )

        enters = inside_now - inside_prev
        exits = inside_prev - inside_now
        if not enters and not exits:
            return []

        now = datetime.now(timezone.utc)
        created: list[GeofenceEvent] = []
        for gid in enters:
            created.append(
                self._add_event(user_id, gid, GeofenceEventType.ENTER, now, lat, lng)
            )
        for gid in exits:
            created.append(
                self._add_event(user_id, gid, GeofenceEventType.EXIT, now, lat, lng)
            )
        await self.db.flush()
        # Notify (in-app row now; FCM best-effort after).
        await self._notify(user_id, enters, exits)
        return created

    def _add_event(self, user_id, geofence_id, event_type, ts, lat, lng) -> GeofenceEvent:
        ev = GeofenceEvent(
            user_id=user_id,
            geofence_id=geofence_id,
            event_type=event_type,
            timestamp=ts,
            lat=lat,
            lng=lng,
        )
        self.db.add(ev)
        return ev

    async def _notify(self, user_id: int, enters: set[int], exits: set[int]) -> None:
        """Create a notification for the employee's supervisor on each crossing
        and push best-effort. Resolves the supervisor via the employee's team."""
        employee = await self.db.get(User, user_id)
        if employee is None:
            return

        # Geofence names for the message.
        names = await self._geofence_names(enters | exits)
        supervisor_id = await self._supervisor_for(employee)

        messages: list[tuple[str, str, int]] = []  # (title, body, geofence_id)
        for gid in enters:
            messages.append(("Geofence entered", f"{employee.name} entered {names.get(gid, 'a zone')}", gid))
        for gid in exits:
            messages.append(("Geofence exited", f"{employee.name} left {names.get(gid, 'a zone')}", gid))

        if supervisor_id is None:
            return
        for title, body, gid in messages:
            self.db.add(
                Notification(
                    user_id=supervisor_id,
                    title=title,
                    body=body,
                    type="geofence",
                )
            )
        # Push (best-effort, post-flush; notifications row is the source of truth).
        try:
            stmt = select(DeviceInfo.fcm_token).where(
                DeviceInfo.user_id == supervisor_id,
                DeviceInfo.fcm_token.is_not(None),
            )
            tokens = [t for t in (await self.db.execute(stmt)).scalars().all() if t]
            if tokens and messages:
                title, body, _ = messages[0]
                await FCMService().send_to_tokens(
                    tokens, title=title, body=body, data={"type": "geofence"}
                )
        except Exception:  # noqa: BLE001
            logger.exception("geofence FCM notify failed")

    async def _geofence_names(self, ids: set[int]) -> dict[int, str]:
        if not ids:
            return {}
        from app.models.geofence import Geofence

        result = await self.db.execute(
            select(Geofence.id, Geofence.name).where(Geofence.id.in_(ids))
        )
        return {row[0]: row[1] for row in result.all()}

    async def _supervisor_for(self, employee: User) -> int | None:
        if employee.team_id is None:
            return None
        team = await self.db.get(Team, employee.team_id)
        if team is None or team.supervisor_id is None:
            return None
        # Don't notify the employee about themselves if they supervise.
        if team.supervisor_id == employee.id:
            return None
        return team.supervisor_id
