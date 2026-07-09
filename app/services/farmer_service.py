"""Farmer (CRM) business logic. Routers stay thin; this layer owns transactions
and team-scope authorization.

TEAM SCOPE (the core rule):
  - ADMIN            sees/edits every farmer.
  - MANAGER/EMPLOYEE see only farmers on their own team. A user with no team
    falls back to farmers they personally created (so a freshly-onboarded rep
    still sees their own entries).
Create assigns team automatically for employees (they cannot file a farmer
under another team); admins/managers may set team_id explicitly.
"""
import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import bad_request, forbidden, not_found
from app.models.crm import Farmer, Lead
from app.models.enums import UserRole
from app.models.user import Team, User
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

    async def _scope_for(self, user: User) -> dict:
        """List filter kwargs that enforce visibility for a non-admin user."""
        if self._is_admin(user):
            return {}
        if user.role == UserRole.MANAGER:
            stmt = select(Team.id).where(Team.manager_id == user.id)
            team_ids = list((await self.db.execute(stmt)).scalars().all())
            return {"team_ids": team_ids, "created_by": user.id}
        if user.team_id is not None:
            return {"team_id": user.team_id}
        # No team: restrict to what this user created.
        return {"created_by": user.id}

    async def _assert_can_view(self, farmer: Farmer, user: User) -> None:
        if self._is_admin(user):
            return
        if user.role == UserRole.MANAGER:
            stmt = select(Team.id).where(Team.manager_id == user.id)
            team_ids = list((await self.db.execute(stmt)).scalars().all())
            if farmer.team_id in team_ids:
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
        customer_type: str | None = None,
    ) -> CursorPage[FarmerListItem]:
        scope = await self._scope_for(user)
        # Admins may filter by an explicit team; non-admins are pinned to scope.
        if self._is_admin(user) and team_id is not None:
            scope = {"team_id": team_id}

        rows, total = await self.repo.list_farmers(
            cursor_id=decode_cursor(cursor),
            limit=limit,
            search=search,
            lead_status=lead_status,
            customer_type=customer_type,
            **scope,
        )
        has_more = len(rows) > limit
        page = rows[:limit]
        items = [
            FarmerListItem(
                id=f.id,
                name=f.name,
                customer_type=f.customer_type,
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
        await self._assert_can_view(farmer, requesting_user)

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
            # Admin/manager may set team_id explicitly; default to their own.
            team_id = payload.team_id if payload.team_id is not None else user.team_id

        if team_id is not None and not await self.repo.active_team_exists(team_id):
            raise not_found("Team not found")

        farmer = Farmer(
            team_id=team_id,
            created_by=user.id,
            customer_type=payload.customer_type,
            name=payload.name.strip(),
            phone=payload.phone,
            village=payload.village,
            district=payload.district,
            address=payload.address,
            pincode=payload.pincode,
            landmark=payload.landmark,
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
        await self._assert_can_view(farmer, user)

        fields = payload.model_dump(exclude_unset=True)
        # team reassignment is admin/manager only.
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
            "customer_type",
            "phone",
            "village",
            "district",
            "address",
            "pincode",
            "landmark",
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

    # ── bulk import (admin preload) ──────────────────────────────────────
    async def import_customers(
        self, rows: list[dict], *, user: User, dry_run: bool
    ) -> "CustomerImportResult":
        """Validate (and optionally commit) a batch of customer rows.

        Admin-only (enforced in the router). Each row must have a name; type
        defaults to FARMER_MEET and must be one of FARMER_MEET/FPO/VLCC/
        RETAILER/DISTRIBUTOR. team_id, when given, must reference an active
        team. Validation runs for every row so the caller sees all problems
        at once; when dry_run is False the valid rows are inserted in a
        single transaction (all-or-nothing)."""
        from app.schemas.crm import CustomerImportError, CustomerImportResult

        valid_types = {"FARMER_MEET", "FPO", "VLCC", "RETAILER", "DISTRIBUTOR"}
        errors: list[CustomerImportError] = []
        by_type: dict[str, int] = {
            "FARMER_MEET": 0, "FPO": 0, "VLCC": 0, "RETAILER": 0, "DISTRIBUTOR": 0,
        }
        staged: list[Farmer] = []
        team_cache: dict[int, bool] = {}

        def _to_int(v, field, rownum):
            if v in (None, ""):
                return None
            try:
                return int(float(str(v).strip()))
            except (TypeError, ValueError):
                errors.append(
                    CustomerImportError(row=rownum, field=field, message="not a number")
                )
                return None

        for idx, raw in enumerate(rows, start=1):
            row = {
                (str(k).strip().lower() if k is not None else ""): v
                for k, v in raw.items()
            }
            name = str(row.get("name") or "").strip()
            if not name:
                errors.append(
                    CustomerImportError(row=idx, field="name", message="name is required")
                )
                continue

            ctype = str(row.get("customer_type") or row.get("type") or "FARMER_MEET").strip().upper()
            if ctype not in valid_types:
                errors.append(
                    CustomerImportError(
                        row=idx,
                        field="customer_type",
                        message=f"must be one of {', '.join(sorted(valid_types))}",
                    )
                )
                continue

            phone = row.get("phone")
            phone = str(phone).strip() if phone not in (None, "") else None

            team_id = _to_int(row.get("team_id"), "team_id", idx)
            if team_id is not None:
                ok = team_cache.get(team_id)
                if ok is None:
                    ok = await self.repo.active_team_exists(team_id)
                    team_cache[team_id] = ok
                if not ok:
                    errors.append(
                        CustomerImportError(
                            row=idx, field="team_id", message="team not found / inactive"
                        )
                    )
                    continue

            farmer = Farmer(
                team_id=team_id if team_id is not None else user.team_id,
                created_by=user.id,
                customer_type=ctype,
                name=name,
                phone=phone,
                village=(str(row.get("village")).strip() if row.get("village") else None),
                district=(str(row.get("district")).strip() if row.get("district") else None),
                address=(str(row.get("address")).strip() if row.get("address") else None),
                total_cattle=_to_int(row.get("total_cattle"), "total_cattle", idx) or 0,
                current_feed_brand=(
                    str(row.get("current_feed_brand")).strip()
                    if row.get("current_feed_brand")
                    else None
                ),
                notes=(str(row.get("notes")).strip() if row.get("notes") else None),
                is_active=True,
            )
            staged.append(farmer)
            by_type[ctype] += 1

        created = 0
        if not dry_run and staged:
            for f in staged:
                self.repo.add(f)
            await self.db.commit()
            created = len(staged)

        return CustomerImportResult(
            total_rows=len(rows),
            created=created,
            skipped=len(rows) - len(staged),
            by_type={k: v for k, v in by_type.items() if v},
            errors=errors,
            dry_run=dry_run,
        )

    # ── visit history ────────────────────────────────────────────────────
    async def list_visits(
        self, farmer_id: int, *, user: User, cursor: str | None, limit: int
    ) -> CursorPage[VisitSummary]:
        farmer = await self.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        await self._assert_can_view(farmer, user)

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
        await self._assert_can_view(farmer, user)
        rows = await self.repo.livestock_history(farmer_id)
        return [LivestockProfileResponse.model_validate(r) for r in rows]

    # ── lead history ─────────────────────────────────────────────────────
    async def lead_history(
        self, farmer_id: int, *, user: User
    ) -> list[LeadHistoryItem]:
        farmer = await self.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        await self._assert_can_view(farmer, user)
        rows = await self.repo.lead_history(farmer_id)
        return [LeadHistoryItem.model_validate(r) for r in rows]

    # ── lead status change (powers the mobile 'Update Status' sheet) ─────
    async def update_lead_status(
        self, farmer_id: int, payload: LeadStatusUpdate, *, user: User
    ) -> LeadResponse:
        farmer = await self.repo.get_by_id(farmer_id)
        if farmer is None:
            raise not_found("Farmer not found")
        await self._assert_can_view(farmer, user)

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
