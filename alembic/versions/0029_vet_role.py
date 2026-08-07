"""Add VET value to the user_role Postgres ENUM.

Postgres does not support removing enum values once added, so the downgrade
is intentionally a no-op (the unused value stays in the type, harmless).
ALTER TYPE ... ADD VALUE acquires no table lock — safe for zero-downtime deploy.

Revision: 0029
Prev: 0028
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0029"
down_revision: Union[str, None] = "0028"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'VET'")


def downgrade() -> None:
    # Postgres cannot remove ENUM values — downgrade is intentionally a no-op.
    pass
