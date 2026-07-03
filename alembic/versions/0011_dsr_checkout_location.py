"""DSR check-out location (checklist #46).

check_in_lat/check_in_lng already exist (migration 0010) but check-out GPS was
being read off the AttendanceSession END row and thrown away in
_generate_in_session — this adds the columns to actually keep it.

Revision: 0011
Prev: 0010_dsr_summary_fields
"""
import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "daily_reports", sa.Column("check_out_lat", sa.Float(), nullable=True)
    )
    op.add_column(
        "daily_reports", sa.Column("check_out_lng", sa.Float(), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("daily_reports", "check_out_lng")
    op.drop_column("daily_reports", "check_out_lat")
