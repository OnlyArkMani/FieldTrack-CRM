"""DSR attendance summary + order value (checklist #46, #49).

check_in_at/check_out_at/check_in_lat/check_in_lng let the DSR show WHEN and
WHERE the day started/ended, instead of computing them and throwing them away
(the previous behavior — see dsr_service.py). orders_value is the day's total
order value now that VisitOrder.price_per_bag exists (migration 0008).

Revision: 0010
Prev: 0009_gps_flat_5min_default
"""
import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "daily_reports",
        sa.Column("check_in_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "daily_reports",
        sa.Column("check_out_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "daily_reports", sa.Column("check_in_lat", sa.Float(), nullable=True)
    )
    op.add_column(
        "daily_reports", sa.Column("check_in_lng", sa.Float(), nullable=True)
    )
    op.add_column(
        "daily_reports",
        sa.Column("orders_value", sa.Numeric(10, 2), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("daily_reports", "orders_value")
    op.drop_column("daily_reports", "check_in_lng")
    op.drop_column("daily_reports", "check_in_lat")
    op.drop_column("daily_reports", "check_out_at")
    op.drop_column("daily_reports", "check_in_at")
