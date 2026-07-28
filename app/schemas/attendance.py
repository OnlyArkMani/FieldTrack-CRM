"""Attendance request/response schemas (Pydantic v2).

STATE MACHINE (mirrored on the device):
  NULL → START → (BREAK ⇄ RESUME)* → END
  current_state is the live position: STARTED | ON_BREAK | RESUMED | ENDED |
  NULL. It's derived (Redis fast-path, DB fallback) — never a stored column.

GPS: lat/lng are required on every transition (the product captures location
at each tap). Bounds-validated here so a garbage fix is a 422, not a row.

work_summary: required ONLY on END, 10–500 chars (enforced on the END body).
"""
from datetime import date as date_type
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models.enums import AttendanceStatus, SessionType

CurrentState = Literal["STARTED", "ON_BREAK", "RESUMED", "ENDED", "RE_CHECKED_IN", "ON_LEAVE", "NULL"]


# ── Requests ─────────────────────────────────────────────────────────────
class GpsPoint(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class AttendanceActionRequest(GpsPoint):
    """START / BREAK / RESUME body. Optional free-text note (not the work
    summary — that's END-only)."""

    notes: str | None = Field(default=None, max_length=500)


class AttendanceEndRequest(GpsPoint):
    # work_summary is optional so the auto-logout path can omit it;
    # the service auto-fills "Auto clock-out on logout." in that case.
    # When a value IS supplied (manual End tap), min_length=10 still applies.
    work_summary: str | None = Field(default=None, max_length=500)


class LeaveRequest(BaseModel):
    """Body for POST /attendance/leave. `date` defaults to today; a future
    date is allowed but a past date is rejected by the service. If planned
    visits already exist for that date, the service rejects the request
    until they're rescheduled or skipped."""

    date: date_type | None = None


class AttendanceStatusOverride(BaseModel):
    """Admin override of the day's classification."""

    status: AttendanceStatus
    reason: str | None = Field(default=None, max_length=500)


class ManualSessionRequest(BaseModel):
    """Admin-inserted session (e.g. employee forgot to END). reason is
    mandatory and recorded in the session note + audit log."""

    type: SessionType
    timestamp: datetime
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)
    reason: str = Field(min_length=3, max_length=500)


# ── Responses ────────────────────────────────────────────────────────────
class SessionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    type: SessionType
    timestamp: datetime
    lat: float | None
    lng: float | None
    notes: str | None


class AttendanceEmployeeRef(BaseModel):
    """Identity block for team/all listings (None on personal endpoints)."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    profile_photo_url: str | None
    role: str

    @model_validator(mode="after")
    def format_profile_photo(self) -> "AttendanceEmployeeRef":
        if self.profile_photo_url and not self.profile_photo_url.startswith(
            ("http://", "https://", "/")
        ):
            self.profile_photo_url = f"/api/v1/employees/{self.id}/profile-photo"
        return self


class AttendanceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    user_id: int
    date: date_type
    status: AttendanceStatus
    total_duration_minutes: int
    total_distance_meters: float
    work_summary: str | None
    current_state: CurrentState
    sessions: list[SessionOut]
    employee: AttendanceEmployeeRef | None = None


class TodayAttendanceOut(BaseModel):
    """Today's attendance, or a NULL-state shell when nothing's been logged
    yet — the device always gets a well-formed object to render against."""

    has_attendance: bool
    current_state: CurrentState
    attendance: AttendanceOut | None = None
