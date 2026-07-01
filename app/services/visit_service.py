"""Visit execution (CRM Module 3) — the core daily workflow. Routers stay thin;
this layer owns transactions, the distance/warning logic, livestock
denormalization, and the lead/follow-up side effects on completion.

KEY RULES:
- Check-in NEVER blocks. If the employee is >200 m from the farmer's recorded
  location, location_warning is set and warning_required is returned so the app
  collects a remark — but the visit is created regardless. If the farmer has no
  recorded location yet, this check-in seeds it (no distance check).
- Livestock is append-only (new row per visit, history preserved) and also
  denormalizes total_cattle / feed brand / feed price onto the farmer.
- Orders require delivery_date >= today + 7 days (clear 400 otherwise).
- Completion sets a lead row; WARM/COLD require a follow-up date and create a
  follow_up; a linked plan item is marked COMPLETED.
"""
import logging
import math
import os
import uuid
from datetime import date as date_type
from datetime import datetime, timezone

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import bad_request, forbidden, not_found
from app.models.crm import (
    Farmer,
    FollowUp,
    Lead,
    LivestockProfile,
    Visit,
    VisitNote,
    VisitOrder,
    VisitPhoto,
)
from app.models.enums import UserRole
from app.models.user import User
from app.repositories.visit_repository import VisitRepository
from app.schemas.crm import (
    CheckInRequest,
    CheckInResponse,
    LeadResponse,
    LivestockProfileResponse,
    LivestockUpsert,
    OrderCreate,
    VisitCompleteRequest,
    VisitDetailResponse,
    VisitNoteResponse,
    VisitNotesUpsert,
    VisitOrderResponse,
    VisitPhotoResponse,
    VisitResponse,
)

logger = logging.getLogger("fieldtrack.visit")

LOCATION_WARNING_METERS = 200.0
ORDER_MIN_LEAD_DAYS = 7
_EARTH_RADIUS_M = 6371000.0
_ALLOWED_PHOTO_TYPES = {"image/jpeg", "image/png", "image/webp", "image/heic"}
_PHOTO_EXT = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "image/heic": "heic",
}


def _photo_download_url(photo_id: int) -> str:
    """API path the mobile app / dashboard fetches the image bytes from."""
    prefix = get_settings().api_v1_prefix
    return f"{prefix}/visits/photos/{photo_id}/file"


def haversine_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Great-circle distance in metres (no external API)."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lng2 - lng1)
    a = (
        math.sin(dphi / 2) ** 2
        + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    )
    return 2 * _EARTH_RADIUS_M * math.asin(math.sqrt(a))


