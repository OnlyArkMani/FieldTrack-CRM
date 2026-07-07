"""Add location fields to users: village, district, state.

WHAT CHANGES
- ``users.village``  (VARCHAR 120, nullable) — the employee's base village/city/town.
- ``users.district`` (VARCHAR 120, nullable) — the employee's base district.
- ``users.state``    (VARCHAR 120, nullable) — the employee's base state.

Where the employee is based (captured once at team-member creation), not a
live GPS fix — that's already covered by attendance/visit check-in lat/lng.
All three optional; existing rows are unaffected.

Revision: 0015
Prev: 0014_visit_vet_request
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0015"
down_revision: Union[str, None] = "0014"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("village", sa.String(length=120), nullable=True))
    op.add_column("users", sa.Column("district", sa.String(length=120), nullable=True))
    op.add_column("users", sa.Column("state", sa.String(length=120), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "state")
    op.drop_column("users", "district")
    op.drop_column("users", "village")
