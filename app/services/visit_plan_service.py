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
        item, name, village, lat, lng, lead, last_visit, last_note, customer_type = row
        return PlanItemView(
            id=item.id,
            farmer_id=item.farmer_id,
            farmer_name=name or "Unknown",
            customer_type=customer_type.value if hasattr(customer_type, 'value') else (customer_type or "FARMER"),
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
    def _missed_item_view(row) -> PlanItemView:
        item, name, village, lat, lng, lead, last_visit, last_note, origin, customer_type = row
        return PlanItemView(
            id=item.id,
            farmer_id=item.farmer_id,
            farmer_name=name or "Unknown",
            customer_type=customer_type.value if hasattr(customer_type, 'value') else (customer_type or "FARMER"),
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
            is_carry_over=True,
            original_date=origin,
        )

    @staticmethod
    def _follow_up_view(row) -> PlanItemView:
        fu, name, village, lat, lng, lead, last_visit, last_note, customer_type = row
        return PlanItemView(
            id=fu.id,
            farmer_id=fu.farmer_id,
            farmer_name=name or "Unknown",
            customer_type=customer_type.value if hasattr(customer_type, 'value') else (customer_type or "FARMER"),
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

        # Carry-over: PLANNED stops from earlier days that were never visited.
        # They auto-appear on the current plan so the employee can continue them
        # (checklist: missed-visit carry-over). Only merged for today/future
        # plans, never when reviewing a past date.
        if plan_date >= self._today_business():
            missed_rows = await self.repo.missed_plan_items_joined(
                employee_id, plan_date
            )
            for r in missed_rows:
                item = r[0]
                if item.farmer_id in planned_farmers:
                    continue
                items.append(self._missed_item_view(r))
                planned_farmers.add(item.farmer_id)

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

    async def skip_missed_item(
        self, user: User, item_id: int
    ) -> MyPlanResponse:
        """Drop a carried-over (missed) item: mark it SKIPPED so it stops
        appearing. Returns the employee's plan for today."""
        item = await self.repo.get_item(item_id)
        if item is None:
            raise not_found("Plan item not found")
        plan = await self.repo.get_plan_by_id(item.plan_id)
        if plan is None:
            raise not_found("Plan not found")
        is_privileged = user.role in (UserRole.ADMIN, UserRole.SUPERVISOR)
        if plan.employee_id != user.id and not is_privileged:
            raise forbidden("This plan isn't yours")
        item.status = "SKIPPED"
        self.repo.add(item)
        await self.db.commit()
        return await self._build_my_plan(plan.employee_id, self._today_business())

    def _today_business(self) -> date_type:
        """Today's calendar date in the business timezone."""
        try:
            tz = ZoneInfo(self.settings.business_timezone)
        except Exception:  # noqa: BLE001
            tz = timezone.utc
        return datetime.now(tz).date()

    # ── public: carry a missed item onto a new date ──────────────────────
    async def carry_over_item(
        self, user: User, item_id: int, target_date: date_type, time_slot
    ) -> MyPlanResponse:
        """Reschedule a missed PLANNED item onto `target_date`: create a fresh
        PLANNED item on that date's plan (creating the plan if needed) and mark
        the source item SKIPPED so it stops carrying over."""
        item = await self.repo.get_item(item_id)
        if item is None:
            raise not_found("Plan item not found")
        source_plan = await self.repo.get_plan_by_id(item.plan_id)
        if source_plan is None:
            raise not_found("Plan not found")
        is_privileged = user.role in (UserRole.ADMIN, UserRole.SUPERVISOR)
        if source_plan.employee_id != user.id and not is_privileged:
            raise forbidden("This plan isn't yours")

        # Target plan for the new date (create if absent).
        target_plan = await self.repo.get_plan(source_plan.employee_id, target_date)
        if target_plan is None:
            target_plan = VisitPlan(
                employee_id=source_plan.employee_id,
                plan_date=target_date,
                status="SUBMITTED",
                submitted_at=datetime.now(timezone.utc),
            )
            self.repo.add(target_plan)
            await self.db.flush()

        self.repo.add(
            VisitPlanItem(
                plan_id=target_plan.id,
                farmer_id=item.farmer_id,
                sequence_order=item.sequence_order or 0,
                time_slot=time_slot if time_slot is not None else item.time_slot,
                purpose=item.purpose,
                notes=item.notes,
                status="PLANNED",
            )
        )
        # Retire the source so it stops appearing as a carry-over.
        item.status = "SKIPPED"
        self.repo.add(item)
        await self.db.commit()
        return await self._build_my_plan(source_plan.employee_id, target_date)

    def _business_tomorrow(self) -> date_type:
        """Tomorrow's calendar date in the business timezone (the day a plan is
        being prepared for)."""
        try:
            tz = ZoneInfo(self.settings.business_timezone)
        except Exception:  # noqa: BLE001 — bad/missing tz config -> UTC
            tz = timezone.utc
        return (datetime.now(tz) + timedelta(days=1)).date()
