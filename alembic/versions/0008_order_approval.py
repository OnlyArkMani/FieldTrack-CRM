"""Order approval workflow (checklist #34) + order value (checklist #49).

Adds the price captured at order time (so the DSR/order-history can show a
value, not just a bag count) and the approve/reject trail. Status itself
stays the existing free-string column (SUBMITTED/APPROVED/REJECTED) —
consistent with how visit_plans.status and daily_reports.status already work
in this codebase, no new enum type needed.

Revision: 0008
Prev: 0007_visit_photos
"""
import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "visit_orders",
        sa.Column("price_per_bag", sa.Numeric(10, 2), nullable=True),
    )
    op.add_column(
        "visit_orders",
        sa.Column(
            "approved_by",
            sa.BigInteger(),
            sa.ForeignKey("users.id"),
            nullable=True,
        ),
    )
    op.add_column(
        "visit_orders",
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "visit_orders",
        sa.Column("rejection_reason", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("visit_orders", "rejection_reason")
    op.drop_column("visit_orders", "approved_at")
    op.drop_column("visit_orders", "approved_by")
    op.drop_column("visit_orders", "price_per_bag")
