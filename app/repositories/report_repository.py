"""Report data access. DB-only — no business rules, no commits, no HTTP.

These are read-heavy range scans. They reuse the existing composite indexes:
attendance (user_id, date) and location_logs (user_id, timestamp).
"""
from datetime import date, datetime, time, timezone

from sqlalchemy import and_, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.attendance import Attendance
from app.models.crm import Visit, VisitOrder
from app.models.enums import AttendanceStatus, GeofenceEventType, UserRole
from app.models.geofence import Geofence, GeofenceEvent
from app.models.location import LocationLog
from app.models.user import Team, User


class ReportRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    async def attendance_in_range(
        self,
        *,
        start: date,
        end: date,
        team_id: int | None = None,
        user_id: int | None = None,
        status: AttendanceStatus | None = None,
    ) -> list[tuple[Attendance, User]]:
        """Every attendance row in [start, end] matching the filters, paired
        with its employee and sessions eager-loaded. Ordered by employee name
        then date so the export reads top-to-bottom per person.

        Admins are excluded (web-only, never tracked) unless a specific user_id
        is requested."""
        conditions = [Attendance.date >= start, Attendance.date <= end]
        if user_id is not None:
            conditions.append(Attendance.user_id == user_id)
        else:
            conditions.append(User.role != UserRole.ADMIN)
        if team_id is not None:
            conditions.append(User.team_id == team_id)
        if status is not None:
            conditions.append(Attendance.status == status)

        stmt = (
            select(Attendance, User)
            .join(User, User.id == Attendance.user_id)
            .where(and_(*conditions))
            .order_by(User.name.asc(), Attendance.date.asc())
            .options(selectinload(Attendance.sessions))
        )
        result = await self.db.execute(stmt)
        return [(row[0], row[1]) for row in result.all()]

    async def mock_counts_in_range(
        self, *, start: date, end: date, user_ids: list[int]
    ) -> dict[tuple[int, date], int]:
        """Flagged (is_mock_gps) ping counts grouped by (user_id, calendar
        day) over the window. func.date() casts the timestamptz in the session
        tz (UTC on the server) so it lines up with attendance.date."""
        if not user_ids:
            return {}
        day = func.date(LocationLog.timestamp)
        stmt = (
            select(LocationLog.user_id, day.label("day"), func.count(LocationLog.id))
            .where(
                LocationLog.user_id.in_(user_ids),
                LocationLog.is_mock_gps.is_(True),
                day >= start,
                day <= end,
            )
            .group_by(LocationLog.user_id, day)
        )
        result = await self.db.execute(stmt)
        out: dict[tuple[int, date], int] = {}
        for uid, d, count in result.all():
            # func.date may yield a date or an ISO string depending on driver;
            # normalize to date.
            dd = d if isinstance(d, date) else date.fromisoformat(str(d))
            out[(int(uid), dd)] = int(count)
        return out

    async def location_points_in_range(
        self, *, start: date, end: date, user_ids: list[int]
    ) -> dict[tuple[int, date], list[tuple[float, float, datetime]]]:
        """Raw GPS pings bucketed by (user_id, calendar day), each bucket
        ordered by timestamp ascending — ready for consecutive-point Haversine.
        func.date() casts in the session tz (UTC) to line up with attendance.date,
        same as mock_counts_in_range."""
        if not user_ids:
            return {}
        day = func.date(LocationLog.timestamp)
        stmt = (
            select(
                LocationLog.user_id,
                day.label("day"),
                LocationLog.lat,
                LocationLog.lng,
                LocationLog.timestamp,
            )
            .where(
                LocationLog.user_id.in_(user_ids),
                day >= start,
                day <= end,
            )
            .order_by(LocationLog.user_id, LocationLog.timestamp.asc())
        )
        result = await self.db.execute(stmt)
        out: dict[tuple[int, date], list[tuple[float, float, datetime]]] = {}
        for uid, d, lat, lng, ts in result.all():
            dd = d if isinstance(d, date) else date.fromisoformat(str(d))
            out.setdefault((int(uid), dd), []).append((float(lat), float(lng), ts))
        return out

    async def geofence_events_in_range(
        self, *, start: date, end: date, user_ids: list[int]
    ) -> dict[tuple[int, date], list[tuple[int, str, str, datetime]]]:
        """ENTER/EXIT events bucketed by (user_id, calendar day), ordered by
        timestamp. Each entry is (geofence_id, zone_name, event_type, timestamp)
        — geofence_id lets us pair an ENTER with the next EXIT for the SAME zone
        even when an employee is inside two overlapping zones at once."""
        if not user_ids:
            return {}
        day = func.date(GeofenceEvent.timestamp)
        stmt = (
            select(
                GeofenceEvent.user_id,
                day.label("day"),
                GeofenceEvent.geofence_id,
                Geofence.name,
                GeofenceEvent.event_type,
                GeofenceEvent.timestamp,
            )
            .join(Geofence, Geofence.id == GeofenceEvent.geofence_id)
            .where(
                GeofenceEvent.user_id.in_(user_ids),
                day >= start,
                day <= end,
            )
            .order_by(GeofenceEvent.user_id, GeofenceEvent.timestamp.asc())
        )
        result = await self.db.execute(stmt)
        out: dict[tuple[int, date], list[tuple[int, str, str, datetime]]] = {}
        for uid, d, gid, name, etype, ts in result.all():
            dd = d if isinstance(d, date) else date.fromisoformat(str(d))
            etype_val = etype.value if isinstance(etype, GeofenceEventType) else str(etype)
            out.setdefault((int(uid), dd), []).append(
                (int(gid), str(name), etype_val, ts)
            )
        return out

    async def assigned_geofences_for_team(
        self, team_id: int
    ) -> list[dict]:
        """Active geofences a team is responsible for: every UNIVERSAL zone plus
        the TEAM zones assigned to this team. Used by the compliance report to
        know the full set of zones each employee is expected to visit."""
        rows = await self.db.execute(
            text(
                """
                SELECT id, name, scope
                FROM geofences
                WHERE is_active = true
                  AND (
                        scope = 'UNIVERSAL'
                        OR (scope = 'TEAM' AND team_id = :team_id)
                      )
                ORDER BY name ASC
                """
            ),
            {"team_id": team_id},
        )
        return [dict(r) for r in rows.mappings().all()]

    async def crm_metrics_in_range(
        self, *, start: date, end: date, team_id: int
    ) -> dict[int, dict[str, int]]:
        """Per-employee CRM activity for a team over [start, end] (inclusive):
        completed visits, orders captured, and total bags. Keyed by employee_id.
        Timestamps are UTC (Visit.check_in_at / VisitOrder.created_at); the day
        window is [start 00:00, end+1 00:00) in UTC, matching the report bounds.

        Used by the weekly/monthly auto-report to show visits/orders/conversion
        alongside attendance."""
        day_start = datetime.combine(start, time.min, tzinfo=timezone.utc)
        day_end = datetime.combine(end, time.max, tzinfo=timezone.utc)
        out: dict[int, dict[str, int]] = {}

        visits_q = await self.db.execute(
            select(Visit.employee_id, func.count(Visit.id))
            .join(User, User.id == Visit.employee_id)
            .where(
                User.team_id == team_id,
                Visit.status == "COMPLETED",
                Visit.check_in_at >= day_start,
                Visit.check_in_at <= day_end,
            )
            .group_by(Visit.employee_id)
        )
        for uid, cnt in visits_q.all():
            if uid is not None:
                out.setdefault(int(uid), {"visits": 0, "orders": 0, "bags": 0})["visits"] = int(cnt)

        orders_q = await self.db.execute(
            select(
                VisitOrder.employee_id,
                func.count(VisitOrder.id),
                func.coalesce(func.sum(VisitOrder.bags_count), 0),
            )
            .join(User, User.id == VisitOrder.employee_id)
            .where(
                User.team_id == team_id,
                VisitOrder.created_at >= day_start,
                VisitOrder.created_at <= day_end,
            )
            .group_by(VisitOrder.employee_id)
        )
        for uid, cnt, bags in orders_q.all():
            if uid is not None:
                row = out.setdefault(int(uid), {"visits": 0, "orders": 0, "bags": 0})
                row["orders"] = int(cnt)
                row["bags"] = int(bags or 0)
        return out

    async def active_team_ids(self) -> list[int]:
        """All active teams — the audience for the weekly/monthly auto-report
        scheduler jobs."""
        stmt = select(Team.id).where(Team.is_active.is_(True)).order_by(Team.id.asc())
        return [int(i) for i in (await self.db.execute(stmt)).scalars().all()]

    async def get_team(self, team_id: int) -> Team | None:
        return await self.db.get(Team, team_id)

    async def team_members(self, team_id: int) -> list[User]:
        """Active non-admin members of a team, ordered by name."""
        stmt = (
            select(User)
            .where(
                User.team_id == team_id,
                User.is_active.is_(True),
                User.role != UserRole.ADMIN,
            )
            .order_by(User.name.asc())
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def supervised_team_ids(self, supervisor_id: int) -> set[int]:
        stmt = select(Team.id).where(Team.supervisor_id == supervisor_id)
        return set((await self.db.execute(stmt)).scalars().all())

    async def get_user(self, user_id: int) -> User | None:
        return await self.db.get(User, user_id)
