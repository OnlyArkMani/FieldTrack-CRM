"""Add current_price_per_bag to visit_org_answers (FPO/VLCC/Retailer step 2).

WHAT CHANGES
- ``visit_org_answers.current_price_per_bag`` NUMERIC(10,2) NULL — the price
  per bag the org currently pays, mirroring livestock_profiles'
  current_price_per_bag for farmers. Also used as the price_per_bag on the
  auto-created visit_orders row when Q5 "interested in supply" is answered.

Revision: 0017
Prev: 0016_customer_type_retailer
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0017"
down_revision: Union[str, None] = "0016"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "visit_org_answers",
        sa.Column("current_price_per_bag", sa.Numeric(10, 2), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("visit_org_answers", "current_price_per_bag")
