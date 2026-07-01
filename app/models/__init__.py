"""Import every model so Base.metadata is complete for Alembic autogenerate."""
from app.models.base import Base
from app.models.enums import (
    AttendanceStatus,
    GeofenceEventType,
    SessionType,
    SyncQueueStatus,
    SyncStatus,
    UserRole,
)
from app.models.user import Team, User
from app.models.attendance import Attendance, AttendanceSession
from app.models.location import LocationLog
from app.models.geofence import Geofence, GeofenceEvent
from app.models.misc import (
    AuditLog,
    DeviceInfo,
    Notification,
    Setting,
    SyncQueue,
)
from app.models.crm import (
    DailyReport,
    Farmer,
    FollowUp,
    GpsConfig,
    Lead,
    LivestockProfile,
    Visit,
    VisitNote,
    VisitOrder,
    VisitPhoto,
    VisitPlan,
    VisitPlanItem,
)

__all__ = [
    "Base",
    "User",
    "Team",
    "Attendance",
    "AttendanceSession",
    "LocationLog",
    "Geofence",
    "GeofenceEvent",
    "Notification",
    "SyncQueue",
    "DeviceInfo",
    "AuditLog",
    "Setting",
    "UserRole",
    "AttendanceStatus",
    "SessionType",
    "SyncStatus",
    "SyncQueueStatus",
    "GeofenceEventType",
    # CRM extension (migration 0005)
    "Farmer",
    "VisitPlan",
    "VisitPlanItem",
    "Visit",
    "VisitNote",
    "VisitPhoto",
    "LivestockProfile",
    "VisitOrder",
    "Lead",
    "FollowUp",
    "DailyReport",
    "GpsConfig",
]
