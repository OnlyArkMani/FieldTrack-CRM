"""Backfill customer team_id for unassigned customers created by team members.

Revision: 0031
Prev: 0030
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0031"
down_revision: Union[str, None] = "0030"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        UPDATE customers
        SET team_id = users.team_id
        FROM users
        WHERE customers.created_by = users.id
          AND customers.team_id IS NULL
          AND users.team_id IS NOT NULL
        """
    )


def downgrade() -> None:
    # Data backfill downgrade is intentionally a no-op.
    pass
