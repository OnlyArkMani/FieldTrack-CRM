"""Geofences (PostGIS polygons) + enter/exit events.

DECISIONS:
- zone is GEOMETRY(POLYGON, 4326) — WGS84, matching GPS coordinates directly.
  Geometry (not geography): zones are small (meters–km), planar math is fine
  and significantly faster; ST_Contains works natively on geometry.
- GIST index on zone — mandatory for ST_Contains performance.
- Containment query used by the sync pipeline:
    SELECT id FROM geofences
    WHERE is_active AND ST_Contains(zone, ST_SetSRID(ST_MakePoint(:lng,:lat),4326));
- geofence_events rows are written server-side when consecutive pings cross a
  boundary (state kept in Redis live-location cache, so no rescan needed).
- events.lat/lng recorded so an event remains meaningful if the zone polygon
  is later edited.
"""
from datetime import datetime

from geoalchemy2 import Geometry
from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    String,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base
from app.models.enums import GeofenceEventType


class Geofence(Base):
    __tablename__ = "geofences"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[str | None] = mapped_column(String(500))
    zone = mapped_column(
        Geometry(geometry_type="POLYGON", srid=4326, spatial_index=False),
        nullable=False,
    )  # spatial_index=False: we create the GIST index explicitly below for a stable name
    # Shape metadata. For CIRCLE we ALSO store a 64-point polygon approximation
    # in `zone` so every PostGIS spatial query (ST_Contains, etc.) stays shape-
    # agnostic; center/radius are kept so the UI renders a true circle.
    shape_type: Mapped[str] = mapped_column(
        String(10), nullable=False, default="POLYGON", server_default="POLYGON"
    )
    center_lat: Mapped[float | None] = mapped_column(Float)
    center_lng: Mapped[float | None] = mapped_column(Float)
    radius_meters: Mapped[float | None] = mapped_column(Float)
    created_by: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL")
    )
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        Index("ix_geofences_zone", "zone", postgresql_using="gist"),
    )


class GeofenceEvent(Base):
    __tablename__ = "geofence_events"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    geofence_id: Mapped[int] = mapped_column(
        ForeignKey("geofences.id", ondelete="CASCADE"), nullable=False
    )
    event_type: Mapped[GeofenceEventType] = mapped_column(
        Enum(GeofenceEventType, name="geofence_event_type"), nullable=False
    )
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    lat: Mapped[float] = mapped_column(Float, nullable=False)
    lng: Mapped[float] = mapped_column(Float, nullable=False)

    geofence: Mapped["Geofence"] = relationship()

    __table_args__ = (
        Index("ix_geofence_events_user_ts", "user_id", "timestamp"),
        Index("ix_geofence_events_geofence_id", "geofence_id"),
    )
