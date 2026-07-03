"""Flatten default GPS cadence to 5 minutes (checklist #16).

Moving and stationary intervals both default to 300s (5 min) instead of the
prior adaptive 180s/720s split. Low-battery interval (1200s) is left as-is —
an intentional exception to protect device battery late in a shift. Existing
per-team rows are left untouched; this only changes what new teams (and the
"no row yet" fallback served by GET /gps-config/my) get by default.

Revision: 0008
Prev: 0007_visit_photos
"""
from alembic import op

# revision identifiers, used by Alembic.
revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column(
        "gps_config",
        "moving_interval_seconds",
        server_default="300",
    )
    op.alter_column(
        "gps_config",
        "stationary_interval_seconds",
        server_default="300",
    )


def downgrade() -> None:
    op.alter_column(
        "gps_config",
        "moving_interval_seconds",
        server_default="180",
    )
    op.alter_column(
        "gps_config",
        "stationary_interval_seconds",
        server_default="720",
    )
