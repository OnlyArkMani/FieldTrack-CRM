"""Visit-plan (CRM Module 2) business logic. Routers stay thin; this layer owns
transactions, the upsert rule, follow-up merging, and team-scope authorization.

KEY RULES:
- get_my_plan never 404s — a missing plan yields an empty (DRAFT) plan so the
  app can render its empty state. Pending follow-ups due that day are merged in
  with is_follow_up=true so they auto-appear.
- POST upserts by (employee_id, plan_date): an existing plan's items are
  replaced (not duplicated) and status flips to SUBMITTED. employee_id always
  comes from the caller, never the body.
- Team/pending views: ADMIN sees everyone; SUPERVISOR sees employees on the
  teams they supervise; EMPLOYEE is forbidden.
"""
import logging
from datetime import date as date_type
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import forbidden, not_found
from app.models.crm import VisitPlan, VisitPlanItem
from app.models.enums import UserRole
from app.models.user import User
from app.repositories.visit_plan_repository import VisitPlanRepository
from app.schemas.crm import (
    MyPlanResponse,
    PendingSubmissionView,
    PlanItemStatusUpdate,
    PlanItemView,
    TeamPlanEmployeeView,
    TeamPlansResponse,
    VisitPlanCreate,
)

logger = logging.getLogger("fieldtrack.visit_plan")

_FOLLOW_UP_SEQUENCE = 9_000  # park merged follow-ups after planned stops


