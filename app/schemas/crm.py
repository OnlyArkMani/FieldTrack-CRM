"""FieldCRM request/response schemas (Pydantic v2) — base set.

Scope: just enough to type the router contracts being built now. Service-layer
validation (e.g. order delivery_date >= today+7, lead reason_note required on a
visit-less status change) lives in the services, not here — these are the wire
shapes. Response models use `from_attributes=True` to read straight off ORM rows.
"""
import re
from datetime import date, datetime, time
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Loose international phone shape: optional +, then 7-15 digits, allowing
# spaces / dashes / parens as separators. Kept permissive on purpose — field
# staff enter numbers in many formats; we only reject obvious garbage.
_PHONE_RE = re.compile(r"^\+?[0-9][0-9\s\-()]{6,19}$")


def _validate_phone(v: str | None) -> str | None:
    if v is None:
        return None
    v = v.strip()
    if not v:
        return None
    if not _PHONE_RE.match(v):
        raise ValueError("Invalid phone number format")
    return v


# Shared literal vocabularies (kept here so clients share one source of truth).
LeadStatus = Literal["HOT", "WARM", "COLD"]
VisitStatus = Literal["CHECKED_IN", "COMPLETED", "ABANDONED"]
VisitPurpose = Literal["FIRST_VISIT", "FOLLOW_UP", "ORDER_COLLECTION", "RELATIONSHIP_VISIT"]
PlanStatus = Literal["DRAFT", "SUBMITTED", "IN_PROGRESS", "COMPLETED"]
PlanItemStatus = Literal["PLANNED", "COMPLETED", "SKIPPED"]
FollowUpStatus = Literal["PENDING", "ACKNOWLEDGED", "COMPLETED", "ESCALATED"]
ReportStatus = Literal["DRAFT", "SUBMITTED"]


# ── Farmers (Module 1) ───────────────────────────────────────────────────
class FarmerCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    phone: str | None = Field(default=None, max_length=20)
    village: str | None = Field(default=None, max_length=200)
    district: str | None = Field(default=None, max_length=200)
    address: str | None = None
    team_id: int | None = None
    lat: float | None = None
    lng: float | None = None
    total_cattle: int = Field(default=0, ge=0)
    current_feed_brand: str | None = Field(default=None, max_length=200)
    current_feed_price_per_bag: Decimal | None = Field(default=None, ge=0)
    notes: str | None = None

    _v_phone = field_validator("phone")(_validate_phone)


class FarmerUpdate(BaseModel):
    """All-optional partial update."""

    name: str | None = Field(default=None, min_length=1, max_length=200)
    phone: str | None = Field(default=None, max_length=20)
    village: str | None = Field(default=None, max_length=200)
    district: str | None = Field(default=None, max_length=200)
    address: str | None = None
    team_id: int | None = None
    lat: float | None = None
    lng: float | None = None
    total_cattle: int | None = Field(default=None, ge=0)
    current_feed_brand: str | None = Field(default=None, max_length=200)
    current_feed_price_per_bag: Decimal | None = Field(default=None, ge=0)
    notes: str | None = None
    is_active: bool | None = None

    _v_phone = field_validator("phone")(_validate_phone)


class FarmerResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    team_id: int | None
    created_by: int | None
    name: str
    phone: str | None
    village: str | None
    district: str | None
    address: str | None
    lat: float | None
    lng: float | None
    total_cattle: int
    current_feed_brand: str | None
    current_feed_price_per_bag: Decimal | None
    notes: str | None
    is_active: bool
    created_at: datetime
    updated_at: datetime


# ── Visit Plans (Module 2) ───────────────────────────────────────────────
class VisitPlanItemCreate(BaseModel):
    farmer_id: int
    sequence_order: int = Field(default=0, ge=0)
    time_slot: time | None = None
    purpose: VisitPurpose | None = None
    notes: str | None = None


class VisitPlanItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    plan_id: int | None
    farmer_id: int | None
    sequence_order: int
    time_slot: time | None
    purpose: str | None
    notes: str | None
    status: str
    created_at: datetime


class VisitPlanCreate(BaseModel):
    plan_date: date
    status: PlanStatus = "DRAFT"
    items: list[VisitPlanItemCreate] = Field(default_factory=list)


class VisitPlanResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    employee_id: int | None
    plan_date: date
    submitted_at: datetime | None
    status: str
    created_at: datetime
    items: list[VisitPlanItemResponse] = Field(default_factory=list)


# ── Visits (Module 3) ────────────────────────────────────────────────────
class VisitCreate(BaseModel):
    """Check-in payload. plan_item_id null == unplanned visit."""

    farmer_id: int
    plan_item_id: int | None = None
    check_in_lat: float | None = None
    check_in_lng: float | None = None
    purpose: VisitPurpose | None = None
    location_warning_remark: str | None = None


class VisitResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    employee_id: int | None
    farmer_id: int | None
    plan_item_id: int | None
    check_in_at: datetime | None
    check_out_at: datetime | None
    check_in_lat: float | None
    check_in_lng: float | None
    farmer_lat: float | None
    farmer_lng: float | None
    distance_at_checkin_meters: float | None
    location_warning: bool
    location_warning_remark: str | None
    purpose: str | None
    status: str
    created_at: datetime
    updated_at: datetime


# ── Leads (Module 4) ─────────────────────────────────────────────────────
class LeadCreate(BaseModel):
    farmer_id: int
    status: LeadStatus
    visit_id: int | None = None
    # Service enforces: required when there's no associated visit.
    reason_note: str | None = None


class LeadResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    farmer_id: int | None
    employee_id: int | None
    visit_id: int | None
    status: str
    reason_note: str | None
    created_at: datetime


# ── Follow-ups (Module 4) ────────────────────────────────────────────────
class FollowUpCreate(BaseModel):
    farmer_id: int
    scheduled_date: date
    scheduled_time: time | None = None
    purpose: str | None = None
    visit_id: int | None = None


class FollowUpResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    farmer_id: int | None
    employee_id: int | None
    visit_id: int | None
    scheduled_date: date
    scheduled_time: time | None
    purpose: str | None
    reminder_sent_24h: bool
    reminder_sent_1h: bool
    status: str
    completed_visit_id: int | None
    created_at: datetime


# ── Daily Sales Report (Module 5) ────────────────────────────────────────
class DailyReportResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    employee_id: int | None
    report_date: date
    attendance_id: int | None
    visits_planned: int
    visits_completed: int
    visits_skipped: int
    orders_captured: int
    hot_leads: int
    warm_leads: int
    cold_leads: int
    follow_ups_scheduled: int
    end_of_day_note: str | None
    manager_comment: str | None = None  # added migration 0006
    submitted_at: datetime | None
    is_late: bool
    status: str
    created_at: datetime


# ── GPS Config (Module 6) ────────────────────────────────────────────────
class GpsConfigUpdate(BaseModel):
    """Admin per-team GPS interval tuning. All optional — patch semantics."""

    moving_interval_seconds: int | None = Field(default=None, ge=10)
    stationary_interval_seconds: int | None = Field(default=None, ge=10)
    low_battery_interval_seconds: int | None = Field(default=None, ge=10)
    low_battery_threshold: int | None = Field(default=None, ge=1, le=100)


class GpsConfigResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    team_id: int | None
    moving_interval_seconds: int
    stationary_interval_seconds: int
    low_battery_interval_seconds: int
    low_battery_threshold: int
    updated_by: int | None
    updated_at: datetime


# ── Farmer aggregate views (list + full profile + histories) ─────────────
class FarmerListItem(BaseModel):
    """One row of GET /farmers — base info enriched with the CURRENT lead
    status (latest leads row) and last-visit timestamp, built in the service."""

    id: int
    name: str
    phone: str | None = None
    village: str | None = None
    district: str | None = None
    total_cattle: int = 0
    is_active: bool = True
    team_id: int | None = None
    team_name: str | None = None
    lead_status: str | None = None  # HOT/WARM/COLD or null if never set
    last_visit_at: datetime | None = None
    created_at: datetime


class VisitSummary(BaseModel):
    """Compact visit row for the farmer profile timeline + visit history."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    employee_id: int | None
    check_in_at: datetime | None
    check_out_at: datetime | None
    purpose: str | None
    status: str
    created_at: datetime


class LivestockProfileResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    farmer_id: int | None
    visit_id: int | None
    total_cattle: int | None
    breed: str | None
    age_group: str | None
    current_brand: str | None
    bags_per_month: int | None
    kg_per_animal_per_day: Decimal | None
    current_price_per_bag: Decimal | None
    willing_to_pay_min: Decimal | None
    willing_to_pay_max: Decimal | None
    health_status: str | None
    health_notes: str | None
    recorded_at: datetime


class LeadHistoryItem(BaseModel):
    """One lead status change (newest-first history)."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    status: str
    reason_note: str | None
    employee_id: int | None
    visit_id: int | None
    created_at: datetime


class CurrentLead(BaseModel):
    """Denormalized 'where this farmer stands now' = latest leads row."""

    status: str
    reason_note: str | None = None
    changed_at: datetime | None = None


