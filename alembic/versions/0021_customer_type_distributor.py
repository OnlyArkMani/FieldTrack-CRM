"""Add DISTRIBUTOR to the customertype enum.

WHAT CHANGES
- Postgres enum ``customertype`` gains a fifth value, ``DISTRIBUTOR``,
  alongside FARMER/FPO/VLCC/RETAILER. Distributor visits reuse the existing
  shared FPO/VLCC/Retailer "org answers" 5-question form — no new
  columns/tables. See 0016 for why ``autocommit_block`` is required here.

Revision: 0021
Prev: 0020_entity_form_fields
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0021"
down_revision: Union[str, None] = "0020"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE customertype ADD VALUE IF NOT EXISTS 'DISTRIBUTOR'")


def downgrade() -> None:
    # Postgres has no ALTER TYPE ... DROP VALUE — see 0016's downgrade.
    pass
