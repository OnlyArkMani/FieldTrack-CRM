"""Geofence team assignment: scope (UNIVERSAL | TEAM) + optional team_id.

Adds two columns to `geofences`:
- team_id  -> nullable FK to teams(id), ON DELETE SET NULL. NULL == universal.
- scope    -> VARCHAR(10) NOT NULL DEFAULT 'UNIVERSAL' ('UNIVERSAL' | 'TEAM').

Existing rows safely become UNIVERSAL (scope default + team_id NULL) — no data
loss. Index on team_id keeps the "geofences for my team" filter fast.

This single migration also underpins Change 4 (Geofence Compliance report),
which reads geofences.scope / geofences.team_id but needs no further DDL.

Revision ID: 0004
Revises: 0003
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0004"
down_revision: Union[str, None] = "0003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # team_id: BigInteger to match teams.id (FK column types must agree).
    op.add_column(
        "geofences",
        sa.Column("team_id", sa.BigInteger(), nullable=True),
    )
    op.create_foreign_key(
        "fk_geofences_team_id_teams",
        "geofences",
        "teams",
        ["team_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.add_column(
        "geofences",
        sa.Column(
            "scope",
            sa.String(length=10),
            nullable=False,
            server_default=sa.text("'UNIVERSAL'"),
        ),
    )
    op.create_index("idx_geofences_team_id", "geofences", ["team_id"])


def downgrade() -> None:
    op.drop_index("idx_geofences_team_id", table_name="geofences")
    op.drop_constraint(
        "fk_geofences_team_id_teams", "geofences", type_="foreignkey"
    )
    op.drop_column("geofences", "scope")
    op.drop_column("geofences", "team_id")
