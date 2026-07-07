"""FieldCRM ORM models — 10 tables for the CRM extension.

Mirrors migration 0005. Conventions match the existing models:
- BigInteger PKs (FK columns derive their type from the referenced column).
- TimestampMixin for tables carrying both created_at + updated_at; tables with
  a single timestamp (created_at OR recorded_at OR updated_at only) declare it
  explicitly so the DDL matches the spec exactly.
- Relationships/back_populates only where a clear parent<->child pair exists
  (plan<->items, visit<->notes, farmer<->visits). Other FKs stay plain columns
  to keep the mapper graph small and unambiguous.
"""
from datetime import date as date_type
from datetime import datetime
from datetime import time as time_type
from decimal import Decimal

from sqlalchemy import (
    BigInteger,
    Boolean,
    Date,
    DateTime,
)
from sqlalchemy import Enum as SAEnum
from sqlalchemy import (
    Float,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    Time,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin


class Customer(Base, TimestampMixin):
    """Customer master record (the CRM's central entity).

    Renamed from ``farmers`` in migration 0008 and given a ``customer_type``
    discriminator (FARMER / FPO / VLCC / RETAILER). Child tables still carry a
    ``farmer_id`` FK column that now references ``customers.id`` — the column
    name is kept for wire/DB compatibility; ``Farmer`` remains an alias of this
    class at the bottom of the module."""

    __tablename__ = "customers"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    # Native PG enum ``customertype`` (created in migration 0008, RETAILER
    # added in migration 0016). Mapped with plain string members (not the
    # Python enum class) so reads return "FARMER"/"FPO"/"VLCC"/"RETAILER"
    # strings — matching the rest of the CRM's string discriminators and the
    # Pydantic Literal wire types. create_type=False: Alembic owns the type's
    # lifecycle, never metadata.create_all.
    customer_type: Mapped[str] = mapped_column(
        SAEnum("FARMER", "FPO", "VLCC", "RETAILER", name="customertype"),
        nullable=False,
        default="FARMER",
        server_default=text("'FARMER'"),
    )
    team_id: Mapped[int | None] = mapped_column(
        ForeignKey("teams.id", ondelete="SET NULL")
    )
    created_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    phone: Mapped[str | None] = mapped_column(String(20))
    village: Mapped[str | None] = mapped_column(String(200))
    district: Mapped[str | None] = mapped_column(String(200))
    address: Mapped[str | None] = mapped_column(Text)
    pincode: Mapped[str | None] = mapped_column(String(10))  # added migration 0013
    landmark: Mapped[str | None] = mapped_column(String(200))  # added migration 0013
    lat: Mapped[float | None] = mapped_column(Float)  # set on first visit
    lng: Mapped[float | None] = mapped_column(Float)
    total_cattle: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    current_feed_brand: Mapped[str | None] = mapped_column(String(200))
    current_feed_price_per_bag: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    notes: Mapped[str | None] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    visits: Mapped[list["Visit"]] = relationship(back_populates="farmer")

    __table_args__ = (
        Index("ix_customers_team_id", "team_id"),
        Index("ix_customers_created_by", "created_by"),
        Index("ix_customers_village", "village"),
        Index("ix_customers_customer_type", "customer_type"),
    )

    def __repr__(self) -> str:
        return (
            f"<Customer id={self.id} type={self.customer_type} "
            f"name={self.name!r} village={self.village!r}>"
        )


class VisitPlan(Base):
    """A field employee's plan FOR a given date (one per employee per day)."""

    __tablename__ = "visit_plans"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    plan_date: Mapped[date_type] = mapped_column(Date, nullable=False)
    submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default="DRAFT", server_default=text("'DRAFT'")
    )  # DRAFT / SUBMITTED / IN_PROGRESS / COMPLETED
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    items: Mapped[list["VisitPlanItem"]] = relationship(
        back_populates="plan", cascade="all, delete-orphan"
    )

    __table_args__ = (
        UniqueConstraint("employee_id", "plan_date", name="uq_visit_plans_employee_id_plan_date"),
    )

    def __repr__(self) -> str:
        return f"<VisitPlan id={self.id} employee_id={self.employee_id} date={self.plan_date} status={self.status}>"


