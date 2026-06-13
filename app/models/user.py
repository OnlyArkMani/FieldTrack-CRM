"""User and Team models.

DECISIONS:
- ASSUMPTION: spec omitted a password column but JWT auth requires one —
  added `password_hash` (bcrypt). Nullable=False; seed admin via script.
- users.team_id <-> teams.supervisor_id is a circular FK. teams.supervisor_id
  uses use_alter=True so create order is teams -> users -> ALTER TABLE teams.
- team_id is nullable: admins don't belong to teams, and employees may be
  created before assignment.
- email is the login identifier — unique + indexed. phone unique too (used
  for support lookups), but nullable.
"""
from sqlalchemy import BigInteger, Boolean, Enum, ForeignKey, Index, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin
from app.models.enums import UserRole


class User(Base, TimestampMixin):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    email: Mapped[str] = mapped_column(String(254), unique=True, index=True, nullable=False)
    phone: Mapped[str | None] = mapped_column(String(20), unique=True)
    password_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    role: Mapped[UserRole] = mapped_column(
        Enum(UserRole, name="user_role"), nullable=False, default=UserRole.EMPLOYEE
    )
    team_id: Mapped[int | None] = mapped_column(
        ForeignKey("teams.id", ondelete="SET NULL")
    )
    profile_photo_url: Mapped[str | None] = mapped_column(String(500))
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    team: Mapped["Team | None"] = relationship(
        back_populates="members", foreign_keys=[team_id]
    )

    __table_args__ = (
        Index("ix_users_team_id", "team_id"),
        Index("ix_users_role", "role"),
    )


class Team(Base, TimestampMixin):
    __tablename__ = "teams"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True, nullable=False)
    description: Mapped[str | None] = mapped_column(String(500))
    # use_alter=True breaks the users<->teams FK cycle: this FK is added via
    # ALTER TABLE after both tables exist.
    supervisor_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL", use_alter=True,
                   name="fk_teams_supervisor_id_users")
    )

    supervisor: Mapped["User | None"] = relationship(foreign_keys=[supervisor_id])
    members: Mapped[list["User"]] = relationship(
        back_populates="team", foreign_keys="User.team_id"
    )

    __table_args__ = (Index("ix_teams_supervisor_id", "supervisor_id"),)
