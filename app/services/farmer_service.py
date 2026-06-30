"""Farmer (CRM) business logic. Routers stay thin; this layer owns transactions
and team-scope authorization.

TEAM SCOPE (the core rule):
  - ADMIN            sees/edits every farmer.
  - SUPERVISOR/EMPLOYEE see only farmers on their own team. A user with no team
    falls back to farmers they personally created (so a freshly-onboarded rep
    still sees their own entries).
Create assigns team automatically for employees (they cannot file a farmer
under another team); admins/supervisors may set team_id explicitly.
"""
import logging

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import bad_request, forbidden, not_found
from app.models.crm import Farmer, Lead
from app.models.enums import UserRole
from app.models.user import User
from app.repositories.farmer_repository import FarmerRepository
from app.schemas.common import CursorPage, decode_cursor, encode_cursor
from app.schemas.crm import (
    CurrentLead,
    FarmerCreate,
    FarmerDetailResponse,
    FarmerListItem,
    FarmerResponse,
    FarmerUpdate,
    FollowUpResponse,
    LeadHistoryItem,
    LeadResponse,
    LeadStatusUpdate,
    LivestockProfileResponse,
    VisitSummary,
)

logger = logging.getLogger("fieldtrack.farmer")

RECENT_VISITS_LIMIT = 3


