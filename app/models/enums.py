"""All enums in one place. Stored as native Postgres ENUM types (validated at
the DB layer, 1-byte storage, readable in psql). Values are UPPERCASE strings
matching what the mobile client sends."""
import enum


class UserRole(str, enum.Enum):
    ADMIN = "ADMIN"
    SUPERVISOR = "SUPERVISOR"
    EMPLOYEE = "EMPLOYEE"


class AttendanceStatus(str, enum.Enum):
    PRESENT = "PRESENT"
    ABSENT = "ABSENT"
    HALF_DAY = "HALF_DAY"


class SessionType(str, enum.Enum):
    START = "START"
    BREAK = "BREAK"
    RESUME = "RESUME"
    END = "END"


class SyncStatus(str, enum.Enum):
    PENDING = "PENDING"
    SYNCED = "SYNCED"
    FAILED = "FAILED"


class GeofenceEventType(str, enum.Enum):
    ENTER = "ENTER"
    EXIT = "EXIT"


class SyncQueueStatus(str, enum.Enum):
    """Server-side sync queue (distinct from per-row SyncStatus on the device)."""

    PENDING = "PENDING"
    PROCESSING = "PROCESSING"
    DONE = "DONE"
    FAILED = "FAILED"
