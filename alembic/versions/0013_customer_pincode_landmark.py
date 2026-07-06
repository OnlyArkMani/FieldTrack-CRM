"""Add structured-address fields to customers: pincode + landmark.

WHAT CHANGES
- ``customers.pincode`` (VARCHAR 10, nullable) — postal PIN code.
- ``customers.landmark`` (VARCHAR 200, nullable) — nearby landmark / address line 2.

Both are optional; existing free-text ``address``, ``village`` and ``district``
columns are unchanged. Part of the July 2026 CRM flow revamp (Feature 1).

Revision: 0013
Prev: 0012_customers_types_org_answers
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0013"
down_revision: Union[str, None] = "0012"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("customers", sa.Column("pincode", sa.String(length=10), nullable=True))
    op.add_column("customers", sa.Column("landmark", sa.String(length=200), nullable=True))


def downgrade() -> None:
    op.drop_column("customers", "landmark")
    op.drop_column("customers", "pincode")