class FarmerService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = FarmerRepository(db)

    # ── scope helpers ────────────────────────────────────────────────────
    @staticmethod
    def _is_admin(user: User) -> bool:
        return user.role == UserRole.ADMIN

    def _scope_for(self, user: User) -> dict:
        """List filter kwargs that enforce visibility for a non-admin user."""
        if self._is_admin(user):
            return {}
        if user.team_id is not None:
            return {"team_id": user.team_id}
        # No team: restrict to what this user created.
        return {"created_by": user.id}

    def _assert_can_view(self, farmer: Farmer, user: User) -> None:
        if self._is_admin(user):
            return
        if user.team_id is not None and farmer.team_id == user.team_id:
            return
        if farmer.created_by == user.id:
            return
        raise forbidden("You don't have access to this farmer")

    # ── list ─────────────────────────────────────────────────────────────
    async def list_farmers(
        self,
        *,
        user: User,
        cursor: str | None,
        limit: int,
        team_id: int | None,
        lead_status: str | None,
        search: str | None,
    ) -> CursorPage[FarmerListItem]:
        scope = self._scope_for(user)
        # Admins may filter by an explicit team; non-admins are pinned to scope.
        if self._is_admin(user) and team_id is not None:
            scope = {"team_id": team_id}

        rows, total = await self.repo.list_farmers(
            cursor_id=decode_cursor(cursor),
            limit=limit,
            search=search,
            lead_status=lead_status,
            **scope,
        )
        has_more = len(rows) > limit
        page = rows[:limit]
        items = [
            FarmerListItem(
                id=f.id,
                name=f.name,
                phone=f.phone,
                village=f.village,
                district=f.district,
                total_cattle=f.total_cattle or 0,
                is_active=f.is_active,
                team_id=f.team_id,
                team_name=team_name,
                lead_status=lead_status_val,
                last_visit_at=last_visit_at,
                created_at=f.created_at,
            )
            for (f, team_name, lead_status_val, last_visit_at) in page
        ]
        next_cursor = (
            encode_cursor(page[-1][0].id) if has_more and page else None
        )
        return CursorPage[FarmerListItem](
            items=items,
            next_cursor=next_cursor,
            total=total,
            has_more=has_more,
        )

    # ── full profile ─────────────────────────────────────────────────────
    async def get_farmer_with_full_profile(
        self, farmer_id: int, requesting_user: User
    ) -> FarmerDetailResponse:
        found = await self.repo.get_with_team(farmer_id)
        if found is None:
            raise not_found("Farmer not found")
        farmer, team_name = found
        self._assert_can_view(farmer, requesting_user)

        latest_lead = await self.repo.latest_lead(farmer_id)
        recent = await self.repo.recent_visits(farmer_id, limit=RECENT_VISITS_LIMIT)
        livestock = await self.repo.latest_livestock(farmer_id)
        follow_ups = await self.repo.pending_follow_ups(farmer_id)
        total_visits = await self.repo.visit_count(farmer_id)
        total_orders = await self.repo.order_count(farmer_id)

        base = FarmerResponse.model_validate(farmer).model_dump()
        return FarmerDetailResponse(
            **base,
            team_name=team_name,
            current_lead=(
                CurrentLead(
                    status=latest_lead.status,
                    reason_note=latest_lead.reason_note,
                    changed_at=latest_lead.created_at,
                )
                if latest_lead
                else None
            ),
            recent_visits=[VisitSummary.model_validate(v) for v in recent],
            latest_livestock=(
                LivestockProfileResponse.model_validate(livestock)
                if livestock
                else None
            ),
            pending_follow_ups=[
                FollowUpResponse.model_validate(f) for f in follow_ups
            ],
            total_visits=total_visits,
            total_orders=total_orders,
        )

    # ── create ───────────────────────────────────────────────────────────
    async def create_farmer(
        self, payload: FarmerCreate, *, user: User
    ) -> FarmerResponse:
        if not payload.name.strip():
            raise bad_request("Name is required")

        # Employees cannot choose a team — they're pinned to their own.
        if user.role == UserRole.EMPLOYEE:
            team_id = user.team_id
        else:
            # Admin/supervisor may set team_id explicitly; default to their own.
            team_id = payload.team_id if payload.team_id is not None else user.team_id

        if team_id is not None and not await self.repo.active_team_exists(team_id):
            raise not_found("Team not found")

        farmer = Farmer(
            team_id=team_id,
            created_by=user.id,
            name=payload.name.strip(),
            phone=payload.phone,
            village=payload.village,
            district=payload.district,
            address=payload.address,
            lat=payload.lat,
            lng=payload.lng,
            total_cattle=payload.total_cattle or 0,
            current_feed_brand=payload.current_feed_brand,
            current_feed_price_per_bag=payload.current_feed_price_per_bag,
            notes=payload.notes,
            is_active=True,
        )
        self.repo.add(farmer)
        await self.db.commit()
        await self.db.refresh(farmer)
        return FarmerResponse.model_validate(farmer)

    # ── update (base info only) ──────────────────────────────────────────
    async def update_farmer(
        self, farmer_id: int, payload: FarmerUpdate, *, user: User
    ) -> FarmerResponse:
        farmer = await self.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        self._assert_can_view(farmer, user)

        fields = payload.model_dump(exclude_unset=True)
        # team reassignment is admin/supervisor only.
        if "team_id" in fields:
            if user.role == UserRole.EMPLOYEE:
                fields.pop("team_id")
            else:
                tid = fields["team_id"]
                if tid is not None and not await self.repo.active_team_exists(tid):
                    raise not_found("Team not found")

        # Livestock is captured per-visit, never edited here — guard anyway.
        editable = {
            "name",
            "phone",
            "village",
            "district",
            "address",
            "lat",
            "lng",
            "total_cattle",
            "current_feed_brand",
            "current_feed_price_per_bag",
            "notes",
            "is_active",
            "team_id",
        }
        for key, value in fields.items():
            if key in editable:
                setattr(farmer, key, value)

        self.repo.add(farmer)
        await self.db.commit()
        await self.db.refresh(farmer)
        return FarmerResponse.model_validate(farmer)

    # ── visit history ────────────────────────────────────────────────────
    async def list_visits(
        self, farmer_id: int, *, user: User, cursor: str | None, limit: int
    ) -> CursorPage[VisitSummary]:
        farmer = await self.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        self._assert_can_view(farmer, user)

        rows, total = await self.repo.list_visits(
            farmer_id, cursor_id=decode_cursor(cursor), limit=limit
        )
        has_more = len(rows) > limit
        page = rows[:limit]
        next_cursor = encode_cursor(page[-1].id) if has_more and page else None
        return CursorPage[VisitSummary](
            items=[VisitSummary.model_validate(v) for v in page],
            next_cursor=next_cursor,
            total=total,
            has_more=has_more,
        )

    # ── livestock history ────────────────────────────────────────────────
    async def livestock_history(
        self, farmer_id: int, *, user: User
    ) -> list[LivestockProfileResponse]:
        farmer = await self.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        self._assert_can_view(farmer, user)
        rows = await self.repo.livestock_history(farmer_id)
        return [LivestockProfileResponse.model_validate(r) for r in rows]

    # ── lead history ─────────────────────────────────────────────────────
    async def lead_history(
        self, farmer_id: int, *, user: User
    ) -> list[LeadHistoryItem]:
        farmer = await self.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        self._assert_can_view(farmer, user)
        rows = await self.repo.lead_history(farmer_id)
        return [LeadHistoryItem.model_validate(r) for r in rows]

    # ── lead status change (powers the mobile 'Update Status' sheet) ─────
    async def update_lead_status(
        self, farmer_id: int, payload: LeadStatusUpdate, *, user: User
    ) -> LeadResponse:
        farmer = await self.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        self._assert_can_view(farmer, user)

        lead = Lead(
            farmer_id=farmer_id,
            employee_id=user.id,
            visit_id=payload.visit_id,
            status=payload.status,
            reason_note=payload.reason_note.strip(),
        )
        self.repo.add_lead(lead)
        await self.db.commit()
        await self.db.refresh(lead)
        return LeadResponse.model_validate(lead)
