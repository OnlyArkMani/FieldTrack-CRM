"""Add per-entity-type visit form fields (checklist: Retailer/FPO/Farmer forms).

WHAT CHANGES
- ``visit_org_answers`` gains ``price_min``/``price_max`` (the price range at
  which a Retailer resells feed to farmers — a range, unlike the single
  ``current_price_per_bag`` FPOs/VLCCs report). ``current_brand`` (existing
  column) is reused as "Current feed brand" for the Retailer form too, so no
  new column is needed for that field. Nullable; existing rows unaffected.
- ``livestock_profiles`` gains ``uses_cattle_feed`` (does the farmer
  currently use a branded cattle feed at all — gates whether brand/price are
  meaningful) and ``interested_in_new_feed`` (gates whether
  willing_to_pay_min/max are meaningful). Both nullable booleans.

Revision: 0020
Prev: 0019_attendance_on_leave
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0020"
down_revision: Union[str, None] = "0019"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "visit_org_answers",
        sa.Column("price_min", sa.Numeric(10, 2), nullable=True),
    )
    op.add_column(
        "visit_org_answers",
        sa.Column("price_max", sa.Numeric(10, 2), nullable=True),
    )
    op.add_column(
        "livestock_profiles",
        sa.Column("uses_cattle_feed", sa.Boolean(), nullable=True),
    )
    op.add_column(
        "livestock_profiles",
        sa.Column("interested_in_new_feed", sa.Boolean(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("livestock_profiles", "interested_in_new_feed")
    op.drop_column("livestock_profiles", "uses_cattle_feed")
    op.drop_column("visit_org_answers", "price_max")
    op.drop_column("visit_org_answers", "price_min")
