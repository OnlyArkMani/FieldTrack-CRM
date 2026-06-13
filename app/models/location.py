"""Location logs — by far the highest-volume table.

VOLUME MATH (why these choices):
  100 employees x ~10h day x worst-case every 2 min = ~30k rows/day,
  ~11M rows/year. Fine for Postgres on this VPS with the right indexes;
  partitioning is NOT needed at this scale (revisit at >50M rows).

DECISIONS:
- BigInteger PK — this table WILL exceed int32 over years.
- Composite index (user_id, timestamp DESC): every hot query is
  "recent track for user X" — one index serves dashboard + history + reports.
- PARTIAL index on sync_status WHERE PENDING: the sync worker only ever scans
  pending rows; a full index on a column that's 99% 'SYNCED' wastes space.
- lat/lng floats (not PostGIS point): we never run spatial JOINs on raw pings
  server-side at write time; geofence checks compute against geofences.zone
  using ST_Contains(zone, ST_MakePoint(lng, lat)) which needs no geometry
  column here. Avoids geometry write overhead on the hottest table.
- is_mock_gps flag only (project decision: flag, no hard block).
"""
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    func,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base
from app.models.enums import SyncStatus


class LocationLog(Base):
    __tablename__ = "location_logs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    lat: Mapped[float] = mapped_column(Float, nullable=False)
    lng: Mapped[float] = mapped_column(Float, nullable=False)
    timestamp: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )  # device-side capture time, NOT server arrival time (offline sync!)
    accuracy: Mapped[float | None] = mapped_column(Float)  # meters
    speed: Mapped[float | None] = mapped_column(Float)  # m/s
    battery_level: Mapped[int | None] = mapped_column(Integer)  # 0-100
    is_mock_gps: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    sync_status: Mapped[SyncStatus] = mapped_column(
        Enum(SyncStatus, name="sync_status"),
        nullable=False,
        default=SyncStatus.SYNCED,  # rows arriving via API are already synced
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )  # server arrival time — (timestamp vs created_at) delta = sync lag

    __table_args__ = (
        # No DESC needed: Postgres walks btree indexes backwards for free.
        Index("ix_location_logs_user_ts", "user_id", "timestamp"),
        Index(
            "ix_location_logs_pending",
            "sync_status",
            postgresql_where=text("sync_status = 'PENDING'"),
        ),
    )
