"""Notifications, sync queue, device info, audit logs, settings.

DECISIONS:
- notifications.type is a plain string (not enum): notification categories
  will grow (reminders, gps alerts, announcements...) and don't need DB-level
  enforcement — adding a Postgres enum value requires a migration each time.
- sync_queue is the server-side dead-letter/landing zone for offline batches
  that failed validation; happy-path syncs never touch this table (they go
  straight to their target tables, deduped via Redis).
- device_info: UNIQUE on fcm_token — a token identifies one device; if a user
  logs into a second device, that's a second row. last_seen updated on every
  authenticated request from the device (throttled in the service layer).
- audit_logs: critical events only per project decision (login, attendance
  changes, role changes). user_id nullable + SET NULL: audit rows must
  OUTLIVE user deletion.
- settings: user_id nullable => NULL means a global/app-level setting.
  UNIQUE (user_id, key). Note: Postgres treats NULLs as distinct in unique
  constraints; global-setting uniqueness is enforced by the partial unique
  index uq_settings_global_key below.
"""
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import INET, JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base
from app.models.enums import SyncQueueStatus


class Notification(Base):
    __tablename__ = "notifications"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    body: Mapped[str] = mapped_column(Text, nullable=False)
    type: Mapped[str] = mapped_column(String(50), nullable=False)
    is_read: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    fcm_message_id: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        # Serves both "my notifications" and "unread badge count" queries.
        Index("ix_notifications_user_read", "user_id", "is_read"),
        Index("ix_notifications_created_at", "created_at"),
    )


class SyncQueue(Base):
    __tablename__ = "sync_queue"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    entity_type: Mapped[str] = mapped_column(String(50), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=SyncQueueStatus.PENDING.value
    )  # plain varchar (not pg enum): worker-internal state, cheap to evolve;
    # values constrained to SyncQueueStatus at the service layer
    last_error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        # Worker poll: WHERE status='PENDING' ORDER BY created_at
        Index("ix_sync_queue_status_created", "status", "created_at"),
        Index("ix_sync_queue_user_id", "user_id"),
    )


class DeviceInfo(Base):
    __tablename__ = "device_info"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    fcm_token: Mapped[str | None] = mapped_column(String(512))
    device_model: Mapped[str | None] = mapped_column(String(120))
    os_version: Mapped[str | None] = mapped_column(String(50))
    app_version: Mapped[str | None] = mapped_column(String(20))
    last_seen: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        Index("ix_device_info_user_id", "user_id"),
        # Partial unique: many rows may have NULL token (FCM not yet granted).
        Index(
            "uq_device_info_fcm_token",
            "fcm_token",
            unique=True,
            postgresql_where=text("fcm_token IS NOT NULL"),
        ),
    )


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL")
    )  # nullable: audit must survive user deletion; also covers system actions
    action: Mapped[str] = mapped_column(String(100), nullable=False)
    entity_type: Mapped[str | None] = mapped_column(String(50))
    entity_id: Mapped[int | None] = mapped_column(BigInteger)
    metadata_: Mapped[dict[str, Any] | None] = mapped_column("metadata", JSONB)
    # column named "metadata" in DB; attribute is metadata_ because
    # `metadata` is reserved on SQLAlchemy declarative classes.
    ip_address: Mapped[str | None] = mapped_column(INET)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    __table_args__ = (
        Index("ix_audit_logs_user_id", "user_id"),
        Index("ix_audit_logs_created_at", "created_at"),
        Index("ix_audit_logs_entity", "entity_type", "entity_id"),
    )


class Setting(Base):
    __tablename__ = "settings"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE")
    )  # NULL => global app setting
    key: Mapped[str] = mapped_column(String(100), nullable=False)
    value: Mapped[str] = mapped_column(Text, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    __table_args__ = (
        UniqueConstraint("user_id", "key", name="uq_settings_user_key"),
        # Postgres unique constraints don't catch duplicate NULL user_id rows.
        Index(
            "uq_settings_global_key",
            "key",
            unique=True,
            postgresql_where=text("user_id IS NULL"),
        ),
    )
