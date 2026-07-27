"""Add RE_CHECKIN to the session_type enum.

Revision: 0027
Prev: 0026_order_client_id_idempotency
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0027"
down_revision: Union[str, None] = "0026"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE session_type ADD VALUE IF NOT EXISTS 'RE_CHECKIN'")


def downgrade() -> None:
    pass