class VisitPlanItem(Base):
    """One planned farmer stop within a VisitPlan."""

    __tablename__ = "visit_plan_items"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    plan_id: Mapped[int | None] = mapped_column(
        ForeignKey("visit_plans.id", ondelete="CASCADE")
    )
    farmer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"))
    sequence_order: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    time_slot: Mapped[time_type | None] = mapped_column(Time)
    purpose: Mapped[str | None] = mapped_column(String(50))
    # FIRST_VISIT / FOLLOW_UP / ORDER_COLLECTION / RELATIONSHIP_VISIT
    notes: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default="PLANNED", server_default=text("'PLANNED'")
    )  # PLANNED / COMPLETED / SKIPPED
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    plan: Mapped["VisitPlan | None"] = relationship(back_populates="items")

    __table_args__ = (Index("ix_visit_plan_items_plan_id", "plan_id"),)

    def __repr__(self) -> str:
        return f"<VisitPlanItem id={self.id} plan_id={self.plan_id} farmer_id={self.farmer_id} status={self.status}>"


class Visit(Base, TimestampMixin):
    """An executed (or in-progress) field visit to a farmer."""

    __tablename__ = "visits"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    farmer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"))
    plan_item_id: Mapped[int | None] = mapped_column(
        ForeignKey("visit_plan_items.id", ondelete="SET NULL")
    )  # null if unplanned visit
    check_in_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    check_out_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    check_in_lat: Mapped[float | None] = mapped_column(Float)
    check_in_lng: Mapped[float | None] = mapped_column(Float)
    farmer_lat: Mapped[float | None] = mapped_column(Float)
    farmer_lng: Mapped[float | None] = mapped_column(Float)
    distance_at_checkin_meters: Mapped[float | None] = mapped_column(Float)
    location_warning: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )  # true if > 200m
    location_warning_remark: Mapped[str | None] = mapped_column(Text)
    purpose: Mapped[str | None] = mapped_column(String(50))
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default="CHECKED_IN", server_default=text("'CHECKED_IN'")
    )  # CHECKED_IN / COMPLETED / ABANDONED
    # Vet requirement captured during the meeting (migration 0014). Powers the
    # Vet dashboard. vet_status: REQUESTED / SCHEDULED / DONE (null if not needed).
    vet_required: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    vet_cattle_count: Mapped[int | None] = mapped_column(Integer)
    vet_notes: Mapped[str | None] = mapped_column(Text)
    vet_status: Mapped[str | None] = mapped_column(String(20))

    farmer: Mapped["Customer | None"] = relationship(back_populates="visits")
    notes: Mapped[list["VisitNote"]] = relationship(
        back_populates="visit", cascade="all, delete-orphan"
    )

    __table_args__ = (
        Index("ix_visits_employee_id", "employee_id"),
        Index("ix_visits_farmer_id", "farmer_id"),
        Index("ix_visits_check_in_at", "check_in_at"),
    )

    def __repr__(self) -> str:
        return f"<Visit id={self.id} employee_id={self.employee_id} farmer_id={self.farmer_id} status={self.status}>"


class VisitNote(Base, TimestampMixin):
    """Guided meeting-notes form attached to a visit (steps 0-4)."""

    __tablename__ = "visit_notes"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    visit_id: Mapped[int | None] = mapped_column(
        ForeignKey("visits.id", ondelete="CASCADE")
    )
    meeting_highlights: Mapped[str | None] = mapped_column(Text)
    farmer_concerns: Mapped[str | None] = mapped_column(Text)
    product_interest: Mapped[str | None] = mapped_column(Text)
    step_completed: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))

    visit: Mapped["Visit | None"] = relationship(back_populates="notes")

    __table_args__ = (Index("ix_visit_notes_visit_id", "visit_id"),)

    def __repr__(self) -> str:
        return f"<VisitNote id={self.id} visit_id={self.visit_id} step={self.step_completed}>"


class VisitPhoto(Base):
    """A photograph attached to a visit (checklist #24). Up to 5 per visit —
    the cap is enforced in the service. Only metadata lives here; the image
    bytes live in S3 (settings.visit_photo_minio_prefix) — file_path holds the S3
    key, not a filesystem path — and are served via a presigned-URL redirect
    from the download endpoint (owner/team scoped)."""

    __tablename__ = "visit_photos"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    visit_id: Mapped[int | None] = mapped_column(
        ForeignKey("visits.id", ondelete="CASCADE")
    )
    uploaded_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    file_path: Mapped[str] = mapped_column(String(500), nullable=False)
    content_type: Mapped[str | None] = mapped_column(String(100))
    size_bytes: Mapped[int | None] = mapped_column(Integer)
    caption: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (Index("ix_visit_photos_visit_id", "visit_id"),)

    def __repr__(self) -> str:
        return f"<VisitPhoto id={self.id} visit_id={self.visit_id}>"