class VisitPlanService:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db
        self.repo = VisitPlanRepository(db)
        self.settings = get_settings()

    # ── row -> PlanItemView ──────────────────────────────────────────────
    @staticmethod
    def _item_view(row) -> PlanItemView:
        item, name, village, lat, lng, lead, last_visit, last_note = row
        return PlanItemView(
            id=item.id,
            farmer_id=item.farmer_id,
            farmer_name=name or "Unknown",
            village=village,
            lat=lat,
            lng=lng,
            lead_status=lead,
            last_visit_at=last_visit,
            last_visit_note=last_note,
            sequence_order=item.sequence_order or 0,
            time_slot=item.time_slot,
            purpose=item.purpose,
            notes=item.notes,
            status=item.status,
            is_follow_up=False,
        )

    @staticmethod
    def _follow_up_view(row) -> PlanItemView:
        fu, name, village, lat, lng, lead, last_visit, last_note = row
        return PlanItemView(
            id=fu.id,
            farmer_id=fu.farmer_id,
            farmer_name=name or "Unknown",
            village=village,
            lat=lat,
            lng=lng,
            lead_status=lead,
            last_visit_at=last_visit,
            last_visit_note=last_note,
            sequence_order=_FOLLOW_UP_SEQUENCE,
            time_slot=fu.scheduled_time,
            purpose="FOLLOW_UP",
            notes=fu.purpose,
            status="PENDING",
            is_follow_up=True,
            follow_up_id=fu.id,
        )

    async def _build_my_plan(
        self, employee_id: int, plan_date: date_type
    ) -> MyPlanResponse:
        plan = await self.repo.get_plan(employee_id, plan_date)
        items: list[PlanItemView] = []
        if plan is not None:
            rows = await self.repo.plan_items_joined(plan.id)
            items = [self._item_view(r) for r in rows]

        planned_farmers = {it.farmer_id for it in items}
        fu_rows = await self.repo.pending_follow_ups_joined(employee_id, plan_date)
        for r in fu_rows:
            fu = r[0]
            if fu.farmer_id in planned_farmers:
                continue  # already a planned stop — don't double-list
            items.append(self._follow_up_view(r))

        return MyPlanResponse(
            id=plan.id if plan else None,
            plan_date=plan_date,
            status=plan.status if plan else "DRAFT",
            submitted_at=plan.submitted_at if plan else None,
            items=items,
        )

    # ── public: my plan ──────────────────────────────────────────────────
    async def get_my_plan(
        self, user: User, plan_date: date_type
    ) -> MyPlanResponse:
        return await self._build_my_plan(user.id, plan_date)

    # ── public: upsert ───────────────────────────────────────────────────
    async def upsert_plan(
        self, user: User, payload: VisitPlanCreate
    ) -> MyPlanResponse:
        now = datetime.now(timezone.utc)
        plan = await self.repo.get_plan(user.id, payload.plan_date)
        if plan is None:
            plan = VisitPlan(
                employee_id=user.id,
                plan_date=payload.plan_date,
                status="SUBMITTED",
                submitted_at=now,
            )
            self.repo.add(plan)
            await self.db.flush()  # assign plan.id
        else:
            plan.status = "SUBMITTED"
            plan.submitted_at = now
            await self.repo.delete_items(plan.id)
            await self.db.flush()

        for idx, it in enumerate(payload.items):
            if not await self.repo.farmer_exists(it.farmer_id):
                raise not_found(f"Farmer {it.farmer_id} not found")
            self.repo.add(
                VisitPlanItem(
                    plan_id=plan.id,
                    farmer_id=it.farmer_id,
                    sequence_order=it.sequence_order if it.sequence_order is not None else idx,
                    time_slot=it.time_slot,
                    purpose=it.purpose,
                    notes=it.notes,
                    status="PLANNED",
                )
            )
        await self.db.commit()
        return await self._build_my_plan(user.id, payload.plan_date)

    # ── public: single item status (on check-in) ─────────────────────────
    async def update_item_status(
        self,
        user: User,
        plan_id: int,
        item_id: int,
        payload: PlanItemStatusUpdate,
    ) -> MyPlanResponse:
        plan = await self.repo.get_plan_by_id(plan_id)
        if plan is None:
            raise not_found("Plan not found")
        is_privileged = user.role in (UserRole.ADMIN, UserRole.SUPERVISOR)
        if plan.employee_id != user.id and not is_privileged:
            raise forbidden("This plan isn't yours")

        item = await self.repo.get_item(item_id)
        if item is None or item.plan_id != plan_id:
            raise not_found("Plan item not found")

        item.status = payload.status
        self.repo.add(item)
        # Reflect progress on the plan: first completion -> IN_PROGRESS.
        if plan.status == "SUBMITTED" and payload.status in ("COMPLETED", "SKIPPED"):
            plan.status = "IN_PROGRESS"
            self.repo.add(plan)
        await self.db.commit()
        return await self._build_my_plan(plan.employee_id, plan.plan_date)

    # ── team scope helper ────────────────────────────────────────────────
    async def _scope_team_ids(self, user: User) -> list[int] | None:
        """None == all teams (admin); a list == the supervisor's teams."""
        if user.role == UserRole.ADMIN:
            return None
        if user.role == UserRole.SUPERVISOR:
            return await self.repo.supervised_team_ids(user.id)
        raise forbidden("Team plans are supervisor/admin only")

    # ── public: team plans for a date ────────────────────────────────────
    async def get_team_plans(
        self, user: User, plan_date: date_type
    ) -> TeamPlansResponse:
        team_ids = await self._scope_team_ids(user)
        employees = await self.repo.list_employees(team_ids=team_ids)
        emp_ids = [u.id for (u, _) in employees]
        plans = await self.repo.plans_for_employees(emp_ids, plan_date)

        views: list[TeamPlanEmployeeView] = []
        for (emp, team_name) in employees:
            plan = plans.get(emp.id)
            items: list[PlanItemView] = []
            if plan is not None:
                rows = await self.repo.plan_items_joined(plan.id)
                items = [self._item_view(r) for r in rows]
            views.append(
                TeamPlanEmployeeView(
                    employee_id=emp.id,
                    employee_name=emp.name,
                    team_name=team_name,
                    plan_id=plan.id if plan else None,
                    status=plan.status if plan else "NOT_SUBMITTED",
                    visits_planned=len(items),
                    submitted_at=plan.submitted_at if plan else None,
                    items=items,
                )
            )
        return TeamPlansResponse(plan_date=plan_date, employees=views)

    # ── public: pending submissions for tomorrow ─────────────────────────
    async def get_pending_submissions(
        self, user: User
    ) -> list[PendingSubmissionView]:
        team_ids = await self._scope_team_ids(user)
        tomorrow = self._business_tomorrow()
        employees = await self.repo.list_employees(team_ids=team_ids)
        emp_ids = [u.id for (u, _) in employees]
        plans = await self.repo.plans_for_employees(emp_ids, tomorrow)

        pending: list[PendingSubmissionView] = []
        for (emp, team_name) in employees:
            plan = plans.get(emp.id)
            if plan is None or plan.status != "SUBMITTED":
                pending.append(
                    PendingSubmissionView(
                        employee_id=emp.id,
                        employee_name=emp.name,
                        team_name=team_name,
                    )
                )
        return pending

    def _business_tomorrow(self) -> date_type:
        """Tomorrow's calendar date in the business timezone (the day a plan is
        being prepared for)."""
        try:
            tz = ZoneInfo(self.settings.business_timezone)
        except Exception:  # noqa: BLE001 — bad/missing tz config -> UTC
            tz = timezone.utc
        return (datetime.now(tz) + timedelta(days=1)).date()