class FarmerDetailResponse(BaseModel):
    """GET /farmers/{id} — full profile aggregate."""

    model_config = ConfigDict(from_attributes=True)

    # base
    id: int
    team_id: int | None
    team_name: str | None = None
    created_by: int | None
    name: str
    phone: str | None
    village: str | None
    district: str | None
    address: str | None
    lat: float | None
    lng: float | None
    total_cattle: int
    current_feed_brand: str | None
    current_feed_price_per_bag: Decimal | None
    notes: str | None
    is_active: bool
    created_at: datetime
    updated_at: datetime
    # aggregates (populated by the service)
    current_lead: CurrentLead | None = None
    recent_visits: list[VisitSummary] = Field(default_factory=list)
    latest_livestock: LivestockProfileResponse | None = None
    pending_follow_ups: list[FollowUpResponse] = Field(default_factory=list)
    total_visits: int = 0
    total_orders: int = 0


class LeadStatusUpdate(BaseModel):
    """POST /farmers/{id}/lead-status — records a new lead status change.

    reason_note is required here (the mobile 'Update Status' sheet enforces it);
    visit_id is optional (set when the change happened during a visit)."""

    status: LeadStatus
    reason_note: str = Field(min_length=1, max_length=2000)
    visit_id: int | None = None


# ── Visit planning views (Module 2) ──────────────────────────────────────
class PlanItemView(BaseModel):
    """One row in a day's plan — a planned stop OR a merged pending follow-up.
    Farmer details + lead status + last-visit context are joined by the service
    so the card renders without extra round-trips."""

    id: int  # plan_item id, or the follow_up id when is_follow_up
    farmer_id: int
    farmer_name: str
    village: str | None = None
    lat: float | None = None
    lng: float | None = None
    lead_status: str | None = None
    last_visit_at: datetime | None = None
    last_visit_note: str | None = None
    sequence_order: int = 0
    time_slot: time | None = None
    purpose: str | None = None
    notes: str | None = None
    status: str = "PLANNED"  # PLANNED/COMPLETED/SKIPPED (PENDING for follow-ups)
    is_follow_up: bool = False
    follow_up_id: int | None = None


class MyPlanResponse(BaseModel):
    """GET /visit-plans/my/{date}. When no plan exists yet, id is null and
    status is 'DRAFT' (never 404) so the app shows the empty state — but any
    pending follow-ups for the date are still merged into items."""

    id: int | None = None
    plan_date: date
    status: str = "DRAFT"
    submitted_at: datetime | None = None
    items: list[PlanItemView] = Field(default_factory=list)


class PlanItemStatusUpdate(BaseModel):
    status: Literal["PLANNED", "COMPLETED", "SKIPPED"]


class TeamPlanEmployeeView(BaseModel):
    """One employee's plan summary in the team/admin view."""

    employee_id: int
    employee_name: str
    team_name: str | None = None
    plan_id: int | None = None
    status: str = "NOT_SUBMITTED"  # NOT_SUBMITTED / DRAFT / SUBMITTED / ...
    visits_planned: int = 0
    submitted_at: datetime | None = None
    items: list[PlanItemView] = Field(default_factory=list)


class TeamPlansResponse(BaseModel):
    plan_date: date
    employees: list[TeamPlanEmployeeView] = Field(default_factory=list)


class PendingSubmissionView(BaseModel):
    """An employee who hasn't submitted a plan for the target date."""

    employee_id: int
    employee_name: str
    team_name: str | None = None
    supervisor_id: int | None = None


# ── Visit execution (Module 3) ───────────────────────────────────────────
PaymentMode = Literal["CASH", "UPI", "CREDIT"]


class CheckInRequest(BaseModel):
    farmer_id: int
    lat: float
    lng: float
    plan_item_id: int | None = None


class CheckInResponse(BaseModel):
    visit_id: int
    location_warning: bool
    distance_meters: float | None = None
    farmer_name: str
    # Mirror of location_warning — the app must collect a remark when true.
    warning_required: bool


class LocationRemarkRequest(BaseModel):
    remark: str = Field(min_length=1, max_length=2000)


class VisitNotesUpsert(BaseModel):
    meeting_highlights: str | None = None
    farmer_concerns: str | None = None
    product_interest: str | None = None
    step_completed: int = Field(default=0, ge=0, le=4)


class VisitNoteResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    visit_id: int | None
    meeting_highlights: str | None
    farmer_concerns: str | None
    product_interest: str | None
    step_completed: int
    created_at: datetime
    updated_at: datetime


