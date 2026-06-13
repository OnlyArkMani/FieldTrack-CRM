"""Employee business logic. Routers stay thin; this layer owns transactions,
Redis enrichment, and side effects (welcome push).

LIVE STATUS DERIVATION (Redis, read-time, never persisted) — single source:
  location key  fieldtrack:location:{id}  HASH {..., recorded_at}
  state key     fieldtrack:attendance:state:{id}  HASH {state, ...}

  live_status:
    - location key MISSING        -> OFFLINE   (TTL-expired = 2 missed cycles;
                                                 see REDIS_KEYS.md §1)
    - recorded_at older than 5min  -> IDLE      (present but stale-ish)
    - fresh (<5min) and moving     -> ACTIVE    (speed >= 0.5 m/s)
    - fresh (<5min) and stationary -> IDLE
  current_state (from state hash, normalized to the API's 4-value union):
    STARTED|RESUMED -> "STARTED"; ON_BREAK -> "ON_BREAK"; ENDED -> "ENDED";
    missing/unknown -> "NULL".
"""
import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import bad_request, conflict, not_found
from app.core.redis import Keys, get_redis
from app.core.security import hash_password
from app.models.enums import AttendanceStatus
from app.models.misc import DeviceInfo, Notification
from app.models.user import User
from app.repositories.employee_repository import EmployeeRepository
from app.schemas.common import CursorPage, decode_cursor, encode_cursor
from app.schemas.employee import (
    AttendanceDayOut,
    AttendanceSummaryOut,
    EmployeeCreate,
    EmployeeDetailOut,
    EmployeeOut,
    EmployeeStatusUpdate,
    EmployeeUpdate,
    GpsFlagPoint,
    GpsIntegrityOut,
    LiveStatus,
    LocationHistoryOut,
    LocationPointOut,
    TeamRef,
)
from app.services.fcm_service import FCMService

logger = logging.getLogger("fieldtrack.employee")

ACTIVE_WINDOW_SECONDS = 5 * 60  # fresh ping threshold
MOVING_SPEED_MPS = 0.5  # >= this => "moving" => ACTIVE
LOCATION_HISTORY_CAP = 2000
GPS_INTEGRITY_WINDOW_DAYS = 7  # mock-GPS lookback window
GPS_FLAG_POINTS_CAP = 200  # max flagged points returned in the timeline


