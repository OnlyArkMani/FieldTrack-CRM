"""Add manager_comment column to daily_reports.

Also adds manager_comment to the DailyReport ORM model (see app/models/crm.py
for the corresponding Mapped column — added in the same commit).

Revision: 0006
Prev: 0005_fieldcrm_schema
"""
import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "daily_reports",
        sa.Column("manager_comment", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("daily_reports", "manager_comment")
