"""Sync API schemas.

The device queues attendance taps locally while offline and replays them here
when back online. This endpoint is the attendance counterpart to
/location/batch — same contract shape ({processed, skipped, errors}) so the
client's sync engine treats both uniformly.

IDEMPOTENCY: replays are expected (app crashed mid-sync, lost ACK). A session
is a duplicate if one already exists with the same (attendance_id, type) within
30 seconds — see SyncService. Duplicates are SKIPPED, never errored, so the
device can safely mark them done.
"""
from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, Field

from app.models.enums import SessionType


class SessionSyncRecord(BaseModel):
    # Nullable: a tap made entirely offline may not yet know its server-side
    # attendance_id. The service resolves/creates the day's attendance then.
    attendance_id: int | None = None
    type: SessionType
    timestamp: datetime
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)
    notes: str | None = Field(default=None, max_length=500)


class AttendanceSessionSyncIn(BaseModel):
    sessions: Annotated[
        list[SessionSyncRecord], Field(min_length=1, max_length=200)
    ]


class SyncError(BaseModel):
    index: int  # position in the submitted `sessions` array
    reason: str


class AttendanceSessionSyncResult(BaseModel):
    processed: int  # newly inserted
    skipped: int  # duplicates (already on the server)
    errors: list[SyncError]  # records the device should surface / not retry


class ServerStatusOut(BaseModel):
    """Clock-drift probe. The client compares server_time to its own clock;
    a delta > 5 min means the device clock is wrong (which would corrupt
    every offline timestamp) and the user should be warned."""

    server_time: datetime
    server_timezone: str = "UTC"
