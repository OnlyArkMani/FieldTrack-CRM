"""Attendance day record + its START/BREAK/RESUME/END sessions.

DECISIONS:
- UNIQUE (user_id, date): one attendance row per user per day — the state
  machine (START..END) lives in attendance_sessions rows under it.
- total_duration_minutes / total_distance_meters are denormalized rollups
  computed on END (and recomputed by the nightly worker as a safety net).
  Reads (dashboard, reports) vastly outnumber writes — denormalization wins.
- lat/lng on sessions are plain floats (point-in-time capture, no spatial
  queries needed on them — geofence math happens against location_logs).
- ondelete=CASCADE: deleting a user legitimately removes their attendance.
"""
from datetime import date as date_type
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    Date,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin
from app.models.enums import AttendanceStatus, SessionType


class Attendance(Base, TimestampMixin):
    __tablename__ = "attendance"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    date: Mapped[date_type] = mapped_column(Date, nullable=False)
    status: Mapped[AttendanceStatus] = mapped_column(
        Enum(AttendanceStatus, name="attendance_status"),
        nullable=False,
        default=AttendanceStatus.PRESENT,
    )
    total_duration_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    total_distance_meters: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    work_summary: Mapped[str | None] = mapped_column(Text)

    sessions: Mapped[list["AttendanceSession"]] = relationship(
        back_populates="attendance",
        cascade="all, delete-orphan",
        order_by="AttendanceSession.timestamp",
    )

    __table_args__ = (
        UniqueConstraint("user_id", "date", name="uq_attendance_user_date"),
        Index("ix_attendance_user_id", "user_id"),
        Index("ix_attendance_date", "date"),
    )


class AttendanceSession(Base):
    __tablename__ = "attendance_sessions"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    attendance_id: Mapped[int] = mapped_column(
        ForeignKey("attendance.id", ondelete="CASCADE"), nullable=False
    )
    type: Mapped[SessionType] = mapped_column(
        Enum(SessionType, name="session_type"), nullable=False
    )
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    lat: Mapped[float | None] = mapped_column(Float)
    lng: Mapped[float | None] = mapped_column(Float)
    notes: Mapped[str | None] = mapped_column(String(500))

    attendance: Mapped["Attendance"] = relationship(back_populates="sessions")

    __table_args__ = (
        Index("ix_attendance_sessions_attendance_id", "attendance_id"),
        Index("ix_attendance_sessions_timestamp", "timestamp"),
    )