class VisitService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = VisitRepository(db)

    # ── authz helpers ────────────────────────────────────────────────────
    @staticmethod
    def _is_privileged(user: User) -> bool:
        return user.role in (UserRole.ADMIN, UserRole.SUPERVISOR)

    def _assert_can_visit(self, farmer: Farmer, user: User) -> None:
        if self._is_privileged(user):
            return
        if user.team_id is not None and farmer.team_id == user.team_id:
            return
        if farmer.created_by == user.id:
            return
        raise forbidden("You don't have access to this farmer")

    def _assert_owner(self, visit: Visit, user: User) -> None:
        if self._is_privileged(user):
            return
        if visit.employee_id != user.id:
            raise forbidden("This visit isn't yours")

    async def _load_owned_visit(self, visit_id: int, user: User) -> Visit:
        visit = await self.repo.get_visit(visit_id)
        if visit is None:
            raise not_found("Visit not found")
        self._assert_owner(visit, user)
        return visit

    # ── check-in ─────────────────────────────────────────────────────────
    async def check_in(self, user: User, payload: CheckInRequest) -> CheckInResponse:
        farmer = await self.repo.get_farmer(payload.farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        self._assert_can_visit(farmer, user)

        now = datetime.now(timezone.utc)
        warning = False
        distance: float | None = None

        if farmer.lat is None or farmer.lng is None:
            # First visit seeds the farmer's location; no distance check.
            farmer.lat = payload.lat
            farmer.lng = payload.lng
            self.repo.add(farmer)
            farmer_lat, farmer_lng = payload.lat, payload.lng
        else:
            farmer_lat, farmer_lng = farmer.lat, farmer.lng
            distance = haversine_meters(
                payload.lat, payload.lng, farmer.lat, farmer.lng
            )
            warning = distance > LOCATION_WARNING_METERS

        purpose = None
        plan_item = None
        if payload.plan_item_id is not None:
            plan_item = await self.repo.get_plan_item(payload.plan_item_id)
            if plan_item is not None:
                purpose = plan_item.purpose

        visit = Visit(
            employee_id=user.id,
            farmer_id=farmer.id,
            plan_item_id=payload.plan_item_id,
            check_in_at=now,
            check_in_lat=payload.lat,
            check_in_lng=payload.lng,
            farmer_lat=farmer_lat,
            farmer_lng=farmer_lng,
            distance_at_checkin_meters=distance,
            location_warning=warning,
            purpose=purpose,
            status="CHECKED_IN",
        )
        self.repo.add(visit)
        await self.db.flush()

        if plan_item is not None:
            plan_item.status = "IN_PROGRESS"
            self.repo.add(plan_item)

        await self.db.commit()
        return CheckInResponse(
            visit_id=visit.id,
            location_warning=warning,
            distance_meters=round(distance, 1) if distance is not None else None,
            farmer_name=farmer.name,
            warning_required=warning,
        )

    # ── location remark ──────────────────────────────────────────────────
    async def set_location_remark(
        self, user: User, visit_id: int, remark: str
    ) -> VisitDetailResponse:
        visit = await self._load_owned_visit(visit_id, user)
        if not visit.location_warning:
            raise bad_request("This visit has no location warning to explain")
        visit.location_warning_remark = remark.strip()
        self.repo.add(visit)
        await self.db.commit()
        return await self._build_detail(visit)

    # ── notes (upsert) ───────────────────────────────────────────────────
    async def upsert_notes(
        self, user: User, visit_id: int, payload: VisitNotesUpsert
    ) -> VisitNoteResponse:
        visit = await self._load_owned_visit(visit_id, user)
        note = await self.repo.notes_for(visit.id)
        if note is None:
            note = VisitNote(visit_id=visit.id)
            self.repo.add(note)
        note.meeting_highlights = payload.meeting_highlights
        note.farmer_concerns = payload.farmer_concerns
        note.product_interest = payload.product_interest
        note.step_completed = payload.step_completed
        await self.db.commit()
        await self.db.refresh(note)
        return VisitNoteResponse.model_validate(note)

    # ── livestock (append new row + denormalize farmer) ──────────────────
    async def upsert_livestock(
        self, user: User, visit_id: int, payload: LivestockUpsert
    ) -> LivestockProfileResponse:
        visit = await self._load_owned_visit(visit_id, user)
        profile = LivestockProfile(
            farmer_id=visit.farmer_id,
            visit_id=visit.id,
            **payload.model_dump(),
        )
        self.repo.add(profile)

        farmer = await self.repo.get_farmer(visit.farmer_id)
        if farmer is not None:
            if payload.total_cattle is not None:
                farmer.total_cattle = payload.total_cattle
            if payload.current_brand is not None:
                farmer.current_feed_brand = payload.current_brand
            if payload.current_price_per_bag is not None:
                farmer.current_feed_price_per_bag = payload.current_price_per_bag
            self.repo.add(farmer)

        await self.db.commit()
        await self.db.refresh(profile)
        return LivestockProfileResponse.model_validate(profile)

    # ── order ────────────────────────────────────────────────────────────
    async def create_order(
        self, user: User, visit_id: int, payload: OrderCreate
    ) -> VisitOrderResponse:
        visit = await self._load_owned_visit(visit_id, user)
        min_date = self._today() + _days(ORDER_MIN_LEAD_DAYS)
        if payload.delivery_date < min_date:
            raise bad_request(
                f"Delivery date must be on or after {min_date.isoformat()} "
                f"(today + {ORDER_MIN_LEAD_DAYS} days)"
            )
        order = VisitOrder(
            visit_id=visit.id,
            farmer_id=visit.farmer_id,
            employee_id=user.id,
            bags_count=payload.bags_count,
            delivery_date=payload.delivery_date,
            delivery_address=payload.delivery_address,
            payment_mode=payload.payment_mode,
            special_notes=payload.special_notes,
            status="SUBMITTED",
        )
        self.repo.add(order)
        await self.db.flush()

        # Supervisor awareness: notify the employee's team supervisor(s) that an
        # order was captured. Best-effort — never block or fail the order.
        try:
            if user.team_id is not None:
                from app.services.dsr_service import _supervisor_ids_for_team
                from app.services.notification_service import NotificationService

                farmer = await self.repo.get_farmer(visit.farmer_id)
                farmer_name = farmer.name if farmer else "a farmer"
                sup_ids = await _supervisor_ids_for_team(self.db, user.team_id)
                if sup_ids:
                    notif = NotificationService(self.db)
                    for sup_id in sup_ids:
                        if sup_id == user.id:
                            continue
                        await notif.send_fcm(
                            sup_id,
                            title="Order captured",
                            body=f"{user.full_name} captured an order "
                            f"({payload.bags_count} bags) from {farmer_name}.",
                            type="ORDER_CAPTURED",
                            data={
                                "screen": "farmer",
                                "farmer_id": str(visit.farmer_id),
                            },
                            commit=False,
                        )
        except Exception:  # noqa: BLE001 — notification must never break capture
            logger.exception("ORDER_CAPTURED notification failed")

        await self.db.commit()
        await self.db.refresh(order)
        return VisitOrderResponse.model_validate(order)

    # ── complete ─────────────────────────────────────────────────────────
    async def complete_visit(
        self, user: User, visit_id: int, payload: VisitCompleteRequest
    ) -> VisitDetailResponse:
        visit = await self._load_owned_visit(visit_id, user)
        needs_follow_up = payload.lead_status in ("WARM", "COLD")
        if needs_follow_up and payload.follow_up_date is None:
            raise bad_request(
                "A follow-up date is required for Warm or Cold leads"
            )

        now = datetime.now(timezone.utc)
        visit.status = "COMPLETED"
        visit.check_out_at = now
        self.repo.add(visit)

        self.repo.add(
            Lead(
                farmer_id=visit.farmer_id,
                employee_id=user.id,
                visit_id=visit.id,
                status=payload.lead_status,
            )
        )

        if needs_follow_up:
            self.repo.add(
                FollowUp(
                    farmer_id=visit.farmer_id,
                    employee_id=user.id,
                    visit_id=visit.id,
                    scheduled_date=payload.follow_up_date,
                    scheduled_time=payload.follow_up_time,
                    purpose=payload.follow_up_purpose,
                    status="PENDING",
                )
            )

        if visit.plan_item_id is not None:
            item = await self.repo.get_plan_item(visit.plan_item_id)
            if item is not None:
                item.status = "COMPLETED"
                self.repo.add(item)

        # Touch the farmer so "last updated" reflects this visit.
        farmer = await self.repo.get_farmer(visit.farmer_id)
        if farmer is not None:
            farmer.updated_at = now
            self.repo.add(farmer)

        await self.db.commit()
        await self.db.refresh(visit)
        return await self._build_detail(visit)

    # ── photos (checklist #24) ───────────────────────────────────────────
    async def add_photo(
        self,
        user: User,
        visit_id: int,
        *,
        content: bytes,
        content_type: str | None,
        caption: str | None = None,
    ) -> VisitPhotoResponse:
        """Attach a photo to a visit. Enforces the per-visit cap, allowed image
        types, and the size limit. Bytes are written under
        visit_photo_storage_dir/{visit_id}/; only metadata is persisted in DB."""
        visit = await self._load_owned_visit(visit_id, user)
        settings = get_settings()

        ctype = (content_type or "").split(";")[0].strip().lower()
        if ctype not in _ALLOWED_PHOTO_TYPES:
            raise bad_request("Photo must be a JPEG, PNG, WEBP or HEIC image")
        if not content:
            raise bad_request("Empty file")
        if len(content) > settings.max_visit_photo_bytes:
            mb = settings.max_visit_photo_bytes // (1024 * 1024)
            raise bad_request(f"Photo exceeds the {mb} MB limit")

        existing = await self.repo.photo_count(visit.id)
        if existing >= settings.max_visit_photos:
            raise bad_request(
                f"A visit can have at most {settings.max_visit_photos} photos"
            )

        visit_dir = os.path.join(settings.visit_photo_storage_dir, str(visit.id))
        os.makedirs(visit_dir, exist_ok=True)
        ext = _PHOTO_EXT.get(ctype, "jpg")
        path = os.path.join(visit_dir, f"{uuid.uuid4().hex}.{ext}")
        with open(path, "wb") as fh:
            fh.write(content)

        photo = VisitPhoto(
            visit_id=visit.id,
            uploaded_by=user.id,
            file_path=path,
            content_type=ctype,
            size_bytes=len(content),
            caption=(caption.strip()[:200] if caption else None),
        )
        self.repo.add(photo)
        await self.db.commit()
        await self.db.refresh(photo)
        return self._photo_response(photo)

    async def list_photos(
        self, user: User, visit_id: int
    ) -> list[VisitPhotoResponse]:
        visit = await self._load_owned_visit(visit_id, user)
        photos = await self.repo.photos_for(visit.id)
        return [self._photo_response(p) for p in photos]

    async def get_photo_file(
        self, user: User, photo_id: int
    ) -> tuple[str, str, str]:
        """Return (absolute_path, media_type, download_filename) for streaming.
        Authorizes via the parent visit's ownership rules."""
        photo = await self.repo.get_photo(photo_id)
        if photo is None:
            raise not_found("Photo not found")
        # Reuse visit ownership scoping.
        await self._load_owned_visit(photo.visit_id, user)
        if not photo.file_path or not os.path.isfile(photo.file_path):
            raise not_found("Photo file is missing")
        ext = _PHOTO_EXT.get(photo.content_type or "", "jpg")
        return (
            photo.file_path,
            photo.content_type or "application/octet-stream",
            f"visit_{photo.visit_id}_photo_{photo.id}.{ext}",
        )

    async def delete_photo(self, user: User, photo_id: int) -> None:
        photo = await self.repo.get_photo(photo_id)
        if photo is None:
            raise not_found("Photo not found")
        await self._load_owned_visit(photo.visit_id, user)
        path = photo.file_path
        await self.repo.delete_photo(photo)
        await self.db.commit()
        # Remove the file after the DB row is gone (best-effort).
        try:
            if path and os.path.isfile(path):
                os.remove(path)
        except OSError:
            logger.warning("could not remove photo file %s", path)

    @staticmethod
    def _photo_response(photo: VisitPhoto) -> VisitPhotoResponse:
        resp = VisitPhotoResponse.model_validate(photo)
        resp.download_url = _photo_download_url(photo.id)
        return resp

    # ── reads ────────────────────────────────────────────────────────────
    async def get_detail(self, user: User, visit_id: int) -> VisitDetailResponse:
        visit = await self._load_owned_visit(visit_id, user)
        return await self._build_detail(visit)

    async def get_active(self, user: User) -> VisitDetailResponse | None:
        visit = await self.repo.active_visit(user.id)
        if visit is None:
            return None
        return await self._build_detail(visit)

    async def _build_detail(self, visit: Visit) -> VisitDetailResponse:
        farmer_name = await self.repo.farmer_name(visit.farmer_id)
        note = await self.repo.notes_for(visit.id)
        livestock = await self.repo.livestock_for_visit(visit.id)
        orders = await self.repo.orders_for(visit.id)
        lead = await self.repo.lead_for_visit(visit.id)
        photos = await self.repo.photos_for(visit.id)
        base = VisitResponse.model_validate(visit).model_dump()
        return VisitDetailResponse(
            **base,
            farmer_name=farmer_name,
            notes=VisitNoteResponse.model_validate(note) if note else None,
            livestock=(
                LivestockProfileResponse.model_validate(livestock)
                if livestock
                else None
            ),
            orders=[VisitOrderResponse.model_validate(o) for o in orders],
            lead=LeadResponse.model_validate(lead) if lead else None,
            photos=[self._photo_response(p) for p in photos],
        )

    # ── small helpers ────────────────────────────────────────────────────
    @staticmethod
    def _today() -> date_type:
        return datetime.now(timezone.utc).date()


def _days(n: int):
    from datetime import timedelta

    return timedelta(days=n)
