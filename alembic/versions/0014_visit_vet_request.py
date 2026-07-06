"""Add veterinary-requirement fields to visits (July 2026 CRM revamp, Feature 3).

WHAT CHANGES
- ``visits.vet_required``     BOOLEAN NOT NULL DEFAULT false — farmer/customer
  asked for a vet during the meeting.
- ``visits.vet_cattle_count`` INTEGER  NULL — how many cattle need the vet.
- ``visits.vet_notes``        TEXT     NULL — free-text detail.
- ``visits.vet_status``       VARCHAR(20) NULL — REQUESTED / SCHEDULED / DONE.
  Null when no vet is required; set to 'REQUESTED' when vet_required flips true.

Powers the new Vet dashboard (Feature 4), which lists visits where
vet_required is true with the customer, date and cattle count.

Revision: 0014
Prev: 0013_customer_pincode_landmark
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0014"
down_revision: Union[str, None] = "0013"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "visits",
        sa.Column(
            "vet_required",
            sa.Boolean(),
            server_default=sa.text("false"),
            nullable=False,
        ),
    )
    op.add_column("visits", sa.Column("vet_cattle_count", sa.Integer(), nullable=True))
    op.add_column("visits", sa.Column("vet_notes", sa.Text(), nullable=True))
    op.add_column("visits", sa.Column("vet_status", sa.String(length=20), nullable=True))
    op.create_index(
        "ix_visits_vet_required", "visits", ["vet_required"]
    )


def downgrade() -> None:
    op.drop_index("ix_visits_vet_required", table_name="visits")
    op.drop_column("visits", "vet_status")
    op.drop_column("visits", "vet_notes")
    op.drop_column("visits", "vet_cattle_count")
    op.drop_column("visits", "vet_required")
