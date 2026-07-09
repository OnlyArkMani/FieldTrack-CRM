"""Vet-requirement dashboard service (July 2026 CRM revamp, Feature 4).

Lists visits flagged with vet_required=true, scope-aware:
- EMPLOYEE   → only their own raised requests.
- SUPERVISOR → their team's requests.
- ADMIN      → everything (optional team_id filter).

Also lets a manager (admin/supervisor) or the raising employee move a request
through REQUESTED → SCHEDULED → DONE.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import bad_request, forbidden, not_found
from app.models.crm import Customer, Visit
from app.models.enums import UserRole
from app.models.user import Team, User
from app.schemas.crm import VetRequestItem


class VetService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_requests(
        self,
        user: User,
        *,
        status: str | None = None,
        team_id: int | None = None,
        employee_id: int | None = None,
    ) -> list[VetRequestItem]:
        q = (
            select(
                Visit,
                Customer.name.label("farmer_name"),
                Customer.customer_type.label("customer_type"),
                Customer.village.label("village"),
                Customer.phone.label("phone"),
                User.name.label("employee_name"),
                User.team_id.label("employee_team_id"),
                Team.name.label("team_name"),
            )
            .join(Customer, Visit.farmer_id == Customer.id, isouter=True)
            .join(User, Visit.employee_id == User.id, isouter=True)
            .join(Team, User.team_id == Team.id, isouter=True)
            .where(Visit.vet_required.is_(True))
        )

        if user.role == UserRole.EMPLOYEE:
            q = q.where(Visit.employee_id == user.id)
        elif user.role == UserRole.SUPERVISOR:
            if not user.team_id:
                return []
            q = q.where(User.team_id == user.team_id)
        elif user.role == UserRole.ADMIN:
            if team_id is not None:
                q = q.where(User.team_id == team_id)
        else:
            raise forbidden("Not permitted")

        if employee_id is not None:
            # Composes safely with the role scoping above (AND'ed): a
            # supervisor passing another team's employee_id just gets an
            # empty result, not a cross-team leak.
            q = q.where(Visit.employee_id == employee_id)

        if status:
            q = q.where(Visit.vet_status == status.upper())

        q = q.order_by(Visit.check_in_at.desc())
        rows = (await self.db.execute(q)).all()
        return [
            VetRequestItem(
                visit_id=r.Visit.id,
                farmer_id=r.Visit.farmer_id,
                farmer_name=r.farmer_name or "Unknown",
                customer_type=r.customer_type or "FARMER_MEET",
                village=r.village,
                phone=r.phone,
                employee_id=r.Visit.employee_id,
                employee_name=r.employee_name,
                team_name=r.team_name,
                visit_date=r.Visit.check_in_at,
                vet_cattle_count=r.Visit.vet_cattle_count,
                vet_notes=r.Visit.vet_notes,
                vet_status=r.Visit.vet_status or "REQUESTED",
            )
            for r in rows
        ]

    async def update_status(
        self, user: User, visit_id: int, vet_status: str
    ) -> VetRequestItem:
        visit = await self.db.get(Visit, visit_id)
        if visit is None:
            raise not_found("Visit not found")
        if not visit.vet_required:
            raise bad_request("This visit has no vet request")

        # Scope: admin anywhere; supervisor within their team; employee only
        # their own raised request.
        if user.role == UserRole.EMPLOYEE:
            if visit.employee_id != user.id:
                raise forbidden("This request isn't yours")
        elif user.role == UserRole.SUPERVISOR:
            emp = await self.db.get(User, visit.employee_id) if visit.employee_id else None
            if emp is None or emp.team_id != user.team_id:
                raise forbidden("This request isn't on your team")

        visit.vet_status = vet_status.upper()
        self.db.add(visit)
        await self.db.commit()

        # Re-read enriched row for the response.
        items = await self.list_requests(user)
        for it in items:
            if it.visit_id == visit_id:
                return it
        # Fallback minimal item (shouldn't normally happen).
        return VetRequestItem(
            visit_id=visit.id,
            farmer_id=visit.farmer_id,
            farmer_name="Unknown",
            vet_cattle_count=visit.vet_cattle_count,
            vet_notes=visit.vet_notes,
            vet_status=visit.vet_status or "REQUESTED",
        )
