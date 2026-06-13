"""Geofence API schemas (Pydantic v2).

COORDINATE ORDER: [lng, lat] everywhere — matching GeoJSON and PostGIS
ST_MakePoint(x=lng, y=lat). The ring is validated to be a simple closed
polygon; an unclosed ring is auto-closed in the service (last point = first).
"""
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from app.models.enums import GeofenceEventType

# One coordinate pair: exactly [lng, lat].
Coordinate = Annotated[list[float], Field(min_length=2, max_length=2)]

ShapeType = Literal["POLYGON", "CIRCLE"]
CIRCLE_MIN_RADIUS_M = 50.0
CIRCLE_MAX_RADIUS_M = 50000.0


def _validate_ring(coords: list[list[float]]) -> list[list[float]]:
    """Bounds-check vertices and require ≥3 distinct points (a closing
    duplicate doesn't count)."""
    for lng, lat in coords:
        if not (-180 <= lng <= 180) or not (-90 <= lat <= 90):
            raise ValueError("coordinate out of range ([lng,lat])")
    ring = coords[:-1] if coords[0] == coords[-1] else coords
    if len(ring) < 3:
        raise ValueError("a polygon needs at least 3 distinct points")
    return coords


class GeofenceCreate(BaseModel):
    """Create a POLYGON (coordinates) or CIRCLE (center + radius). The shape's
    required fields are enforced by the model validator below."""

    name: str = Field(min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=500)
    shape_type: ShapeType = "POLYGON"

    # POLYGON
    coordinates: list[Coordinate] | None = None
    # CIRCLE
    center_lat: float | None = Field(default=None, ge=-90, le=90)
    center_lng: float | None = Field(default=None, ge=-180, le=180)
    radius_meters: float | None = Field(default=None)

    @model_validator(mode="after")
    def _check_shape(self) -> "GeofenceCreate":
        if self.shape_type == "CIRCLE":
            if (
                self.center_lat is None
                or self.center_lng is None
                or self.radius_meters is None
            ):
                raise ValueError(
                    "CIRCLE requires center_lat, center_lng and radius_meters"
                )
            if not (CIRCLE_MIN_RADIUS_M <= self.radius_meters <= CIRCLE_MAX_RADIUS_M):
                raise ValueError(
                    f"radius_meters must be between {int(CIRCLE_MIN_RADIUS_M)} "
                    f"and {int(CIRCLE_MAX_RADIUS_M)}"
                )
        else:  # POLYGON
            if not self.coordinates or len(self.coordinates) < 3:
                raise ValueError("POLYGON requires at least 3 coordinates")
            _validate_ring(self.coordinates)
        return self


class GeofenceUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=500)
    coordinates: list[Coordinate] | None = Field(default=None, min_length=3)

    @field_validator("coordinates")
    @classmethod
    def _check(cls, coords):
        return None if coords is None else _validate_ring(coords)


class GeofenceEventOut(BaseModel):
    model_config = {"from_attributes": True}

    id: int
    user_id: int
    employee_name: str | None = None
    geofence_id: int
    event_type: GeofenceEventType
    timestamp: datetime
    lat: float
    lng: float


class GeofenceOut(BaseModel):
    id: int
    name: str
    description: str | None
    shape_type: ShapeType
    coordinates: list[list[float]]  # outer ring [[lng,lat], ...] (closed)
    # Circle metadata (null for polygons) — lets the UI draw a true circle.
    center_lat: float | None = None
    center_lng: float | None = None
    radius_meters: float | None = None
    area_sq_meters: float | None = None  # ST_Area(zone::geography)
    is_active: bool
    created_at: datetime


class GeofenceDetailOut(GeofenceOut):
    recent_events: list[GeofenceEventOut] = []


class PresenceOut(BaseModel):
    user_id: int
    employee_name: str | None = None
    entered_at: datetime
    exited_at: datetime | None = None
    duration_minutes: float | None = None  # None => still inside


class EmployeeVisitOut(BaseModel):
    geofence_id: int
    geofence_name: str
    visits: int
    total_minutes: float
