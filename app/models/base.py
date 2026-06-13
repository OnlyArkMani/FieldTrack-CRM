"""Declarative base with naming conventions + shared mixins.

Naming convention matters: without it, Alembic autogenerate produces unnamed
constraints that can't be dropped deterministically in later migrations.
All timestamps are timezone-aware (timestamptz) — server in UTC, mobile
clients localize. Never store naive datetimes.
"""
from datetime import datetime

from sqlalchemy import MetaData, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.types import DateTime

NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)


class TimestampMixin:
    """created_at set by the DB (server_default), updated_at maintained by
    SQLAlchemy onupdate — DB-side defaults survive raw-SQL inserts too."""

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