class EmployeeService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = EmployeeRepository(db)
        self.redis = get_redis()
        self.settings = get_settings()

    # ── List ──────────────────────────────────────────────────────────────
    async def list_employees(
        self,
        *,
        cursor: str | None,
        limit: int,
        team_id: int | None,
        status: str | None,
        search: str | None,
    ) -> CursorPage[EmployeeOut]:
        is_active = self._parse_status_filter(status)
        rows, total = await self.repo.list_employees(
            cursor_id=decode_cursor(cursor),
            limit=limit,
            team_id=team_id,
            is_active=is_active,
            search=search,
        )
        has_more = len(rows) > limit
        page = rows[:limit]
        next_cursor = encode_cursor(page[-1].id) if has_more and page else None

        live_map = await self._live_status_batch([u.id for u in page])
        # One query flags everyone on the page who spoofed GPS since midnight
        # UTC (warning dot on the admin list).
        midnight = datetime.now(timezone.utc).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        flagged_today = await self.repo.mock_gps_user_ids_since(midnight)
        items = []
        for u in page:
            row = EmployeeOut.model_validate(u)
            row.live = live_map.get(u.id)
            row.mock_gps_today = u.id in flagged_today
            items.append(row)
        return CursorPage[EmployeeOut](
            items=items,
            next_cursor=next_cursor,
            total=total,
            has_more=has_more,
        )

    @staticmethod
    def _parse_status_filter(status: str | None) -> bool | None:
        if status is None:
            return None
        s = status.strip().lower()
        if s in {"active", "true", "1"}:
            return True
        if s in {"inactive", "false", "0"}:
            return False
        raise bad_request("status must be 'active' or 'inactive'")

    # ── Detail (with live status) ────────────────────────────────────────
    async def get_detail(self, user_id: int) -> EmployeeDetailOut:
        user = await self.repo.get_with_team(user_id)
        if user is None:
            raise not_found("Employee not found")
        live = await self._live_status(user_id)
        # exclude "live" — it's re-supplied as a required kwarg below; leaving
        # it in the dump would collide with the explicit live= argument.
        data = EmployeeOut.model_validate(user).model_dump(exclude={"live"})
        return EmployeeDetailOut(
            **data,
            team=TeamRef.model_validate(user.team) if user.team else None,
            live=live,
        )

    async def _live_status(self, user_id: int) -> LiveStatus:
        loc = await self.redis.hgetall(Keys.location(user_id))
        state_hash = await self.redis.hgetall(Keys.attendance_state(user_id))
        return self._derive_live(loc, state_hash)

    async def _live_status_batch(
        self, user_ids: list[int]
    ) -> dict[int, LiveStatus]:
        """One round trip for the whole page: pipeline 2 HGETALLs per user.

        At a 100-page that's 200 cheap reads in a single pipeline — far better
        than N detail-style sequential reads, and the list screen needs a dot
        for every row."""
        if not user_ids:
            return {}
        pipe = self.redis.pipeline()
        for uid in user_ids:
            pipe.hgetall(Keys.location(uid))
            pipe.hgetall(Keys.attendance_state(uid))
        results = await pipe.execute()
        out: dict[int, LiveStatus] = {}
        for i, uid in enumerate(user_ids):
            loc = results[i * 2] or {}
            state_hash = results[i * 2 + 1] or {}
            out[uid] = self._derive_live(loc, state_hash)
        return out

    def _derive_live(
        self, loc: dict[str, Any], state_hash: dict[str, Any]
    ) -> LiveStatus:
        current_state = self._normalize_state(state_hash.get("state"))

        if not loc:
            return LiveStatus(
                live_status="OFFLINE", last_seen=None, current_state=current_state
            )

        last_seen = self._parse_dt(loc.get("recorded_at"))
        battery = self._parse_int(loc.get("battery_level"))
        is_mock = str(loc.get("is_mock_gps", "")).lower() in {"1", "true"}

        live_value = "IDLE"
        if last_seen is not None:
            age = (datetime.now(timezone.utc) - last_seen).total_seconds()
            if age <= ACTIVE_WINDOW_SECONDS:
                speed = self._parse_float(loc.get("speed")) or 0.0
                live_value = "ACTIVE" if speed >= MOVING_SPEED_MPS else "IDLE"
            else:
                live_value = "IDLE"

        return LiveStatus(
            live_status=live_value,  # type: ignore[arg-type]
            last_seen=last_seen,
            current_state=current_state,
            battery_level=battery,
            is_mock_gps=is_mock,
        )

    @staticmethod
    def _normalize_state(raw: str | None) -> str:
        return {
            "STARTED": "STARTED",
            "RESUMED": "STARTED",
            "ON_BREAK": "ON_BREAK",
            "ENDED": "ENDED",
        }.get((raw or "").upper(), "NULL")

    @staticmethod
    def _parse_dt(value: str | None) -> datetime | None:
        if not value:
            return None
        try:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
        except ValueError:
            return None

    @staticmethod
    def _parse_int(value: Any) -> int | None:
        try:
            return int(value) if value not in (None, "") else None
        except (ValueError, TypeError):
            return None

    @staticmethod
    def _parse_float(value: Any) -> float | None:
        try:
            return float(value) if value not in (None, "") else None
        except (ValueError, TypeError):
            return None

    # ── Create (admin) ───────────────────────────────────────────────────
    async def create(
        self, payload: EmployeeCreate, *, actor: User, ip: str | None
    ) -> EmployeeDetailOut:
        email = payload.email.lower()
        if await self.repo.email_exists(email):
            raise conflict("An account with this email already exists")
        if payload.team_id is not None and not await self.repo.active_team_exists(
            payload.team_id
        ):
            raise not_found("Team not found")

        user = User(
            name=payload.name,
            email=email,
            phone=payload.phone,
            password_hash=hash_password(payload.password),
            role=payload.role,
            team_id=payload.team_id,
            profile_photo_url=payload.profile_photo_url,
            is_active=True,
        )
        self.repo.add(user)
        await self.db.flush()  # assign user.id before audit/notification

        self.repo.add_audit_log(
            user_id=actor.id,
            action="EMPLOYEE_CREATED",
            entity_id=user.id,
            ip_address=ip,
            metadata={"role": payload.role.value, "email": email},
        )
        # In-app welcome notification (source of truth; push is the nudge).
        self.db.add(
            Notification(
                user_id=user.id,
                title="Welcome to FieldTrack",
                body=f"Hi {user.name}, your account is ready. Log in to get started.",
                type="welcome",
            )
        )
        await self.db.commit()

        await self._send_welcome_push(user)  # best-effort, post-commit
        return await self.get_detail(user.id)

    async def _send_welcome_push(self, user: User) -> None:
        """Push to any already-registered devices (a freshly created employee
        usually has none yet — the push lands on next device registration via
        the in-app notification regardless)."""
        try:
            stmt = select(DeviceInfo.fcm_token).where(
                DeviceInfo.user_id == user.id, DeviceInfo.fcm_token.is_not(None)
            )
            tokens = [t for t in (await self.db.execute(stmt)).scalars().all() if t]
            await FCMService().send_to_tokens(
                tokens,
                title="Welcome to FieldTrack",
                body=f"Hi {user.name}, your account is ready.",
                data={"type": "welcome"},
            )
        except Exception:  # noqa: BLE001 — never let push break create
            logger.exception("welcome push failed for user %s", user.id)

    # ── Update profile ───────────────────────────────────────────────────
    async def update(
        self, user_id: int, payload: EmployeeUpdate, *, actor: User, ip: str | None
    ) -> EmployeeDetailOut:
        user = await self.repo.get_by_id(user_id)
        if user is None:
            raise not_found("Employee not found")

        fields = payload.model_dump(exclude_unset=True)
        if "email" in fields and fields["email"]:
            new_email = fields["email"].lower()
            if new_email != user.email and await self.repo.email_exists(
                new_email, exclude_id=user_id
            ):
                raise conflict("An account with this email already exists")
            user.email = new_email
        if "team_id" in fields:
            tid = fields["team_id"]
            if tid is not None and not await self.repo.active_team_exists(tid):
                raise not_found("Team not found")
            user.team_id = tid
        for key in ("name", "phone", "role", "profile_photo_url"):
            if key in fields:
                setattr(user, key, fields[key])

        self.repo.add(user)
        self.repo.add_audit_log(
            user_id=actor.id,
            action="EMPLOYEE_UPDATED",
            entity_id=user.id,
            ip_address=ip,
            metadata={"fields": sorted(fields.keys())},
        )
        await self.db.commit()
        return await self.get_detail(user.id)

    # ── Activate / deactivate (admin) ────────────────────────────────────
    async def set_status(
        self,
        user_id: int,
        payload: EmployeeStatusUpdate,
        *,
        actor: User,
        ip: str | None,
    ) -> EmployeeDetailOut:
        user = await self.repo.get_by_id(user_id)
        if user is None:
            raise not_found("Employee not found")
        if user.id == actor.id and not payload.is_active:
            raise bad_request("You cannot deactivate your own account")

        user.is_active = payload.is_active
        self.repo.add(user)
        # Deactivation kills the device session immediately (token blacklist is
        # per-jti; the refresh fingerprint is the session kill-switch).
        if not payload.is_active:
            await self.redis.delete(Keys.refresh_token(user.id))
        self.repo.add_audit_log(
            user_id=actor.id,
            action="EMPLOYEE_ACTIVATED" if payload.is_active else "EMPLOYEE_DEACTIVATED",
            entity_id=user.id,
            ip_address=ip,
        )
        await self.db.commit()
        return await self.get_detail(user.id)

    # ── Attendance summary (monthly) ─────────────────────────────────────
    async def attendance_summary(
        self, user_id: int, *, year: int, month: int
    ) -> AttendanceSummaryOut:
        if not 1 <= month <= 12:
            raise bad_request("month must be 1-12")
        if await self.repo.get_by_id(user_id) is None:
            raise not_found("Employee not found")

        records = await self.repo.attendance_for_month(user_id, year, month)
        present = half = absent = 0
        total_minutes = 0
        total_distance = 0.0
        for r in records:
            if r.status == AttendanceStatus.PRESENT:
                present += 1
            elif r.status == AttendanceStatus.HALF_DAY:
                half += 1
            elif r.status == AttendanceStatus.ABSENT:
                absent += 1
            total_minutes += r.total_duration_minutes
            total_distance += r.total_distance_meters

        recorded = len(records)
        return AttendanceSummaryOut(
            user_id=user_id,
            year=year,
            month=month,
            days_present=present,
            days_half=half,
            days_absent=absent,
            days_recorded=recorded,
            total_work_minutes=total_minutes,
            total_distance_meters=round(total_distance, 2),
            avg_work_minutes=round(total_minutes / recorded) if recorded else 0,
            days=[AttendanceDayOut.model_validate(r) for r in records],
        )

    # ── Location history (date-filtered) ─────────────────────────────────
    async def location_history(
        self, user_id: int, *, date_from, date_to, limit: int
    ) -> LocationHistoryOut:
        if date_from > date_to:
            raise bad_request("date_from must be on or before date_to")
        if await self.repo.get_by_id(user_id) is None:
            raise not_found("Employee not found")

        capped = min(limit, LOCATION_HISTORY_CAP)
        rows = await self.repo.location_history(
            user_id, date_from=date_from, date_to=date_to, limit=capped
        )
        truncated = len(rows) > capped
        points = rows[:capped]
        return LocationHistoryOut(
            user_id=user_id,
            date_from=date_from,
            date_to=date_to,
            count=len(points),
            truncated=truncated,
            points=[LocationPointOut.model_validate(p) for p in points],
        )

    # ── Mock GPS integrity (admin web — anti-gaming) ─────────────────────
    async def gps_integrity(self, user_id: int) -> GpsIntegrityOut:
        """7-day mock-GPS picture for one employee: total detections, whether
        flagged today, and the (capped) flagged-point timeline.

        EMPLOYEE-INVISIBLE: this is supervisor/admin-only data; nothing here is
        ever exposed to the employee's own app (intentional anti-gaming
        design)."""
        if await self.repo.get_by_id(user_id) is None:
            raise not_found("Employee not found")

        now = datetime.now(timezone.utc)
        since = now - timedelta(days=GPS_INTEGRITY_WINDOW_DAYS)
        midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)

        detections = await self.repo.mock_gps_count(user_id, since=since)
        points = await self.repo.mock_gps_points(
            user_id, since=since, limit=GPS_FLAG_POINTS_CAP
        )
        # Newest points come first; if any is from today the badge lights up —
        # no extra query needed unless there were zero detections.
        flagged_today = bool(points) and points[0].timestamp >= midnight
        return GpsIntegrityOut(
            user_id=user_id,
            window_days=GPS_INTEGRITY_WINDOW_DAYS,
            detections=detections,
            flagged_today=flagged_today,
            points=[GpsFlagPoint.model_validate(p) for p in points],
        )
