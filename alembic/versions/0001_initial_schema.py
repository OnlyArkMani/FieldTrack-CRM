"""Initial schema — all 13 tables, PostGIS extension, enums, indexes.

Revision ID: 0001
Revises:
Create Date: 2026-06-11

CREATE ORDER (FK-safe):
  postgis ext -> teams (without supervisor FK) -> users -> ALTER teams
  (add supervisor FK; breaks the users<->teams cycle) -> attendance ->
  attendance_sessions -> location_logs -> geofences -> geofence_events ->
  notifications -> sync_queue -> device_info -> audit_logs -> settings
"""
from typing import Sequence, Union

import geoalchemy2
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

user_role = sa.Enum("ADMIN", "SUPERVISOR", "EMPLOYEE", name="user_role")
attendance_status = sa.Enum("PRESENT", "ABSENT", "HALF_DAY", name="attendance_status")
session_type = sa.Enum("START", "BREAK", "RESUME", "END", name="session_type")
sync_status = sa.Enum("PENDING", "SYNCED", "FAILED", name="sync_status")
geofence_event_type = sa.Enum("ENTER", "EXIT", name="geofence_event_type")


def upgrade() -> None:
    # PostGIS: the postgis/postgis docker image pre-installs this, but the
    # guard makes the migration portable to any Postgres 15 with PostGIS available.
    op.execute("CREATE EXTENSION IF NOT EXISTS postgis")

    # ── teams (supervisor FK added after users exists) ─────────────────
    op.create_table(
        "teams",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("name", sa.String(120), nullable=False, unique=True),
        sa.Column("description", sa.String(500)),
        sa.Column("supervisor_id", sa.BigInteger()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_teams_supervisor_id", "teams", ["supervisor_id"])

    # ── users ──────────────────────────────────────────────────────────
    op.create_table(
        "users",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("email", sa.String(254), nullable=False, unique=True),
        sa.Column("phone", sa.String(20), unique=True),
        sa.Column("password_hash", sa.String(128), nullable=False),
        sa.Column("role", user_role, nullable=False),
        sa.Column("team_id", sa.BigInteger(), sa.ForeignKey("teams.id", ondelete="SET NULL")),
        sa.Column("profile_photo_url", sa.String(500)),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_users_email", "users", ["email"])
    op.create_index("ix_users_team_id", "users", ["team_id"])
    op.create_index("ix_users_role", "users", ["role"])

    # Close the circular FK now that users exists.
    op.create_foreign_key(
        "fk_teams_supervisor_id_users",
        "teams", "users",
        ["supervisor_id"], ["id"],
        ondelete="SET NULL",
    )

    # ── attendance ─────────────────────────────────────────────────────
    op.create_table(
        "attendance",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("date", sa.Date(), nullable=False),
        sa.Column("status", attendance_status, nullable=False),
        sa.Column("total_duration_minutes", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("total_distance_meters", sa.Float(), nullable=False, server_default="0"),
        sa.Column("work_summary", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("user_id", "date", name="uq_attendance_user_date"),
    )
    op.create_index("ix_attendance_user_id", "attendance", ["user_id"])
    op.create_index("ix_attendance_date", "attendance", ["date"])

    # ── attendance_sessions ────────────────────────────────────────────
    op.create_table(
        "attendance_sessions",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("attendance_id", sa.BigInteger(), sa.ForeignKey("attendance.id", ondelete="CASCADE"), nullable=False),
        sa.Column("type", session_type, nullable=False),
        sa.Column("timestamp", sa.DateTime(timezone=True), nullable=False),
        sa.Column("lat", sa.Float()),
        sa.Column("lng", sa.Float()),
        sa.Column("notes", sa.String(500)),
    )
    op.create_index("ix_attendance_sessions_attendance_id", "attendance_sessions", ["attendance_id"])
    op.create_index("ix_attendance_sessions_timestamp", "attendance_sessions", ["timestamp"])

    # ── location_logs ──────────────────────────────────────────────────
    op.create_table(
        "location_logs",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("lat", sa.Float(), nullable=False),
        sa.Column("lng", sa.Float(), nullable=False),
        sa.Column("timestamp", sa.DateTime(timezone=True), nullable=False),
        sa.Column("accuracy", sa.Float()),
        sa.Column("speed", sa.Float()),
        sa.Column("battery_level", sa.Integer()),
        sa.Column("is_mock_gps", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("sync_status", sync_status, nullable=False, server_default="SYNCED"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_location_logs_user_ts", "location_logs", ["user_id", "timestamp"])
    op.create_index(
        "ix_location_logs_pending",
        "location_logs",
        ["sync_status"],
        postgresql_where=sa.text("sync_status = 'PENDING'"),
    )

    # ── geofences (PostGIS) ────────────────────────────────────────────
    op.create_table(
        "geofences",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("description", sa.String(500)),
        sa.Column(
            "zone",
            geoalchemy2.Geometry(geometry_type="POLYGON", srid=4326, spatial_index=False),
            nullable=False,
        ),
        sa.Column("created_by", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="SET NULL")),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_geofences_zone", "geofences", ["zone"], postgresql_using="gist")

    # ── geofence_events ────────────────────────────────────────────────
    op.create_table(
        "geofence_events",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("geofence_id", sa.BigInteger(), sa.ForeignKey("geofences.id", ondelete="CASCADE"), nullable=False),
        sa.Column("event_type", geofence_event_type, nullable=False),
        sa.Column("timestamp", sa.DateTime(timezone=True), nullable=False),
        sa.Column("lat", sa.Float(), nullable=False),
        sa.Column("lng", sa.Float(), nullable=False),
    )
    op.create_index("ix_geofence_events_user_ts", "geofence_events", ["user_id", "timestamp"])
    op.create_index("ix_geofence_events_geofence_id", "geofence_events", ["geofence_id"])

    # ── notifications ──────────────────────────────────────────────────
    op.create_table(
        "notifications",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("type", sa.String(50), nullable=False),
        sa.Column("is_read", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("fcm_message_id", sa.String(200)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_notifications_user_read", "notifications", ["user_id", "is_read"])
    op.create_index("ix_notifications_created_at", "notifications", ["created_at"])

    # ── sync_queue ─────────────────────────────────────────────────────
    op.create_table(
        "sync_queue",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("entity_type", sa.String(50), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("status", sa.String(20), nullable=False, server_default="PENDING"),
        sa.Column("last_error", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_sync_queue_status_created", "sync_queue", ["status", "created_at"])
    op.create_index("ix_sync_queue_user_id", "sync_queue", ["user_id"])

    # ── device_info ────────────────────────────────────────────────────
    op.create_table(
        "device_info",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("fcm_token", sa.String(512)),
        sa.Column("device_model", sa.String(120)),
        sa.Column("os_version", sa.String(50)),
        sa.Column("app_version", sa.String(20)),
        sa.Column("last_seen", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_device_info_user_id", "device_info", ["user_id"])
    op.create_index(
        "uq_device_info_fcm_token",
        "device_info",
        ["fcm_token"],
        unique=True,
        postgresql_where=sa.text("fcm_token IS NOT NULL"),
    )

    # ── audit_logs ─────────────────────────────────────────────────────
    op.create_table(
        "audit_logs",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="SET NULL")),
        sa.Column("action", sa.String(100), nullable=False),
        sa.Column("entity_type", sa.String(50)),
        sa.Column("entity_id", sa.BigInteger()),
        sa.Column("metadata", postgresql.JSONB()),
        sa.Column("ip_address", postgresql.INET()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )
    op.create_index("ix_audit_logs_user_id", "audit_logs", ["user_id"])
    op.create_index("ix_audit_logs_created_at", "audit_logs", ["created_at"])
    op.create_index("ix_audit_logs_entity", "audit_logs", ["entity_type", "entity_id"])

    # ── settings ───────────────────────────────────────────────────────
    op.create_table(
        "settings",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("users.id", ondelete="CASCADE")),
        sa.Column("key", sa.String(100), nullable=False),
        sa.Column("value", sa.Text(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("user_id", "key", name="uq_settings_user_key"),
    )
    op.create_index(
        "uq_settings_global_key",
        "settings",
        ["key"],
        unique=True,
        postgresql_where=sa.text("user_id IS NULL"),
    )


def downgrade() -> None:
    # Reverse FK order; drop the circular FK first.
    op.drop_constraint("fk_teams_supervisor_id_users", "teams", type_="foreignkey")
    for table in (
        "settings",
        "audit_logs",
        "device_info",
        "sync_queue",
        "notifications",
        "geofence_events",
        "geofences",
        "location_logs",
        "attendance_sessions",
        "attendance",
        "users",
        "teams",
    ):
        op.drop_table(table)
    for enum in (user_role, attendance_status, session_type, sync_status, geofence_event_type):
        enum.drop(op.get_bind(), checkfirst=True)
    # Deliberately NOT dropping the postgis extension — other DBs may share it.
