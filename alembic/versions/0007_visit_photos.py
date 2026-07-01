"""Add visit_photos table (checklist #24 — up to 5 photos per visit).

Metadata only; image bytes live on the VPS filesystem
(settings.visit_photo_storage_dir). See app/models/crm.py VisitPhoto for the
ORM counterpart added in the same commit.

Revision: 0007
Prev: 0006_dsr_manager_comment
"""
import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "visit_photos",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column(
            "visit_id",
            sa.BigInteger(),
            sa.ForeignKey("visits.id", ondelete="CASCADE"),
            nullable=True,
        ),
        sa.Column(
            "uploaded_by",
            sa.BigInteger(),
            sa.ForeignKey("users.id"),
            nullable=True,
        ),
        sa.Column("file_path", sa.String(length=500), nullable=False),
        sa.Column("content_type", sa.String(length=100), nullable=True),
        sa.Column("size_bytes", sa.Integer(), nullable=True),
        sa.Column("caption", sa.String(length=200), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
    )
    op.create_index("ix_visit_photos_visit_id", "visit_photos", ["visit_id"])


def downgrade() -> None:
    op.drop_index("ix_visit_photos_visit_id", table_name="visit_photos")
    op.drop_table("visit_photos")
