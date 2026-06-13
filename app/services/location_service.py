"""Location ingestion + retrieval.

INGESTION PIPELINE (POST /location/batch):
1. Per-record semantic check (future timestamps from broken device clocks
   -> counted `failed`, never block the batch).
2. Redis dedup: SET NX on sha256(user_id:timestamp), TTL 6h. Devices retry
   batches after lost ACKs; the same fix must not insert twice. 6h covers
   any realistic retry window (the device queue itself drains far faster).
   SET NX is atomic -> race-free across both uvicorn workers.
3. Bulk insert survivors into location_logs.
4. Refresh the live-location hash (fieldtrack:location:{user_id}, TTL 2h)
   with the NEWEST record by device timestamp — batches arrive oldest-first,
   but we don't trust ordering.

ACCESS RULES (live/history): admin -> anyone; supervisor -> members of teams
they supervise (+ themselves); employee -> self only.
"""
import hashlib
import logging
import math
from datetime import date as date_type
from datetime import datetime, time, timedelta, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import ApiError, forbidden
from app.core.redis import Keys, get_redis
from app.models.enums import SyncStatus, UserRole
from app.models.user import User
from app.repositories.location_repository import LocationRepository
from app.schemas.location import (
    HistoryPoint,
    LivePoint,
    LocationBatchIn,
    LocationBatchResult,
    LocationHistoryOut,
    RoutePointOut,
    RouteReplayOut,
    RouteSessionOut,
    TeamLivePoint,
)


# ── Trail-replay helpers (module-level, pure) ─────────────────────────────
_SESSION_STATE = {
    "START": "STARTED",
    "RESUME": "RESUMED",
    "BREAK": "ON_BREAK",
    "END": None,  # tracking has stopped — points after END have no state
}


def _haversine_total(coords: list[tuple[float, float]]) -> float:
    """Sum of great-circle distances (metres) across an ordered (lat,lng) list."""
    if len(coords) < 2:
        return 0.0
    r = 6371000.0
    total = 0.0
    for i in range(1, len(coords)):
        lat1, lng1 = coords[i - 1]
        lat2, lng2 = coords[i]
        p1, p2 = math.radians(lat1), math.radians(lat2)
        dphi = math.radians(lat2 - lat1)
        dl = math.radians(lng2 - lng1)
        a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
        total += 2 * r * math.asin(min(1.0, math.sqrt(a)))
    return total


def _state_transitions(sessions) -> list[tuple[datetime, str | None]]:
    out: list[tuple[datetime, str | None]] = []
    for s in sorted(sessions, key=lambda s: s.timestamp):
        t = s.type.value if hasattr(s.type, "value") else str(s.type)
        out.append((s.timestamp, _SESSION_STATE.get(t)))
    return out


def _state_at(transitions: list[tuple[datetime, str | None]], ts: datetime) -> str | None:
    state: str | None = None
    for t, st in transitions:
        if t <= ts:
            state = st
        else:
            break
    return state


def _perp_dist(p, a, b) -> float:
    """Perpendicular distance from point p to segment a-b in degree space
    (lat=y, lng=x). Planar approximation — fine for route simplification."""
    py, px = p[0], p[1]
    ay, ax = a[0], a[1]
    by, bx = b[0], b[1]
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    projx, projy = ax + t * dx, ay + t * dy
    return math.hypot(px - projx, py - projy)


def _douglas_peucker(coords: list[tuple[float, float]], eps: float) -> list[bool]:
    """Iterative Douglas–Peucker. Returns a keep-mask over `coords`."""
    n = len(coords)
    keep = [False] * n
    if n == 0:
        return keep
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        s, e = stack.pop()
        if e <= s + 1:
            continue
        dmax, idx = 0.0, s
        for i in range(s + 1, e):
            d = _perp_dist(coords[i], coords[s], coords[e])
            if d > dmax:
                dmax, idx = d, i
        if dmax > eps:
            keep[idx] = True
            stack.append((s, idx))
            stack.append((idx, e))
    return keep

DEDUP_TTL_SECONDS = 6 * 3600
LIVE_TTL_SECONDS = 2 * 3600
FUTURE_TOLERANCE = timedelta(minutes=5)  # allow small clock skew