class LivestockProfile(Base):
    """Point-in-time livestock snapshot — new row per visit (history preserved)."""

    __tablename__ = "livestock_profiles"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    farmer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"))
    visit_id: Mapped[int | None] = mapped_column(ForeignKey("visits.id"))
    total_cattle: Mapped[int | None] = mapped_column(Integer)
    breed: Mapped[str | None] = mapped_column(String(100))  # Sahiwal/Murrah/HF Cross/Gir/Local/Other
    age_group: Mapped[str | None] = mapped_column(String(50))  # Calf/Heifer/Adult/Senior
    current_brand: Mapped[str | None] = mapped_column(String(200))
    bags_per_month: Mapped[int | None] = mapped_column(Integer)
    kg_per_animal_per_day: Mapped[Decimal | None] = mapped_column(Numeric(5, 2))
    current_price_per_bag: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    willing_to_pay_min: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    willing_to_pay_max: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    health_status: Mapped[str | None] = mapped_column(String(20))  # Excellent/Good/Fair/Poor
    health_notes: Mapped[str | None] = mapped_column(Text)
    recorded_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        Index("ix_livestock_profiles_farmer_id", "farmer_id"),
        Index("ix_livestock_profiles_visit_id", "visit_id"),
    )

    def __repr__(self) -> str:
        return f"<LivestockProfile id={self.id} farmer_id={self.farmer_id} visit_id={self.visit_id}>"


class VisitOrder(Base):
    """Order captured during a visit. status: SUBMITTED -> APPROVED/REJECTED
    (checklist #34 — manager approval)."""

    __tablename__ = "visit_orders"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    visit_id: Mapped[int | None] = mapped_column(ForeignKey("visits.id"))
    farmer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"))
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    bags_count: Mapped[int] = mapped_column(Integer, nullable=False)
    delivery_date: Mapped[date_type] = mapped_column(Date, nullable=False)  # >= today+7 (service-validated)
    delivery_address: Mapped[str | None] = mapped_column(Text)
    payment_mode: Mapped[str | None] = mapped_column(String(50))  # CASH / UPI / CREDIT
    special_notes: Mapped[str | None] = mapped_column(Text)
    # Price at order time (farmer's negotiated rate) — powers total_value here
    # and the DSR order-value line (checklist #49).
    price_per_bag: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    status: Mapped[str] = mapped_column(
        String(30), nullable=False, default="SUBMITTED", server_default=text("'SUBMITTED'")
    )  # SUBMITTED / APPROVED / REJECTED
    approved_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    rejection_reason: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        Index("ix_visit_orders_visit_id", "visit_id"),
        Index("ix_visit_orders_farmer_id", "farmer_id"),
    )

    def __repr__(self) -> str:
        return f"<VisitOrder id={self.id} farmer_id={self.farmer_id} bags={self.bags_count} status={self.status}>"


class Lead(Base):
    """Lead status change — one row per change; current = latest for farmer."""

    __tablename__ = "leads"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    farmer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"))
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    visit_id: Mapped[int | None] = mapped_column(ForeignKey("visits.id"))
    status: Mapped[str] = mapped_column(String(20), nullable=False)  # HOT / WARM / COLD
    reason_note: Mapped[str | None] = mapped_column(Text)  # required on status change without visit
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        Index("ix_leads_farmer_id", "farmer_id"),
        Index("ix_leads_employee_id", "employee_id"),
        Index("ix_leads_created_at", text("created_at DESC")),
    )

    def __repr__(self) -> str:
        return f"<Lead id={self.id} farmer_id={self.farmer_id} status={self.status}>"


class FollowUp(Base):
    """Scheduled follow-up with 24h/1h reminder tracking."""

    __tablename__ = "follow_ups"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    farmer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"))
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    visit_id: Mapped[int | None] = mapped_column(
        ForeignKey("visits.id", ondelete="SET NULL")
    )
    scheduled_date: Mapped[date_type] = mapped_column(Date, nullable=False)
    scheduled_time: Mapped[time_type | None] = mapped_column(Time)
    purpose: Mapped[str | None] = mapped_column(Text)
    reminder_sent_24h: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    reminder_sent_1h: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default="PENDING", server_default=text("'PENDING'")
    )  # PENDING / ACKNOWLEDGED / COMPLETED / ESCALATED
    completed_visit_id: Mapped[int | None] = mapped_column(
        ForeignKey("visits.id", ondelete="SET NULL")
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        Index("ix_follow_ups_employee_id", "employee_id"),
        Index("ix_follow_ups_scheduled_date", "scheduled_date"),
        Index("ix_follow_ups_status", "status"),
    )

    def __repr__(self) -> str:
        return f"<FollowUp id={self.id} farmer_id={self.farmer_id} date={self.scheduled_date} status={self.status}>"


