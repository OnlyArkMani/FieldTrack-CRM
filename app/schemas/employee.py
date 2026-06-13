"""Employee request/response schemas (Pydantic v2).

DESIGN:
- An "employee" is a row in `users` (any role). These schemas are the
  admin/supervisor-facing CRUD surface over that table — distinct from
  auth's UserOut (which is the self-view returned at login).
- EmployeeDetailOut embeds a LiveStatus block enriched from Redis at read
  time (never persisted) — see employee_service for the derivation rules.
- Email lowercased at the boundary (one normalization point, mirrors auth).
- Status filter on the list maps to is_active (active|inactive), NOT live
  status — live status is ephemeral and not queryable in Postgres.
"""
from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from app.models.enums import UserRole


# ── Live status (Redis-derived, read-time only) ──────────────────────────
LiveStatusValue = Literal["ACTIVE", "IDLE", "OFFLINE"]
CurrentState = Literal["STARTED", "ON_BREAK", "ENDED", "NULL"]


class LiveStatus(BaseModel):
    live_status: LiveStatusValue
    last_seen: datetime | None  # recorded_at of the last accepted ping
    current_state: CurrentState  # attendance state machine position
    battery_level: int | None = None
    is_mock_gps: bool = False


# ── Create / update ──────────────────────────────────────────────────────
class _LowercaseEmailMixin(BaseModel):
    @field_validator("email", mode="after", check_fields=False)
    @classmethod
    def _lower(cls, v: str | None) -> str | None:
        return v.lower() if isinstance(v, str) else v


class EmployeeCreate(_LowercaseEmailMixin):
    name: str = Field(min_length=2, max_length=120)
    email: EmailStr
    phone: str | None = Field(default=None, max_length=20)
    password: str = Field(min_length=8, max_length=128)
    role: UserRole = UserRole.EMPLOYEE
    team_id: int | None = None
    profile_photo_url: str | None = Field(default=None, max_length=500)


class EmployeeUpdate(_LowercaseEmailMixin):
    """All fields optional — PUT here is a partial-friendly profile update;
    only provided keys change. None never blanks a column (use model_fields_set
    in the service to tell 'absent' from 'explicit null')."""

    name: str | None = Field(default=None, min_length=2, max_length=120)
    email: EmailStr | None = None
    phone: str | None = Field(default=None, max_length=20)
    role: UserRole | None = None
    team_id: int | None = None
    profile_photo_url: str | None = Field(default=None, max_length=500)


class EmployeeStatusUpdate(BaseModel):
    is_active: bool


# ── Output ───────────────────────────────────────────────────────────────
class TeamRef(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str


class EmployeeOut(BaseModel):
    """List-row shape. Identity + team + a live block.

    `live` is Redis-derived and OPTIONAL here: the list service fills it via a
    pipeline (cheap at this scale), but it stays nullable so the row schema is
    still valid if enrichment is ever skipped. The detail schema below narrows
    it to required."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    email: str
    phone: str | None
    role: UserRole
    team_id: int | None
    profile_photo_url: str | None
    is_active: bool
    created_at: datetime
    live: LiveStatus | None = None
    # True if this employee has ANY mock-GPS-flagged ping today. Surfaces a
    # warning dot on the admin list (anti-gaming). Filled by a single bulk
    # query in the list service; stays False if enrichment is skipped.
    mock_gps_today: bool = False


class EmployeeDetailOut(EmployeeOut):
    """Detail-screen shape: list fields + team object + (required) live status."""

    team: TeamRef | None = None
    live: LiveStatus


# ── Attendance summary (monthly) ─────────────────────────────────────────
class AttendanceDayOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    date: date
    status: str
    total_duration_minutes: int
    total_distance_meters: float


class AttendanceSummaryOut(BaseModel):
    user_id: int
    year: int
    month: int
    days_present: int
    days_half: int
    days_absent: int
    days_recorded: int  # rows that exist (present + half + explicit absent)
    total_work_minutes: int
    total_distance_meters: float
    avg_work_minutes: int  # over days_recorded, 0 if none
    days: list[AttendanceDayOut]


# ── Location history ─────────────────────────────────────────────────────
class LocationPointOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    lat: float
    lng: float
    timestamp: datetime
    accuracy: float | None
    speed: float | None
    battery_level: int | None
    is_mock_gps: bool


class LocationHistoryOut(BaseModel):
    user_id: int
    date_from: date
    date_to: date
    count: int
    truncated: bool  # True when the cap was hit (client should narrow range)
    points: list[LocationPointOut]


# ── Mock GPS integrity (admin web — anti-gaming) ─────────────────────────
class GpsFlagPoint(BaseModel):
    """One flagged (mock-GPS) location ping for the integrity timeline."""

    model_config = ConfigDict(from_attributes=True)

    lat: float
    lng: float
    timestamp: datetime
    accuracy: float | None
    battery_level: int | None


class GpsIntegrityOut(BaseModel):
    """Mock-GPS picture for one employee over a recent window.

    `flagged_today` drives the employee-list warning badge; `detections` is the
    window total; `points` is the (capped) flagged timeline for the detail
    page. EMPLOYEE-INVISIBLE by design — this endpoint is supervisor/admin
    only; the employee never learns they were flagged (anti-gaming)."""

    user_id: int
    window_days: int
    detections: int
    flagged_today: bool
    points: list[GpsFlagPoint]
