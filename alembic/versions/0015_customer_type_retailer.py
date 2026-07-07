"""Add RETAILER to the customertype enum (checklist A12).

WHAT CHANGES
- Postgres enum ``customertype`` gains a fourth value, ``RETAILER``, alongside
  the existing FARMER / FPO / VLCC. Retailer visits reuse the existing shared
  FPO/VLCC "org answers" 5-question form — no new columns/tables.
- ``ALTER TYPE ... ADD VALUE`` cannot run inside the same transaction as a
  statement that uses the new value, but it's fine as the sole statement in
  its own migration transaction (Postgres 12+, this project runs PG15).

Revision: 0015
Prev: 0014_visit_vet_request
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0015"
down_revision: Union[str, None] = "0014"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("ALTER TYPE customertype ADD VALUE IF NOT EXISTS 'RETAILER'")


def downgrade() -> None:
    # Postgres has no ALTER TYPE ... DROP VALUE. Downgrading would require
    # rebuilding the enum (rename old -> create new -> cast every column ->
    # drop old), which risks failing outright if any row is already RETAILER.
    # Left as a no-op, matching the project's convention of not supporting
    # enum-value removal (see 0012's downgrade, which only drops the type it
    # created, never a single value).
    pass
