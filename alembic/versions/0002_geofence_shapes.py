"""Geofence circle support: shape_type + circle metadata columns.

The existing `zone` GEOMETRY(POLYGON,4326) column is kept and reused for BOTH
shapes — circles store a 64-point polygon approximation there so every PostGIS
spatial query (ST_Contains, ST_Area, …) stays shape-agnostic. center/radius are
stored alongside purely so the UI can render a true circle.

Revision ID: 0002
Revises: 0001
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0002"
down_revision: Union[str, None] = "0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "geofences",
        sa.Column(
            "shape_type",
            sa.String(length=10),
            nullable=False,
            server_default="POLYGON",
        ),
    )
    op.add_column("geofences", sa.Column("center_lat", sa.Float(), nullable=True))
    op.add_column("geofences", sa.Column("center_lng", sa.Float(), nullable=True))
    op.add_column(
        "geofences", sa.Column("radius_meters", sa.Float(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("geofences", "radius_meters")
    op.drop_column("geofences", "center_lng")
    op.drop_column("geofences", "center_lat")
    op.drop_column("geofences", "shape_type")
