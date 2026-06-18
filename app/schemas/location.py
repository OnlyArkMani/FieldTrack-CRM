"""Location API schemas.

Validation philosophy: structural validity (ranges, types, batch size) is
enforced here and rejects the whole request with 422; per-record SEMANTIC
problems (e.g. timestamp from the future) are counted as `failed` in the
batch result instead — one bad record from a device with a broken clock must
not block 99 good ones.
"""
from datetime import datetime, time
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field


class LocationRecordIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    timestamp: datetime  # device capture time (UTC ISO8601)
    accuracy: float | None = Field(default=None, ge=0)
    speed: float | None = Field(default=None, ge=0)
    battery_level: int | None = Field(default=None, ge=0, le=100)
    is_mock_gps: bool = False


class LocationBatchIn(BaseModel):
    records: Annotated[list[LocationRecordIn], Field(min_length=1, max_length=100)]


class LocationBatchResult(BaseModel):
    processed: int
    skipped: int  # Redis dedup hits — already seen, safely ignored
    failed: int   # semantically invalid records (e.g. future timestamps)


class LivePoint(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    user_id: int
    lat: float
    lng: float
    accuracy: float | None = None
    speed: float | None = None
    battery_level: int | None = None
    is_mock_gps: bool = False
    recorded_at: datetime
    source: str  # "live" (Redis) | "db" (fallback)


class HistoryPoint(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    lat: float
    lng: float
    timestamp: datetime
    accuracy: float | None = None
    speed: float | None = None
    is_mock_gps: bool = False


class LocationHistoryOut(BaseModel):
    user_id: int
    date: str
    start_time: time | None = None
    end_time: time | None = None
    count: int
    points: list[HistoryPoint]


class LatLng(BaseModel):
    lat: float
    lng: float


class RoutePointsOut(BaseModel):
    """Ordered route for map rendering. `simplified` is True when the raw track
    exceeded the threshold and was run through PostGIS ST_Simplify
    (Douglas–Peucker) to keep the polyline light for low-end devices."""

    user_id: int
    date: str
    count: int
    raw_count: int  # points before simplification
    simplified: bool
    points: list[LatLng]


class RoutePointOut(BaseModel):
    """One enriched point for trail replay."""

    lat: float
    lng: float
    timestamp: datetime
    speed: float | None = None
    accuracy: float | None = None
    is_mock_gps: bool = False
    attendance_state: str | None = None  # STARTED | ON_BREAK | RESUMED | None


class RouteSessionOut(BaseModel):
    """Attendance state-machine marker (START/BREAK/RESUME/END)."""

    type: str
    lat: float | None = None
    lng: float | None = None
    timestamp: datetime


class RouteReplayOut(BaseModel):
    """Full trail-replay payload for a user's day: enriched points + session
    markers + aggregate stats. Points are ordered by timestamp ASC. When the
    raw track exceeds 500 points it's simplified (Douglas–Peucker), but every
    mock-GPS-flagged point is preserved regardless."""

    user_id: int
    date: str
    total_distance_meters: float
    total_duration_minutes: int
    simplified: bool = False
    points: list[RoutePointOut]
    sessions: list[RouteSessionOut]


class DailyDistanceOut(BaseModel):
    """One day's distance + GPS point count — a row in the 30-day trail
    summary. `has_trail` is true when a per-day route replay is available
    (i.e. points > 0) so the UI knows which days are clickable."""

    date: str
    distance_meters: float
    point_count: int
    has_trail: bool


class TrailSummaryOut(BaseModel):
    """30-day (configurable) distance report for one employee. Cheap to
    compute (one grouped SQL query) and cheap to store — it's derived
    on-demand from location_logs, which already retains 90 days."""

    user_id: int
    start_date: str
    end_date: str
    total_distance_meters: float
    days: list[DailyDistanceOut]


class TeamLivePoint(BaseModel):
    """One team member's live position for the supervisor map. status is the
    derived ACTIVE/IDLE/OFFLINE; attendance_state is the state-machine label."""

    user_id: int
    name: str
    photo_url: str | None = None
    lat: float | None = None
    lng: float | None = None
    last_seen: datetime | None = None
    status: str  # ACTIVE | IDLE | OFFLINE
    attendance_state: str  # STARTED | ON_BREAK | RESUMED | ENDED | NULL
    battery_level: int | None = None
    source: str  # "live" (Redis) | "db" | "none"
