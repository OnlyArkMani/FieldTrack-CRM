"""Customer types: rename farmers -> customers, add customer_type, add the
shared FPO/VLCC organisation-answer table.

WHAT CHANGES
- New Postgres enum ``customertype`` (FARMER / FPO / VLCC).
- Table ``farmers`` is renamed to ``customers`` (all child FK columns keep the
  name ``farmer_id`` but now reference ``customers.id`` via the same, unchanged
  FK constraints — Postgres tracks them by identity across the rename).
- ``customers.customer_type`` added, NOT NULL DEFAULT 'FARMER' (so every
  pre-existing farmer row is classified FARMER automatically).
- The three farmer indexes are renamed to their ``ix_customers_*`` equivalents
  and a new ``ix_customers_customer_type`` index is added.
- New table ``visit_org_answers`` holds the 5-question form answered on FPO and
  VLCC visits.

Revision: 0012
Prev: 0011_dsr_checkout_location
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0012"
down_revision: Union[str, None] = "0011"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# create_type=False: we create/drop the type explicitly below so that
# add_column / drop_column don't try to manage the type a second time.
CUSTOMER_TYPE = postgresql.ENUM(
    "FARMER", "FPO", "VLCC", name="customertype", create_type=False
)


def upgrade() -> None:
    bind = op.get_bind()

    # 1) enum type
    CUSTOMER_TYPE.create(bind, checkfirst=True)

    # 2) rename the table (FKs + indexes follow automatically by identity)
    op.rename_table("farmers", "customers")

    # 3) rename the carried-over indexes to the new naming
    op.execute("ALTER INDEX ix_farmers_team_id RENAME TO ix_customers_team_id")
    op.execute("ALTER INDEX ix_farmers_created_by RENAME TO ix_customers_created_by")
    op.execute("ALTER INDEX ix_farmers_village RENAME TO ix_customers_village")

    # 4) discriminator column — existing rows become FARMER
    op.add_column(
        "customers",
        sa.Column(
            "customer_type",
            CUSTOMER_TYPE,
            server_default=sa.text("'FARMER'"),
            nullable=False,
        ),
    )
    op.create_index(
        "ix_customers_customer_type", "customers", ["customer_type"]
    )

    # 5) shared FPO/VLCC organisation answers
    op.create_table(
        "visit_org_answers",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("visit_id", sa.BigInteger(), nullable=True),
        sa.Column("farmer_id", sa.BigInteger(), nullable=True),
        sa.Column("member_count", sa.Integer(), nullable=True),
        sa.Column("total_cattle", sa.Integer(), nullable=True),
        sa.Column("current_brand", sa.String(length=200), nullable=True),
        sa.Column("monthly_bags", sa.Integer(), nullable=True),
        sa.Column(
            "interested_in_supply",
            sa.Boolean(),
            server_default=sa.text("false"),
            nullable=False,
        ),
        sa.Column("interested_bags", sa.Integer(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column(
            "recorded_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["visit_id"], ["visits.id"],
            name="fk_visit_org_answers_visit_id_visits", ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["farmer_id"], ["customers.id"],
            name="fk_visit_org_answers_farmer_id_customers",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_visit_org_answers"),
    )
    op.create_index(
        "ix_visit_org_answers_visit_id", "visit_org_answers", ["visit_id"]
    )
    op.create_index(
        "ix_visit_org_answers_farmer_id", "visit_org_answers", ["farmer_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_visit_org_answers_farmer_id", table_name="visit_org_answers")
    op.drop_index("ix_visit_org_answers_visit_id", table_name="visit_org_answers")
    op.drop_table("visit_org_answers")

    op.drop_index("ix_customers_customer_type", table_name="customers")
    op.drop_column("customers", "customer_type")

    op.execute("ALTER INDEX ix_customers_village RENAME TO ix_farmers_village")
    op.execute("ALTER INDEX ix_customers_created_by RENAME TO ix_farmers_created_by")
    op.execute("ALTER INDEX ix_customers_team_id RENAME TO ix_farmers_team_id")

    op.rename_table("customers", "farmers")

    CUSTOMER_TYPE.drop(op.get_bind(), checkfirst=True)
