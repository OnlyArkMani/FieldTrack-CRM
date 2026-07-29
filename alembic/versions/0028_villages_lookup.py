"""Add villages reference table for LGD village lookup + pg_trgm search.

WHAT CHANGES
- Enables pg_trgm extension (safe no-op if already present).
- Creates ``villages`` table seeded from data.gov.in LGD dataset.
- GIN trigram index on ``village_name`` for fast ILIKE autocomplete.
- B-tree index on ``district_name`` for district-filter queries.
- UNIQUE on ``village_code`` (LGD code) so the seeder upserts safely.

Revision: 0028
Prev: 0027
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0028"
down_revision: Union[str, None] = "0027"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    op.create_table(
        "villages",
        sa.Column("id", sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column("village_code", sa.BigInteger(), nullable=False),
        sa.Column("village_name", sa.String(200), nullable=False),
        sa.Column("village_name_local", sa.String(200), nullable=True),
        sa.Column("subdistrict_code", sa.BigInteger(), nullable=True),
        sa.Column("subdistrict_name", sa.String(200), nullable=True),
        sa.Column("district_code", sa.BigInteger(), nullable=True),
        sa.Column("district_name", sa.String(200), nullable=False),
        sa.Column("state_code", sa.Integer(), nullable=False),
        sa.Column("state_name", sa.String(100), nullable=False),
    )

    op.create_index(
        "uq_villages_village_code", "villages", ["village_code"], unique=True
    )
    op.execute(
        "CREATE INDEX ix_villages_name_trgm ON villages "
        "USING GIN (village_name gin_trgm_ops)"
    )
    op.create_index("ix_villages_district_name", "villages", ["district_name"])
    op.create_index("ix_villages_state_code", "villages", ["state_code"])


def downgrade() -> None:
    op.drop_table("villages")
