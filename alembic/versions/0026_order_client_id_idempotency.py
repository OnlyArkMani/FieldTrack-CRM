
"""Add client_id to visit_orders for idempotent offline sync.

WHAT CHANGES
- ``visit_orders.client_id`` (nullable String(36), a client-generated UUID)
  closes the one remaining duplicate-creation risk in the offline visit
  sub-actions: a lost response after a successful order creation would
  otherwise double-create it on the sync engine's retry. Same pattern as
  migration 0025 (customers/visits) — NULL for orders created through the
  normal (online) path.
- Unique partial index (`WHERE client_id IS NOT NULL`) so a retried create
  with the same client_id is a no-op.

Revision: 0026
Prev: 0025_client_id_idempotency
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0026"
down_revision: Union[str, None] = "0025"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "visit_orders", sa.Column("client_id", sa.String(length=36), nullable=True)
    )
    op.create_index(
        "ux_visit_orders_client_id",
        "visit_orders",
        ["client_id"],
        unique=True,
        postgresql_where=sa.text("client_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("ux_visit_orders_client_id", table_name="visit_orders")
    op.drop_column("visit_orders", "client_id")
