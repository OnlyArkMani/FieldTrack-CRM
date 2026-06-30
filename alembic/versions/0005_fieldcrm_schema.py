"""FieldCRM schema — 10 new CRM tables layered on top of FieldTrack.

Adds the Customer/Farmer DB, Visit Planning, Visit Execution + Notes +
Livestock, Lead Management, Daily Sales Report and per-team GPS config modules.

CONVENTIONS (match existing tables):
- BigInteger PKs (BIGSERIAL). Existing tables (users/teams/attendance/...) all
  use BigInteger and migration 0004 documents that "FK column types must agree",
  so every FK column here is BigInteger to stay join-compatible. The spec's
  "SERIAL" means "auto-increment PK"; BIGSERIAL satisfies that.
- created_at/updated_at are timestamptz with server-side defaults.
- FK constraints are explicitly named (deterministic drops in later migrations).
- No existing table is modified — this migration is purely additive.

Creation order respects FK dependencies; downgrade drops in reverse.

Revision ID: 0005
Revises: 0004
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0005"
down_revision: Union[str, None] = "0004"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ── farmers ──────────────────────────────────────────────────────────
    op.create_table(
        "farmers",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("team_id", sa.BigInteger(), nullable=True),
        sa.Column("created_by", sa.BigInteger(), nullable=True),
        sa.Column("name", sa.String(length=200), nullable=False),
        sa.Column("phone", sa.String(length=20), nullable=True),
        sa.Column("village", sa.String(length=200), nullable=True),
        sa.Column("district", sa.String(length=200), nullable=True),
        sa.Column("address", sa.Text(), nullable=True),
        sa.Column("lat", sa.Float(), nullable=True),
        sa.Column("lng", sa.Float(), nullable=True),
        sa.Column("total_cattle", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("current_feed_brand", sa.String(length=200), nullable=True),
        sa.Column("current_feed_price_per_bag", sa.Numeric(10, 2), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("is_active", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["team_id"], ["teams.id"], name="fk_farmers_team_id_teams", ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], name="fk_farmers_created_by_users"),
        sa.PrimaryKeyConstraint("id", name="pk_farmers"),
    )
    op.create_index("ix_farmers_team_id", "farmers", ["team_id"])
    op.create_index("ix_farmers_created_by", "farmers", ["created_by"])
    op.create_index("ix_farmers_village", "farmers", ["village"])

    # ── visit_plans ──────────────────────────────────────────────────────
    op.create_table(
        "visit_plans",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("employee_id", sa.BigInteger(), nullable=True),
        sa.Column("plan_date", sa.Date(), nullable=False),
        sa.Column("submitted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("status", sa.String(length=20), server_default=sa.text("'DRAFT'"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["employee_id"], ["users.id"], name="fk_visit_plans_employee_id_users"),
        sa.PrimaryKeyConstraint("id", name="pk_visit_plans"),
        sa.UniqueConstraint("employee_id", "plan_date", name="uq_visit_plans_employee_id_plan_date"),
    )

    # ── visit_plan_items ─────────────────────────────────────────────────
    op.create_table(
        "visit_plan_items",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("plan_id", sa.BigInteger(), nullable=True),
        sa.Column("farmer_id", sa.BigInteger(), nullable=True),
        sa.Column("sequence_order", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("time_slot", sa.Time(), nullable=True),
        sa.Column("purpose", sa.String(length=50), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("status", sa.String(length=20), server_default=sa.text("'PLANNED'"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["plan_id"], ["visit_plans.id"], name="fk_visit_plan_items_plan_id_visit_plans", ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["farmer_id"], ["farmers.id"], name="fk_visit_plan_items_farmer_id_farmers"),
        sa.PrimaryKeyConstraint("id", name="pk_visit_plan_items"),
    )
    op.create_index("ix_visit_plan_items_plan_id", "visit_plan_items", ["plan_id"])

    # ── visits ───────────────────────────────────────────────────────────
    op.create_table(
        "visits",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("employee_id", sa.BigInteger(), nullable=True),
        sa.Column("farmer_id", sa.BigInteger(), nullable=True),
        sa.Column("plan_item_id", sa.BigInteger(), nullable=True),
        sa.Column("check_in_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("check_out_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("check_in_lat", sa.Float(), nullable=True),
        sa.Column("check_in_lng", sa.Float(), nullable=True),
        sa.Column("farmer_lat", sa.Float(), nullable=True),
        sa.Column("farmer_lng", sa.Float(), nullable=True),
        sa.Column("distance_at_checkin_meters", sa.Float(), nullable=True),
        sa.Column("location_warning", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("location_warning_remark", sa.Text(), nullable=True),
        sa.Column("purpose", sa.String(length=50), nullable=True),
        sa.Column("status", sa.String(length=20), server_default=sa.text("'CHECKED_IN'"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["employee_id"], ["users.id"], name="fk_visits_employee_id_users"),
        sa.ForeignKeyConstraint(["farmer_id"], ["farmers.id"], name="fk_visits_farmer_id_farmers"),
        sa.ForeignKeyConstraint(["plan_item_id"], ["visit_plan_items.id"], name="fk_visits_plan_item_id_visit_plan_items", ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id", name="pk_visits"),
    )
    op.create_index("ix_visits_employee_id", "visits", ["employee_id"])
    op.create_index("ix_visits_farmer_id", "visits", ["farmer_id"])
    op.create_index("ix_visits_check_in_at", "visits", ["check_in_at"])

    # ── visit_notes ──────────────────────────────────────────────────────
    op.create_table(
        "visit_notes",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("visit_id", sa.BigInteger(), nullable=True),
        sa.Column("meeting_highlights", sa.Text(), nullable=True),
        sa.Column("farmer_concerns", sa.Text(), nullable=True),
        sa.Column("product_interest", sa.Text(), nullable=True),
        sa.Column("step_completed", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["visit_id"], ["visits.id"], name="fk_visit_notes_visit_id_visits", ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id", name="pk_visit_notes"),
    )
    op.create_index("ix_visit_notes_visit_id", "visit_notes", ["visit_id"])

    # ── livestock_profiles ───────────────────────────────────────────────
    op.create_table(
        "livestock_profiles",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("farmer_id", sa.BigInteger(), nullable=True),
        sa.Column("visit_id", sa.BigInteger(), nullable=True),
        sa.Column("total_cattle", sa.Integer(), nullable=True),
        sa.Column("breed", sa.String(length=100), nullable=True),
        sa.Column("age_group", sa.String(length=50), nullable=True),
        sa.Column("current_brand", sa.String(length=200), nullable=True),
        sa.Column("bags_per_month", sa.Integer(), nullable=True),
        sa.Column("kg_per_animal_per_day", sa.Numeric(5, 2), nullable=True),
        sa.Column("current_price_per_bag", sa.Numeric(10, 2), nullable=True),
        sa.Column("willing_to_pay_min", sa.Numeric(10, 2), nullable=True),
        sa.Column("willing_to_pay_max", sa.Numeric(10, 2), nullable=True),
        sa.Column("health_status", sa.String(length=20), nullable=True),
        sa.Column("health_notes", sa.Text(), nullable=True),
        sa.Column("recorded_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["farmer_id"], ["farmers.id"], name="fk_livestock_profiles_farmer_id_farmers"),
        sa.ForeignKeyConstraint(["visit_id"], ["visits.id"], name="fk_livestock_profiles_visit_id_visits"),
        sa.PrimaryKeyConstraint("id", name="pk_livestock_profiles"),
    )
    op.create_index("ix_livestock_profiles_farmer_id", "livestock_profiles", ["farmer_id"])
    op.create_index("ix_livestock_profiles_visit_id", "livestock_profiles", ["visit_id"])

    # ── visit_orders ─────────────────────────────────────────────────────
    op.create_table(
        "visit_orders",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("visit_id", sa.BigInteger(), nullable=True),
        sa.Column("farmer_id", sa.BigInteger(), nullable=True),
        sa.Column("employee_id", sa.BigInteger(), nullable=True),
        sa.Column("bags_count", sa.Integer(), nullable=False),
        sa.Column("delivery_date", sa.Date(), nullable=False),
        sa.Column("delivery_address", sa.Text(), nullable=True),
        sa.Column("payment_mode", sa.String(length=50), nullable=True),
        sa.Column("special_notes", sa.Text(), nullable=True),
        sa.Column("status", sa.String(length=30), server_default=sa.text("'SUBMITTED'"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["visit_id"], ["visits.id"], name="fk_visit_orders_visit_id_visits"),
        sa.ForeignKeyConstraint(["farmer_id"], ["farmers.id"], name="fk_visit_orders_farmer_id_farmers"),
        sa.ForeignKeyConstraint(["employee_id"], ["users.id"], name="fk_visit_orders_employee_id_users"),
        sa.PrimaryKeyConstraint("id", name="pk_visit_orders"),
    )
    op.create_index("ix_visit_orders_visit_id", "visit_orders", ["visit_id"])
    op.create_index("ix_visit_orders_farmer_id", "visit_orders", ["farmer_id"])

    # ── leads ────────────────────────────────────────────────────────────
    op.create_table(
        "leads",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("farmer_id", sa.BigInteger(), nullable=True),
        sa.Column("employee_id", sa.BigInteger(), nullable=True),
        sa.Column("visit_id", sa.BigInteger(), nullable=True),
        sa.Column("status", sa.String(length=20), nullable=False),
        sa.Column("reason_note", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["farmer_id"], ["farmers.id"], name="fk_leads_farmer_id_farmers"),
        sa.ForeignKeyConstraint(["employee_id"], ["users.id"], name="fk_leads_employee_id_users"),
        sa.ForeignKeyConstraint(["visit_id"], ["visits.id"], name="fk_leads_visit_id_visits"),
        sa.PrimaryKeyConstraint("id", name="pk_leads"),
    )
    op.create_index("ix_leads_farmer_id", "leads", ["farmer_id"])
    op.create_index("ix_leads_employee_id", "leads", ["employee_id"])
    # DESC: "current status = latest row for farmer" reads newest-first.
    op.create_index("ix_leads_created_at", "leads", [sa.text("created_at DESC")])

    # ── follow_ups ───────────────────────────────────────────────────────
    op.create_table(
        "follow_ups",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("farmer_id", sa.BigInteger(), nullable=True),
        sa.Column("employee_id", sa.BigInteger(), nullable=True),
        sa.Column("visit_id", sa.BigInteger(), nullable=True),
        sa.Column("scheduled_date", sa.Date(), nullable=False),
        sa.Column("scheduled_time", sa.Time(), nullable=True),
        sa.Column("purpose", sa.Text(), nullable=True),
        sa.Column("reminder_sent_24h", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("reminder_sent_1h", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("status", sa.String(length=20), server_default=sa.text("'PENDING'"), nullable=False),
        sa.Column("completed_visit_id", sa.BigInteger(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["farmer_id"], ["farmers.id"], name="fk_follow_ups_farmer_id_farmers"),
        sa.ForeignKeyConstraint(["employee_id"], ["users.id"], name="fk_follow_ups_employee_id_users"),
        sa.ForeignKeyConstraint(["visit_id"], ["visits.id"], name="fk_follow_ups_visit_id_visits", ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["completed_visit_id"], ["visits.id"], name="fk_follow_ups_completed_visit_id_visits", ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id", name="pk_follow_ups"),
    )
    op.create_index("ix_follow_ups_employee_id", "follow_ups", ["employee_id"])
    op.create_index("ix_follow_ups_scheduled_date", "follow_ups", ["scheduled_date"])
    op.create_index("ix_follow_ups_status", "follow_ups", ["status"])

    # ── daily_reports ────────────────────────────────────────────────────
    op.create_table(
        "daily_reports",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("employee_id", sa.BigInteger(), nullable=True),
        sa.Column("report_date", sa.Date(), nullable=False),
        sa.Column("attendance_id", sa.BigInteger(), nullable=True),
        sa.Column("visits_planned", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("visits_completed", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("visits_skipped", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("orders_captured", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("hot_leads", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("warm_leads", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("cold_leads", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("follow_ups_scheduled", sa.Integer(), server_default=sa.text("0"), nullable=True),
        sa.Column("end_of_day_note", sa.Text(), nullable=True),
        sa.Column("submitted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("is_late", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("status", sa.String(length=20), server_default=sa.text("'DRAFT'"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["employee_id"], ["users.id"], name="fk_daily_reports_employee_id_users"),
        sa.ForeignKeyConstraint(["attendance_id"], ["attendance.id"], name="fk_daily_reports_attendance_id_attendance"),
        sa.PrimaryKeyConstraint("id", name="pk_daily_reports"),
        sa.UniqueConstraint("employee_id", "report_date", name="uq_daily_reports_employee_id_report_date"),
    )
    op.create_index("ix_daily_reports_employee_id", "daily_reports", ["employee_id"])
    op.create_index("ix_daily_reports_report_date", "daily_reports", [sa.text("report_date DESC")])

    # ── gps_config ───────────────────────────────────────────────────────
    op.create_table(
        "gps_config",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("team_id", sa.BigInteger(), nullable=True),
        sa.Column("moving_interval_seconds", sa.Integer(), server_default=sa.text("180"), nullable=True),
        sa.Column("stationary_interval_seconds", sa.Integer(), server_default=sa.text("720"), nullable=True),
        sa.Column("low_battery_interval_seconds", sa.Integer(), server_default=sa.text("1200"), nullable=True),
        sa.Column("low_battery_threshold", sa.Integer(), server_default=sa.text("20"), nullable=True),
        sa.Column("updated_by", sa.BigInteger(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["team_id"], ["teams.id"], name="fk_gps_config_team_id_teams", ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["updated_by"], ["users.id"], name="fk_gps_config_updated_by_users"),
        sa.PrimaryKeyConstraint("id", name="pk_gps_config"),
        sa.UniqueConstraint("team_id", name="uq_gps_config_team_id"),
    )


def downgrade() -> None:
    op.drop_table("gps_config")
    op.drop_index("ix_daily_reports_report_date", table_name="daily_reports")
    op.drop_index("ix_daily_reports_employee_id", table_name="daily_reports")
    op.drop_table("daily_reports")
    op.drop_index("ix_follow_ups_status", table_name="follow_ups")
    op.drop_index("ix_follow_ups_scheduled_date", table_name="follow_ups")
    op.drop_index("ix_follow_ups_employee_id", table_name="follow_ups")
    op.drop_table("follow_ups")
    op.drop_index("ix_leads_created_at", table_name="leads")
    op.drop_index("ix_leads_employee_id", table_name="leads")
    op.drop_index("ix_leads_farmer_id", table_name="leads")
    op.drop_table("leads")
    op.drop_index("ix_visit_orders_farmer_id", table_name="visit_orders")
    op.drop_index("ix_visit_orders_visit_id", table_name="visit_orders")
    op.drop_table("visit_orders")
    op.drop_index("ix_livestock_profiles_visit_id", table_name="livestock_profiles")
    op.drop_index("ix_livestock_profiles_farmer_id", table_name="livestock_profiles")
    op.drop_table("livestock_profiles")
    op.drop_index("ix_visit_notes_visit_id", table_name="visit_notes")
    op.drop_table("visit_notes")
    op.drop_index("ix_visits_check_in_at", table_name="visits")
    op.drop_index("ix_visits_farmer_id", table_name="visits")
    op.drop_index("ix_visits_employee_id", table_name="visits")
    op.drop_table("visits")
    op.drop_index("ix_visit_plan_items_plan_id", table_name="visit_plan_items")
    op.drop_table("visit_plan_items")
    op.drop_table("visit_plans")
    op.drop_index("ix_farmers_village", table_name="farmers")
    op.drop_index("ix_farmers_created_by", table_name="farmers")
    op.drop_index("ix_farmers_team_id", table_name="farmers")
    op.drop_table("farmers")