class DailyReport(Base):
    """Daily Sales Report — auto-generated on attendance END (one per day)."""

    __tablename__ = "daily_reports"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    report_date: Mapped[date_type] = mapped_column(Date, nullable=False)
    attendance_id: Mapped[int | None] = mapped_column(ForeignKey("attendance.id"))
    visits_planned: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    visits_completed: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    visits_skipped: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    orders_captured: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    # Sum of bags_count * price_per_bag across the day's orders (checklist
    # #49) — None when none of that day's orders had a price set.
    orders_value: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    hot_leads: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    warm_leads: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    cold_leads: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    follow_ups_scheduled: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"))
    # Attendance summary (checklist #46) — captured at generation time instead
    # of being computed and discarded.
    check_in_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    check_out_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    check_in_lat: Mapped[float | None] = mapped_column(Float)
    check_in_lng: Mapped[float | None] = mapped_column(Float)
    check_out_lat: Mapped[float | None] = mapped_column(Float)  # added migration 0011
    check_out_lng: Mapped[float | None] = mapped_column(Float)
    end_of_day_note: Mapped[str | None] = mapped_column(Text)  # max 300 chars (validated in schema)
    manager_comment: Mapped[str | None] = mapped_column(Text)   # added migration 0006
    submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    is_late: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)  # after 7:30 PM
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default="DRAFT", server_default=text("'DRAFT'")
    )  # DRAFT / SUBMITTED
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        UniqueConstraint("employee_id", "report_date", name="uq_daily_reports_employee_id_report_date"),
        Index("ix_daily_reports_employee_id", "employee_id"),
        Index("ix_daily_reports_report_date", text("report_date DESC")),
    )

    def __repr__(self) -> str:
        return f"<DailyReport id={self.id} employee_id={self.employee_id} date={self.report_date} status={self.status}>"


class GpsConfig(Base):
    """Per-team GPS sampling intervals (admin-configurable). One row per team."""

    __tablename__ = "gps_config"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    team_id: Mapped[int | None] = mapped_column(
        ForeignKey("teams.id", ondelete="CASCADE")
    )
    moving_interval_seconds: Mapped[int] = mapped_column(
        Integer, default=300, server_default=text("300")
    )
    stationary_interval_seconds: Mapped[int] = mapped_column(
        Integer, default=300, server_default=text("300")
    )
    low_battery_interval_seconds: Mapped[int] = mapped_column(
        Integer, default=1200, server_default=text("1200")
    )
    low_battery_threshold: Mapped[int] = mapped_column(
        Integer, default=20, server_default=text("20")
    )
    updated_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    __table_args__ = (UniqueConstraint("team_id", name="uq_gps_config_team_id"),)

    def __repr__(self) -> str:
        return f"<GpsConfig id={self.id} team_id={self.team_id}>"


class VisitOrgAnswer(Base):
    """Shared 5-question organisation form captured on FPO / VLCC visits.

    Farmers keep the guided livestock form; FPO and VLCC customers answer one
    common 5-question set instead. One row per visit (upserted). When
    ``interested_in_supply`` is set with ``interested_bags`` > 0 the service
    also writes a real ``visit_orders`` row so the interest flows through DSR,
    reports and the manager dashboard exactly like a farmer order."""

    __tablename__ = "visit_org_answers"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    visit_id: Mapped[int | None] = mapped_column(
        ForeignKey("visits.id", ondelete="CASCADE")
    )
    farmer_id: Mapped[int | None] = mapped_column(ForeignKey("customers.id"))
    # Q1 — number of member farmers (FPO) / farmers pouring milk (VLCC)
    member_count: Mapped[int | None] = mapped_column(Integer)
    # Q2 — total cattle across members (approx)
    total_cattle: Mapped[int | None] = mapped_column(Integer)
    # Q3 — current feed brand / procurement channel
    current_brand: Mapped[str | None] = mapped_column(String(200))
    # Q4 — monthly feed requirement (bags/month)
    monthly_bags: Mapped[int | None] = mapped_column(Integer)
    # Q5 — interested in supply? -> bags requested (drives order capture)
    interested_in_supply: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    interested_bags: Mapped[int | None] = mapped_column(Integer)
    notes: Mapped[str | None] = mapped_column(Text)
    recorded_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        Index("ix_visit_org_answers_visit_id", "visit_id"),
        Index("ix_visit_org_answers_farmer_id", "farmer_id"),
    )

    def __repr__(self) -> str:
        return (
            f"<VisitOrgAnswer id={self.id} visit_id={self.visit_id} "
            f"interested={self.interested_in_supply}>"
        )


# ── Backwards-compat alias ───────────────────────────────────────────────
# The table was renamed farmers -> customers in 0008, but a large amount of
# service/repository code (and the mobile/web JSON contract) still refers to
# "farmer". Keeping this alias lets that code keep importing ``Farmer`` while
# new code uses the clearer ``Customer`` name.
Farmer = Customer
