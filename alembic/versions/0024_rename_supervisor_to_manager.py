"""Rename SUPERVISOR role to MANAGER.

WHAT CHANGES
- Postgres enum ``user_role`` label ``SUPERVISOR`` is renamed to ``MANAGER``.
- Column ``teams.supervisor_id`` is renamed to ``teams.manager_id``.
- Foreign key constraint ``fk_teams_supervisor_id_users`` is renamed to ``fk_teams_manager_id_users``.
- Index ``ix_teams_supervisor_id`` is renamed to ``ix_teams_manager_id``.

Revision: 0024
Prev: 0023
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0024"
down_revision: Union[str, None] = "0023"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Rename column
    op.alter_column("teams", "supervisor_id", new_column_name="manager_id")
    # Rename index
    op.execute("ALTER INDEX ix_teams_supervisor_id RENAME TO ix_teams_manager_id")
    # Rename foreign key
    op.execute(
        "ALTER TABLE teams RENAME CONSTRAINT fk_teams_supervisor_id_users TO fk_teams_manager_id_users"
    )
    # Rename enum value
    op.execute("ALTER TYPE user_role RENAME VALUE 'SUPERVISOR' TO 'MANAGER'")


def downgrade() -> None:
    # Rename enum value back
    op.execute("ALTER TYPE user_role RENAME VALUE 'MANAGER' TO 'SUPERVISOR'")
    # Rename foreign key back
    op.execute(
        "ALTER TABLE teams RENAME CONSTRAINT fk_teams_manager_id_users TO fk_teams_supervisor_id_users"
    )
    # Rename index back
    op.execute("ALTER INDEX ix_teams_manager_id RENAME TO ix_teams_supervisor_id")
    # Rename column back
    op.alter_column("teams", "manager_id", new_column_name="supervisor_id")
