"""Report data access. DB-only — no business rules, no commits, no HTTP.

These are read-heavy range scans. They reuse the existing composite indexes:
attendance (user_id, date) and location_logs (user_id, timestamp).
"""
from datetime import date, datetime, time, timezone

from sqlalchemy import and_, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.attendance import Attendance
from app.models.crm import (
    Farmer,
    Lead,
    LivestockProfile,
    Visit,
    VisitNote,
    VisitOrder,
    VisitPlan,
    VisitPlanItem,
)
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

    async def location_points_in_range(
        self, *, start: date, end: date, user_ids: list[int]
    ) -> dict[tuple[int, date], list[tuple[float, float, datetime]]]:
        """Raw GPS pings bucketed by (user_id, calendar day), each bucket
        ordered by timestamp ascending — ready for consecutive-point Haversine.
        func.date() casts in the session tz (UTC) to line up with attendance.date."""
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

    async def managed_team_ids(self, manager_id: int) -> set[int]:
        stmt = select(Team.id).where(Team.manager_id == manager_id)
        return set((await self.db.execute(stmt)).scalars().all())

    async def get_user(self, user_id: int) -> User | None:
        return await self.db.get(User, user_id)

    # ── Per-employee CRM detail (EMPLOYEE_CONSOLIDATED) ──────────────────────
    @staticmethod
    def _utc_bounds(start: date, end: date) -> tuple[datetime, datetime]:
        return (
            datetime.combine(start, time.min, tzinfo=timezone.utc),
            datetime.combine(end, time.max, tzinfo=timezone.utc),
        )

    async def employee_visits_in_range(
        self, *, user_id: int, start: date, end: date
    ) -> list[tuple[Visit, str | None, str | None, str | None, str | None]]:
        """This employee's visits in [start, end] (by check-in), each paired with
        the FPO/farmer name, customer_type, and meeting-notes remarks (highlights/concerns)
        captured on the guided visit-notes form, if any. Ordered oldest-first."""
        lo, hi = self._utc_bounds(start, end)
        stmt = (
            select(
                Visit,
                Farmer.name,
                Farmer.customer_type,
                VisitNote.meeting_highlights,
                VisitNote.farmer_concerns,
            )
            .join(Farmer, Farmer.id == Visit.farmer_id, isouter=True)
            .outerjoin(VisitNote, VisitNote.visit_id == Visit.id)
            .where(
                Visit.employee_id == user_id,
                Visit.check_in_at >= lo,
                Visit.check_in_at <= hi,
            )
            .order_by(Visit.check_in_at.asc())
        )
        result = await self.db.execute(stmt)
        return [(r[0], r[1], r[2], r[3], r[4]) for r in result.all()]

    async def employee_visits_planned_count_in_range(
        self, *, user_id: int, start: date, end: date
    ) -> int:
        """Count of VisitPlanItem rows under this employee's plans in
        [start, end] (by plan_date) — same source as the daily DSR's
        visits_planned and the crm-performance endpoint's visits_planned."""
        stmt = (
            select(func.count(VisitPlanItem.id))
            .join(VisitPlan, VisitPlan.id == VisitPlanItem.plan_id)
            .where(
                VisitPlan.employee_id == user_id,
                VisitPlan.plan_date >= start,
                VisitPlan.plan_date <= end,
            )
        )
        result = await self.db.execute(stmt)
        return result.scalar_one() or 0

    async def employee_vet_requests_by_status_in_range(
        self, *, user_id: int, start: date, end: date
    ) -> dict[str, int]:
        """Vet requests raised by this employee in [start, end] (by
        check_in_at), grouped by vet_status (checklist A8). Not gated on
        check_out_at — vet_required is set during the visit, independent of
        completion."""
        lo, hi = self._utc_bounds(start, end)
        stmt = (
            select(Visit.vet_status, func.count(Visit.id))
            .where(
                Visit.employee_id == user_id,
                Visit.vet_required.is_(True),
                Visit.check_in_at >= lo,
                Visit.check_in_at <= hi,
            )
            .group_by(Visit.vet_status)
        )
        result = await self.db.execute(stmt)
        return {(s or "REQUESTED"): c for s, c in result.all()}

    async def employee_orders_in_range(
        self, *, user_id: int, start: date, end: date
    ) -> list[tuple[VisitOrder, str | None]]:
        """This employee's captured orders in [start, end] (by created_at)."""
        lo, hi = self._utc_bounds(start, end)
        stmt = (
            select(VisitOrder, Farmer.name)
            .join(Farmer, Farmer.id == VisitOrder.farmer_id, isouter=True)
            .where(
                VisitOrder.employee_id == user_id,
                VisitOrder.created_at >= lo,
                VisitOrder.created_at <= hi,
            )
            .order_by(VisitOrder.created_at.asc())
        )
        result = await self.db.execute(stmt)
        return [(r[0], r[1]) for r in result.all()]

    async def employee_leads_in_range(
        self, *, user_id: int, start: date, end: date
    ) -> list[tuple[Lead, str | None]]:
        """Lead status changes this employee recorded in [start, end]."""
        lo, hi = self._utc_bounds(start, end)
        stmt = (
            select(Lead, Farmer.name)
            .join(Farmer, Farmer.id == Lead.farmer_id, isouter=True)
            .where(
                Lead.employee_id == user_id,
                Lead.created_at >= lo,
                Lead.created_at <= hi,
            )
            .order_by(Lead.created_at.asc())
        )
        result = await self.db.execute(stmt)
        return [(r[0], r[1]) for r in result.all()]

    # ── Per-farmer history (FARMER_EXPORT) ──────────────────────────────────
    async def get_farmer(self, farmer_id: int) -> Farmer | None:
        return await self.db.get(Farmer, farmer_id)

    async def farmer_visits(
        self, farmer_id: int
    ) -> list[tuple[Visit, str | None]]:
        """Every visit to this FPO/farmer, each paired with the employee name.
        Newest-first."""
        stmt = (
            select(Visit, User.name)
            .join(User, User.id == Visit.employee_id, isouter=True)
            .where(Visit.farmer_id == farmer_id)
            .order_by(Visit.check_in_at.desc().nullslast(), Visit.id.desc())
        )
        result = await self.db.execute(stmt)
        return [(r[0], r[1]) for r in result.all()]

    async def farmer_orders(
        self, farmer_id: int
    ) -> list[tuple[VisitOrder, str | None]]:
        stmt = (
            select(VisitOrder, User.name)
            .join(User, User.id == VisitOrder.employee_id, isouter=True)
            .where(VisitOrder.farmer_id == farmer_id)
            .order_by(VisitOrder.created_at.desc(), VisitOrder.id.desc())
        )
        result = await self.db.execute(stmt)
        return [(r[0], r[1]) for r in result.all()]

    async def farmer_livestock(self, farmer_id: int) -> list[LivestockProfile]:
        stmt = (
            select(LivestockProfile)
            .where(LivestockProfile.farmer_id == farmer_id)
            .order_by(
                LivestockProfile.recorded_at.desc(), LivestockProfile.id.desc()
            )
        )
        return list((await self.db.execute(stmt)).scalars().all())

    async def farmer_leads(
        self, farmer_id: int
    ) -> list[tuple[Lead, str | None]]:
        stmt = (
            select(Lead, User.name)
            .join(User, User.id == Lead.employee_id, isouter=True)
            .where(Lead.farmer_id == farmer_id)
            .order_by(Lead.created_at.desc(), Lead.id.desc())
        )
        result = await self.db.execute(stmt)
        return [(r[0], r[1]) for r in result.all()]
