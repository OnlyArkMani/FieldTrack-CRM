
"""Add client_id to customers and visits for idempotent offline sync.

WHAT CHANGES
- ``customers.client_id`` and ``visits.client_id`` (nullable String(36),
  a client-generated UUID) let the mobile offline queue retry a create
  request safely: if the server already has a row for that client_id, the
  create is a no-op that returns the existing row instead of inserting a
  duplicate. NULL for every row created through the normal (online) path,
  which never sends one.
- Unique partial index on each (`WHERE client_id IS NOT NULL`) so multiple
  NULLs don't collide (Postgres unique constraints already never dedupe
  NULLs, but the partial index also keeps the index itself small since the
  vast majority of rows won't carry a client_id).

Revision: 0025
Prev: 0024_rename_supervisor_to_manager
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0025"
down_revision: Union[str, None] = "0024"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "customers", sa.Column("client_id", sa.String(length=36), nullable=True)
    )
    op.create_index(
        "ux_customers_client_id",
        "customers",
        ["client_id"],
        unique=True,
        postgresql_where=sa.text("client_id IS NOT NULL"),
    )

    op.add_column(
        "visits", sa.Column("client_id", sa.String(length=36), nullable=True)
    )
    op.create_index(
        "ux_visits_client_id",
        "visits",
        ["client_id"],
        unique=True,
        postgresql_where=sa.text("client_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("ux_visits_client_id", table_name="visits")
    op.drop_column("visits", "client_id")

    op.drop_index("ux_customers_client_id", table_name="customers")
    op.drop_column("customers", "client_id")
