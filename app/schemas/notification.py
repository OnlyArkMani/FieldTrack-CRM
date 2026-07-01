"""Notification request/response schemas (Pydantic v2).

DESIGN:
- `type` is a free string on the wire (mirrors the DB column — categories grow
  without migrations), but we publish the canonical set as NotificationType for
  clients/scheduler to share one vocabulary. Unknown types still round-trip.
- `data` is the FCM data payload echoed back so the app can deep-link from an
  in-app tap exactly as it would from a push tap (one navigation switch on
  data['type']). It is NOT persisted per-row to keep the hot notifications
  table lean; the in-app list reconstructs intent from `type` + ids it embeds
  in the body's companion fields when needed.
- Listing uses the shared cursor envelope (CursorPage) for one pagination
  contract across the API.
"""
from datetime import datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field


class NotificationType(str, Enum):
    """Canonical trigger vocabulary — shared by scheduler, services, and the
    mobile deep-link switch. Stored as plain strings (see models/misc.py)."""

    ATTENDANCE_REMINDER = "ATTENDANCE_REMINDER"
    END_WORK_REMINDER = "END_WORK_REMINDER"
    GPS_DISABLED = "GPS_DISABLED"
    SYNC_FAILED = "SYNC_FAILED"
    GEOFENCE_ENTER = "GEOFENCE_ENTER"
    GEOFENCE_EXIT = "GEOFENCE_EXIT"
    ADMIN_ANNOUNCEMENT = "ADMIN_ANNOUNCEMENT"
    # CRM manager-facing alerts (scheduler-driven).
    ABSENTEE_ALERT = "ABSENTEE_ALERT"        # exec not checked in by 09:30
    STATIONARY_ALERT = "STATIONARY_ALERT"    # exec not moving 90+ min in field hours
    WEEKLY_REPORT = "WEEKLY_REPORT"          # Monday auto team report ready
    MONTHLY_REPORT = "MONTHLY_REPORT"        # 1st-of-month auto team report ready


class NotificationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    body: str
    type: str
    is_read: bool
    created_at: datetime


class UnreadCountOut(BaseModel):
    unread: int


class MarkReadResult(BaseModel):
    """Returned by the mark-read endpoints. `updated` is how many rows flipped
    (0 on a no-op, e.g. already-read or not-yours) so the client can reconcile
    its optimistic badge without a refetch."""

    updated: int
    unread: int


# ── Admin announcement (admin -> team or all employees) ──────────────────
class AnnouncementIn(BaseModel):
    title: str = Field(min_length=2, max_length=200)
    body: str = Field(min_length=1, max_length=2000)
    # Target: a specific team, or every employee/supervisor when null. Mutually
    # exclusive in practice — team_id null == broadcast.
    team_id: int | None = Field(
        default=None,
        description="Send to this team only; null broadcasts to all field users.",
    )


class AnnouncementResult(BaseModel):
    recipients: int  # in-app notification rows created
    pushed: int  # devices an FCM push was delivered to (best-effort)


# ── Device token registration (mobile -> POST /devices/token) ────────────
class DeviceTokenIn(BaseModel):
    fcm_token: str = Field(min_length=10, max_length=512)
    device_model: str | None = Field(default=None, max_length=120)
    os_version: str | None = Field(default=None, max_length=50)
    app_version: str | None = Field(default=None, max_length=20)


class DeviceTokenOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    fcm_token: str | None
    device_model: str | None
    os_version: str | None
    app_version: str | None
    last_seen: datetime | None
