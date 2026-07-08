"""Add reminder_sent to visit_plan_items (planned-visit reminder push).

WHAT CHANGES
- ``visit_plan_items.reminder_sent`` BOOLEAN NOT NULL DEFAULT false — flipped
  by the scheduler once a reminder push has fired for that item, so a
  30-minute-cadence job never double-sends across ticks/misfires.

Revision: 0018
Prev: 0017_org_answers_price_per_bag
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0018"
down_revision: Union[str, None] = "0017"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "visit_plan_items",
        sa.Column(
            "reminder_sent",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )


def downgrade() -> None:
    op.drop_column("visit_plan_items", "reminder_sent")