# Route rendering
ROUTE_SIMPLIFY_THRESHOLD = 500  # raw points above which we thin server-side
ROUTE_SIMPLIFY_TOLERANCE = 0.00007  # ~7m in degrees @ equator (Douglas–Peucker)

# Live-status derivation (mirrors the dashboard's rules)
LIVE_ACTIVE_WINDOW = timedelta(minutes=5)
LIVE_MOVING_SPEED_MPS = 0.5


def _dedup_hash(user_id: int, timestamp: datetime) -> str:
    raw = f"{user_id}:{timestamp.astimezone(timezone.utc).isoformat()}"
    return hashlib.sha256(raw.encode()).hexdigest()


class LocationService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = LocationRepository(db)
        self.redis = get_redis()

    # ── Ingestion ──────────────────────────────────────────────────────────
    async def ingest_batch(
        self, user: User, batch: LocationBatchIn
    ) -> LocationBatchResult:
        now = datetime.now(timezone.utc)
        processed = skipped = failed = 0
        mappings: list[dict] = []
        newest = None  # newest accepted record, for the live cache

        for record in batch.records:
            ts = record.timestamp
            if ts.tzinfo is None:  # naive timestamps are treated as UTC
                ts = ts.replace(tzinfo=timezone.utc)

            if ts > now + FUTURE_TOLERANCE:
                failed += 1
                continue

            # Atomic claim: False => another request already processed this fix.
            claimed = await self.redis.set(
                Keys.sync_processed(_dedup_hash(user.id, ts)),
                "1",
                nx=True,
                ex=DEDUP_TTL_SECONDS,
            )
            if not claimed:
                skipped += 1
                continue

            mappings.append({
                "user_id": user.id,
                "lat": record.lat,
                "lng": record.lng,
                "timestamp": ts,
                "accuracy": record.accuracy,
                "speed": record.speed,
                "battery_level": record.battery_level,
                "is_mock_gps": record.is_mock_gps,
                "sync_status": SyncStatus.SYNCED,
            })
            processed += 1
            if newest is None or ts > newest["timestamp"]:
                newest = mappings[-1]

        # Capture the last ping BEFORE this batch — it's the "previous point"
        # for the geofence ENTER/EXIT check against the batch's newest point.
        prev = await self.repo.latest_for_user(user.id) if newest is not None else None

        if mappings:
            await self.repo.bulk_insert(mappings)
            await self.db.commit()

        if newest is not None:
            await self._update_live_cache(user.id, newest)
            await self._check_geofences(user.id, newest, prev)

        return LocationBatchResult(
            processed=processed, skipped=skipped, failed=failed
        )

    async def _check_geofences(self, user_id: int, newest: dict, prev) -> None:
        """Server-side geofence evaluation (best-effort: never blocks ingestion).
        Compares the batch's newest point with the user's prior ping; the
        GeofenceService records ENTER/EXIT events and notifies supervisors."""
        from app.services.geofence_service import GeofenceService

        try:
            events = await GeofenceService(self.db).check_geofence_events(
                user_id,
                newest["lat"],
                newest["lng"],
                prev.lat if prev is not None else None,
                prev.lng if prev is not None else None,
            )
            if events:
                await self.db.commit()
        except Exception:  # noqa: BLE001 — geofencing must not break location sync
            await self.db.rollback()
            logging.getLogger("fieldtrack.location").exception(
                "geofence check failed for user %s", user_id
            )

    async def _update_live_cache(self, user_id: int, rec: dict) -> None:
        key = Keys.location(user_id)
        await self.redis.hset(key, mapping={
            "lat": rec["lat"],
            "lng": rec["lng"],
            "accuracy": rec["accuracy"] if rec["accuracy"] is not None else "",
            "speed": rec["speed"] if rec["speed"] is not None else "",
            "battery_level": rec["battery_level"]
            if rec["battery_level"] is not None else "",
            "is_mock_gps": int(rec["is_mock_gps"]),
            "recorded_at": rec["timestamp"].isoformat(),
        })
        await self.redis.expire(key, LIVE_TTL_SECONDS)
        # Notify the admin WebSocket fan-out that this user's position changed.
        # Fire-and-forget pub/sub; a missed publish just means the WS falls back
        # to its 15s periodic snapshot.
        await self.redis.publish(Keys.LOCATION_UPDATES_CHANNEL, str(user_id))

    # ── Access control ─────────────────────────────────────────────────────
    async def _assert_can_view(self, viewer: User, target_id: int) -> None:
        if viewer.id == target_id or viewer.role == UserRole.ADMIN:
            return
        if viewer.role == UserRole.SUPERVISOR:
            target = await self.repo.get_user(target_id)
            if target is None:
                raise ApiError(404, "User not found", "NOT_FOUND")
            team_ids = await self.repo.supervised_team_ids(viewer.id)
            if target.team_id in team_ids:
                return
            raise forbidden("This employee is not on your team")
        raise forbidden("You can only view your own location data")

    # ── Live ───────────────────────────────────────────────────────────────
    async def live(self, viewer: User, user_id: int) -> LivePoint | None:
        await self._assert_can_view(viewer, user_id)

        cached = await self.redis.hgetall(Keys.location(user_id))
        if cached:
            return LivePoint(
                user_id=user_id,
                lat=float(cached["lat"]),
                lng=float(cached["lng"]),
                accuracy=float(cached["accuracy"]) if cached.get("accuracy") else None,
                speed=float(cached["speed"]) if cached.get("speed") else None,
                battery_level=int(cached["battery_level"])
                if cached.get("battery_level") else None,
                is_mock_gps=cached.get("is_mock_gps") == "1",
                recorded_at=datetime.fromisoformat(cached["recorded_at"]),
                source="live",
            )

        latest = await self.repo.latest_for_user(user_id)
        if latest is None:
            return None
        return LivePoint(
            user_id=user_id,
            lat=latest.lat,
            lng=latest.lng,
            accuracy=latest.accuracy,
            speed=latest.speed,
            battery_level=latest.battery_level,
            is_mock_gps=latest.is_mock_gps,
            recorded_at=latest.timestamp,
            source="db",
        )

    # ── History ────────────────────────────────────────────────────────────
    async def history(
        self,
        viewer: User,
        user_id: int,
        day: date_type,
        start: time | None,
        end: time | None,
    ) -> LocationHistoryOut:
        await self._assert_can_view(viewer, user_id)
        points = await self.repo.history(user_id, day, start, end)
        return LocationHistoryOut(
            user_id=user_id,
            date=day.isoformat(),
            start_time=start,
            end_time=end,
            count=len(points),
            points=[HistoryPoint.model_validate(p) for p in points],
        )

    # ── Route / trail replay (enriched points + sessions + stats) ───────────
    async def route(
        self, viewer: User, user_id: int, day: date_type
    ) -> RouteReplayOut:
        await self._assert_can_view(viewer, user_id)

        raw = await self.repo.history(user_id, day)  # full rows, timestamp ASC

        # Attendance sessions + duration for the day (state markers + active time).
        attendance = await self._attendance_for_day(user_id, day)
        sessions = list(attendance.sessions) if attendance else []
        total_duration = attendance.total_duration_minutes if attendance else 0

        # Total distance: haversine across the RAW track (before simplification).
        total_distance = _haversine_total([(p.lat, p.lng) for p in raw])

        # attendance_state per point, from the session transition timeline.
        transitions = _state_transitions(sessions)

        # Simplify if large, but ALWAYS keep mock-GPS points (the warnings).
        simplified = False
        kept = raw
        if len(raw) > ROUTE_SIMPLIFY_THRESHOLD:
            simplified = True
            coords = [(p.lat, p.lng) for p in raw]
            keep_mask = _douglas_peucker(coords, ROUTE_SIMPLIFY_TOLERANCE)
            kept = [
                p
                for i, p in enumerate(raw)
                if keep_mask[i] or p.is_mock_gps
            ]

        points = [
            RoutePointOut(
                lat=p.lat,
                lng=p.lng,
                timestamp=p.timestamp,
                speed=p.speed,
                accuracy=p.accuracy,
                is_mock_gps=p.is_mock_gps,
                attendance_state=_state_at(transitions, p.timestamp),
            )
            for p in kept
        ]
        session_out = [
            RouteSessionOut(
                type=s.type.value if hasattr(s.type, "value") else str(s.type),
                lat=s.lat,
                lng=s.lng,
                timestamp=s.timestamp,
            )
            for s in sorted(sessions, key=lambda s: s.timestamp)
        ]

        return RouteReplayOut(
            user_id=user_id,
            date=day.isoformat(),
            total_distance_meters=round(total_distance, 1),
            total_duration_minutes=total_duration,
            simplified=simplified,
            points=points,
            sessions=session_out,
        )

    async def _attendance_for_day(self, user_id: int, day: date_type):
        from sqlalchemy import select
        from sqlalchemy.orm import selectinload

        from app.models.attendance import Attendance

        stmt = (
            select(Attendance)
            .where(Attendance.user_id == user_id, Attendance.date == day)
            .options(selectinload(Attendance.sessions))
        )
        return (await self.db.execute(stmt)).scalar_one_or_none()

    # ── Team live (supervisor map) ──────────────────────────────────────────
    async def team_live(self, viewer: User) -> list[TeamLivePoint]:
        team_ids = await self.repo.supervised_team_ids(viewer.id)
        members = await self.repo.members_of_teams(team_ids)
        return await self._live_points_for(members)

    # ── All live (admin dashboard / WebSocket) ──────────────────────────────
    async def all_live(self) -> list[TeamLivePoint]:
        """Live data for every active field employee — the admin map/WS feed."""
        members = await self.repo.active_field_employees()
        return await self._live_points_for(members)

    async def _live_points_for(self, members: list[User]) -> list[TeamLivePoint]:
        if not members:
            return []

        # One pipeline: location + attendance-state hash for every member.
        pipe = self.redis.pipeline()
        for m in members:
            pipe.hgetall(Keys.location(m.id))
            pipe.hgetall(Keys.attendance_state(m.id))
        results = await pipe.execute()

        out: list[TeamLivePoint] = []
        for i, m in enumerate(members):
            loc = results[i * 2] or {}
            state_hash = results[i * 2 + 1] or {}
            attendance_state = (state_hash.get("state") or "NULL").upper()

            if loc:
                status, last_seen = self._derive_live_status(loc)
                out.append(
                    TeamLivePoint(
                        user_id=m.id,
                        name=m.name,
                        photo_url=m.profile_photo_url,
                        lat=float(loc["lat"]),
                        lng=float(loc["lng"]),
                        last_seen=last_seen,
                        status=status,
                        attendance_state=attendance_state,
                        battery_level=int(loc["battery_level"])
                        if loc.get("battery_level") else None,
                        source="live",
                    )
                )
                continue

            # Redis miss → last DB record (offline, but show last known spot).
            latest = await self.repo.latest_for_user(m.id)
            out.append(
                TeamLivePoint(
                    user_id=m.id,
                    name=m.name,
                    photo_url=m.profile_photo_url,
                    lat=latest.lat if latest else None,
                    lng=latest.lng if latest else None,
                    last_seen=latest.timestamp if latest else None,
                    status="OFFLINE",
                    attendance_state=attendance_state,
                    battery_level=latest.battery_level if latest else None,
                    source="db" if latest else "none",
                )
            )
        return out

    @staticmethod
    def _derive_live_status(loc: dict) -> tuple[str, datetime | None]:
        """(status, last_seen) from a live-location hash. Fresh + moving =>
        ACTIVE; fresh + stationary => IDLE; stale (Redis still warm) => IDLE."""
        recorded_at = None
        raw = loc.get("recorded_at")
        if raw:
            try:
                recorded_at = datetime.fromisoformat(raw)
                if recorded_at.tzinfo is None:
                    recorded_at = recorded_at.replace(tzinfo=timezone.utc)
            except ValueError:
                recorded_at = None

        if recorded_at is None:
            return "IDLE", None
        age = datetime.now(timezone.utc) - recorded_at
        if age <= LIVE_ACTIVE_WINDOW:
            try:
                speed = float(loc.get("speed") or 0.0)
            except ValueError:
                speed = 0.0
            return ("ACTIVE" if speed >= LIVE_MOVING_SPEED_MPS else "IDLE"), recorded_at
        return "IDLE", recorded_at