class LivestockUpsert(BaseModel):
    total_cattle: int | None = Field(default=None, ge=0)
    breed: str | None = Field(default=None, max_length=100)
    age_group: str | None = Field(default=None, max_length=50)
    current_brand: str | None = Field(default=None, max_length=200)
    bags_per_month: int | None = Field(default=None, ge=0)
    kg_per_animal_per_day: Decimal | None = Field(default=None, ge=0)
    current_price_per_bag: Decimal | None = Field(default=None, ge=0)
    willing_to_pay_min: Decimal | None = Field(default=None, ge=0)
    willing_to_pay_max: Decimal | None = Field(default=None, ge=0)
    health_status: str | None = Field(default=None, max_length=20)
    health_notes: str | None = None


class OrderCreate(BaseModel):
    bags_count: int = Field(ge=1)
    delivery_date: date  # service enforces >= today + 7 days
    delivery_address: str | None = None
    payment_mode: PaymentMode | None = None
    special_notes: str | None = None


class VisitOrderResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    visit_id: int | None
    farmer_id: int | None
    employee_id: int | None
    bags_count: int
    delivery_date: date
    delivery_address: str | None
    payment_mode: str | None
    special_notes: str | None
    status: str
    created_at: datetime


class VisitPhotoResponse(BaseModel):
    """Metadata for one photo attached to a visit. The image itself is fetched
    from `download_url` (streamed, owner/team scoped)."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    visit_id: int | None
    uploaded_by: int | None
    content_type: str | None
    size_bytes: int | None
    caption: str | None
    created_at: datetime
    download_url: str | None = None


class VisitCompleteRequest(BaseModel):
    lead_status: LeadStatus
    # Required (service-enforced) when lead_status is WARM or COLD.
    follow_up_date: date | None = None
    follow_up_time: time | None = None
    follow_up_purpose: str | None = None


class VisitDetailResponse(BaseModel):
    """GET /visits/{id} — base visit + the data captured across the 4 steps."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    employee_id: int | None
    farmer_id: int | None
    farmer_name: str | None = None
    plan_item_id: int | None
    check_in_at: datetime | None
    check_out_at: datetime | None
    check_in_lat: float | None
    check_in_lng: float | None
    farmer_lat: float | None
    farmer_lng: float | None
    distance_at_checkin_meters: float | None
    location_warning: bool
    location_warning_remark: str | None
    purpose: str | None
    status: str
    created_at: datetime
    updated_at: datetime
    # step data (populated by the service)
    notes: VisitNoteResponse | None = None
    livestock: LivestockProfileResponse | None = None
    orders: list[VisitOrderResponse] = Field(default_factory=list)
    lead: LeadResponse | None = None
    photos: list[VisitPhotoResponse] = Field(default_factory=list)


# ── Lead management (Module 4) ───────────────────────────────────────────
class LeadListItem(BaseModel):
    """A farmer with their CURRENT lead status, plus the next pending follow-up
    (when WARM/COLD). Built by the service."""

    farmer_id: int
    farmer_name: str
    village: str | None = None
    lead_status: str
    last_visit_at: datetime | None = None
    follow_up_date: date | None = None
    follow_up_time: time | None = None
    reason_note: str | None = None
    employee_id: int | None = None
    employee_name: str | None = None  # populated in the team view


class TeamLeadsResponse(BaseModel):
    hot_count: int = 0
    warm_count: int = 0
    cold_count: int = 0
    items: list[LeadListItem] = Field(default_factory=list)


class PipelineTeamRow(BaseModel):
    team_name: str
    hot: int = 0
    warm: int = 0
    cold: int = 0


class PipelineEmployeeRow(BaseModel):
    name: str
    hot: int = 0
    warm: int = 0
    cold: int = 0


class PipelineResponse(BaseModel):
    hot_count: int = 0
    warm_count: int = 0
    cold_count: int = 0
    by_team: list[PipelineTeamRow] = Field(default_factory=list)
    by_employee: list[PipelineEmployeeRow] = Field(default_factory=list)


class LeadStatusUpdateRequest(BaseModel):
    """POST /leads/update-status — change a farmer's lead WITHOUT a visit.

    reason_note is required (min 10 chars). For WARM/COLD an optional follow-up
    (date/time/purpose) may be scheduled at the same time."""

    farmer_id: int
    status: LeadStatus
    reason_note: str = Field(min_length=10, max_length=2000)
    follow_up_date: date | None = None
    follow_up_time: time | None = None
    follow_up_purpose: str | None = None


# ── Follow-ups (Module 4) ────────────────────────────────────────────────
class FollowUpListItem(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    farmer_id: int | None
    farmer_name: str | None = None
    employee_id: int | None = None
    employee_name: str | None = None
    scheduled_date: date
    scheduled_time: time | None = None
    purpose: str | None = None
    status: str
    reminder_sent_24h: bool = False
    reminder_sent_1h: bool = False


class FollowUpCompleteRequest(BaseModel):
    completed_visit_id: int | None = None
