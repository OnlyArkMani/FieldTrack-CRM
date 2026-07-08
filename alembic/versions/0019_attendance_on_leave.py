"""Add ON_LEAVE to the attendance_status enum (self-service leave marking).

WHAT CHANGES
- Postgres enum ``attendance_status`` gains a fourth value, ``ON_LEAVE``,
  alongside PRESENT / ABSENT / HALF_DAY. An employee who hasn't checked in yet
  can mark today as leave (POST /attendance/leave), creating a sessionless
  Attendance row with this status; current_state resolves to "ON_LEAVE" for
  it (see AttendanceService._state_of).
- ``ALTER TYPE ... ADD VALUE`` cannot run in the same transaction as a
  statement that uses the new value — see 0016's note. autocommit_block keeps
  this on its own connection-level transaction.

Revision: 0019
Prev: 0018_visit_plan_item_reminder_sent
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0019"
down_revision: Union[str, None] = "0018"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE attendance_status ADD VALUE IF NOT EXISTS 'ON_LEAVE'")


def downgrade() -> None:
    # Postgres has no ALTER TYPE ... DROP VALUE — see 0016's downgrade note.
    pass
