"""Rename customertype enum value FARMER -> FARMER_MEET.

WHAT CHANGES
- Postgres enum ``customertype`` label ``FARMER`` is renamed to
  ``FARMER_MEET`` via ``ALTER TYPE ... RENAME VALUE``. Existing rows already
  storing 'FARMER' are automatically repointed to the renamed label — no data
  migration needed. Unlike ``ADD VALUE`` (0016/0021), ``RENAME VALUE`` has no
  same-transaction restriction, so no ``autocommit_block`` is required here.
- The column default on ``customers.customer_type`` is a literal cast
  ('FARMER'::customertype) that would break once the label it points at is
  renamed, so it's dropped and re-added against the new label in the same
  migration.

Revision: 0023
Prev: 0022_visit_plan_item_target_order
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0023"
down_revision: Union[str, None] = "0022"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("ALTER TABLE customers ALTER COLUMN customer_type DROP DEFAULT")
    op.execute("ALTER TYPE customertype RENAME VALUE 'FARMER' TO 'FARMER_MEET'")
    op.execute(
        "ALTER TABLE customers ALTER COLUMN customer_type SET DEFAULT 'FARMER_MEET'"
    )


def downgrade() -> None:
    op.execute("ALTER TABLE customers ALTER COLUMN customer_type DROP DEFAULT")
    op.execute("ALTER TYPE customertype RENAME VALUE 'FARMER_MEET' TO 'FARMER'")
    op.execute(
        "ALTER TABLE customers ALTER COLUMN customer_type SET DEFAULT 'FARMER'"
    )
