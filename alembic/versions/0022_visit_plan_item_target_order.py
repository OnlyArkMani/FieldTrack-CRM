
"""Add target_order_bags to visit_plan_items.

WHAT CHANGES
- ``visit_plan_items`` gains ``target_order_bags`` (nullable int) — the number
  of bags the executive is aiming to sell/collect an order for at that
  planned stop, set at planning time. Nullable; existing rows unaffected.

Revision: 0022
Prev: 0021_customer_type_distributor
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0022"
down_revision: Union[str, None] = "0021"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "visit_plan_items",
        sa.Column("target_order_bags", sa.Integer(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("visit_plan_items", "target_order_bags")
