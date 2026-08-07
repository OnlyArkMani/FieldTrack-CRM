"""Add late_checkout_reason to attendance and daily_reports tables.

Revision: 0030
Prev: 0029
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0030"
down_revision: Union[str, None] = "0029"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "attendance",
        sa.Column("late_checkout_reason", sa.Text(), nullable=True),
    )
    op.add_column(
        "daily_reports",
        sa.Column("late_checkout_reason", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("daily_reports", "late_checkout_reason")
    op.drop_column("attendance", "late_checkout_reason")
