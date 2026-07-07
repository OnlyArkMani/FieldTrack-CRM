"""Add RETAILER to the customertype enum (checklist A12).

WHAT CHANGES
- Postgres enum ``customertype`` gains a fourth value, ``RETAILER``, alongside
  the existing FARMER / FPO / VLCC. Retailer visits reuse the existing shared
  FPO/VLCC "org answers" 5-question form — no new columns/tables.
- ``ALTER TYPE ... ADD VALUE`` cannot run in the same transaction as a
  statement that uses the new value. This repo's ``alembic/env.py`` runs a
  full ``upgrade head`` as ONE transaction (no ``transaction_per_migration``),
  so a later migration that reads/writes 'RETAILER' would otherwise share a
  transaction with this ADD VALUE on a from-scratch run. ``autocommit_block``
  forces this statement onto its own connection-level transaction regardless
  of how it's batched with other revisions.

Revision: 0016
Prev: 0015_user_location
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0016"
down_revision: Union[str, None] = "0015"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE customertype ADD VALUE IF NOT EXISTS 'RETAILER'")


def downgrade() -> None:
    # Postgres has no ALTER TYPE ... DROP VALUE. Downgrading would require
    # rebuilding the enum (rename old -> create new -> cast every column ->
    # drop old), which risks failing outright if any row is already RETAILER.
    # Left as a no-op, matching the project's convention of not supporting
    # enum-value removal (see 0012's downgrade, which only drops the type it
    # created, never a single value).
    pass
