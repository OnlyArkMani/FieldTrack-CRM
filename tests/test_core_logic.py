"""Core business-logic unit tests.

These are intentionally DB-free so they run fast and deterministically in CI
(the postgres/redis service containers are still used by the migration step).
They cover the pure logic most likely to silently break a release:
  - attendance worked-minutes math (must EXCLUDE break gaps)
  - the attendance state-machine transition table
  - password hashing round-trip
  - FCM being a true no-op when unconfigured
  - report date-range validation ceiling
"""
from datetime import datetime, timedelta, timezone

import pytest

from app.models.enums import SessionType
from app.models.attendance import AttendanceSession
from app.services.attendance_service import (
    _ALLOWED_FROM,
    calculate_duration,
)


def _sess(t: SessionType, dt: datetime) -> AttendanceSession:
    return AttendanceSession(type=t, timestamp=dt, lat=0.0, lng=0.0)


def test_duration_excludes_break_time():
    base = datetime(2026, 6, 18, 9, 0, tzinfo=timezone.utc)
    sessions = [
        _sess(SessionType.START, base),                       # 09:00
        _sess(SessionType.BREAK, base + timedelta(hours=3)),  # 12:00  -> 3h worked
        _sess(SessionType.RESUME, base + timedelta(hours=4)), # 13:00  (1h break, excluded)
        _sess(SessionType.END, base + timedelta(hours=8)),    # 17:00  -> 4h worked
    ]
    # 3h + 4h = 7h = 420 minutes; the 1h break is NOT counted.
    assert calculate_duration(sessions) == 420


def test_duration_empty_is_zero():
    assert calculate_duration([]) == 0


def test_duration_is_order_independent():
    base = datetime(2026, 6, 18, 9, 0, tzinfo=timezone.utc)
    ordered = [
        _sess(SessionType.START, base),
        _sess(SessionType.END, base + timedelta(hours=2)),
    ]
    shuffled = list(reversed(ordered))
    assert calculate_duration(shuffled) == calculate_duration(ordered) == 120


def test_state_machine_transitions():
    # START only from NULL; you cannot START again once STARTED.
    assert "NULL" in _ALLOWED_FROM[SessionType.START]
    assert "STARTED" not in _ALLOWED_FROM[SessionType.START]
    # BREAK only while working; RESUME only from a break; END only while working.
    assert _ALLOWED_FROM[SessionType.BREAK] == {"STARTED", "RESUMED"}
    assert _ALLOWED_FROM[SessionType.RESUME] == {"ON_BREAK"}
    assert _ALLOWED_FROM[SessionType.END] == {"STARTED", "RESUMED"}


def test_password_hash_roundtrip():
    from app.core.security import hash_password, verify_password

    h = hash_password("S3cret-Passw0rd!")
    assert h != "S3cret-Passw0rd!"          # never stored in plaintext
    assert verify_password("S3cret-Passw0rd!", h) is True
    assert verify_password("wrong-password", h) is False


async def test_fcm_is_noop_when_unconfigured():
    """With no service-account file configured, FCM must silently skip — no
    exception — so create/update requests never 500 because push isn't set up."""
    from app.services.fcm_service import FCMService

    svc = FCMService()
    svc.settings.fcm_service_account_file = ""
    svc.settings.fcm_service_account_b64 = ""
    assert svc._configured is False  # CI sets FCM_PROJECT_ID but file is ""
    delivered = await svc.send_to_tokens(["fake-token"], title="t", body="b")
    assert delivered == []

    result = await svc.send_and_classify(["fake-token"], title="t", body="b")
    assert result.delivered_count == 0
    assert result.stale_tokens == []


def test_report_range_validator_ceiling():
    """Schema allows up to a 1-year sanity ceiling; the 31-day business rule is
    enforced at the endpoint (so a 35-day range returns 400, not 422)."""
    from app.schemas.report import ReportFilters
    from datetime import date

    # 35 days must PASS schema validation (endpoint enforces the 31-day 400).
    ReportFilters(start_date=date(2026, 1, 1), end_date=date(2026, 2, 5))
    # start after end is always rejected.
    with pytest.raises(ValueError):
        ReportFilters(start_date=date(2026, 2, 5), end_date=date(2026, 1, 1))
    # Beyond the 1-year sanity ceiling is rejected.
    with pytest.raises(ValueError):
        ReportFilters(start_date=date(2025, 1, 1), end_date=date(2026, 6, 1))


@pytest.mark.asyncio
async def test_team_service_list_filtering_by_role():
    from unittest.mock import AsyncMock
    from app.services.team_service import TeamService
    from app.models.user import User, Team
    from app.models.enums import UserRole
    from app.repositories.team_repository import TeamRow

    admin_user = User(id=1, name="Admin", role=UserRole.ADMIN)
    manager_user = User(id=2, name="Manager", role=UserRole.MANAGER)
    employee_user = User(id=3, name="Employee", role=UserRole.EMPLOYEE, team_id=10)

    t1 = Team(id=10, name="Team A", manager_id=2, is_active=True)
    t2 = Team(id=11, name="Team B", manager_id=4, is_active=True)
    row1 = TeamRow(t1, manager_name="Manager", member_count=5, present_today=2)
    row2 = TeamRow(t2, manager_name="Other", member_count=3, present_today=1)

    mock_db = AsyncMock()
    service = TeamService(mock_db)

    async def mock_list_with_stats(*args, **kwargs):
        manager_id = kwargs.get("manager_id")
        if manager_id == 2:
            return [row1]
        elif manager_id is None:
            return [row1, row2]
        return []

    service.repo.list_with_stats = mock_list_with_stats

    # Test Admin: should list all teams
    admin_teams = await service.list_teams(admin_user)
    assert len(admin_teams) == 2
    assert admin_teams[0].id == 10
    assert admin_teams[1].id == 11

    # Test Manager: should only list teams they manage (ID 2)
    mgr_teams = await service.list_teams(manager_user)
    assert len(mgr_teams) == 1
    assert mgr_teams[0].id == 10

    # Test Employee: should only list the team they belong to (ID 10)
    emp_teams = await service.list_teams(employee_user)
    assert len(emp_teams) == 1
    assert emp_teams[0].id == 10


@pytest.mark.asyncio
async def test_team_service_get_detail_permissions():
    from unittest.mock import AsyncMock
    from app.services.team_service import TeamService
    from app.models.user import User, Team
    from app.models.enums import UserRole
    from app.repositories.team_repository import TeamRow
    from app.core.exceptions import ApiError

    manager_user = User(id=2, name="Manager", role=UserRole.MANAGER)
    other_manager = User(id=4, name="Other Manager", role=UserRole.MANAGER)
    employee_user = User(id=3, name="Employee", role=UserRole.EMPLOYEE, team_id=10)
    other_employee = User(id=5, name="Other Employee", role=UserRole.EMPLOYEE, team_id=11)

    t1 = Team(id=10, name="Team A", manager_id=2, is_active=True)
    row = TeamRow(t1, manager_name="Manager", member_count=5, present_today=2)

    mock_db = AsyncMock()
    service = TeamService(mock_db)

    async def mock_get_stats_for(team_id, today):
        if team_id == 10:
            return row
        return None

    async def mock_get_members(team_id):
        return []

    service.repo.get_stats_for = mock_get_stats_for
    service.repo.get_members = mock_get_members
    service._live_status_for = AsyncMock(return_value={})

    # Manager owns it -> Success
    detail = await service.get_detail(10, manager_user)
    assert detail.id == 10

    # Manager does not own it -> 403 Forbidden
    with pytest.raises(ApiError) as exc_info:
        await service.get_detail(10, other_manager)
    assert exc_info.value.status_code == 403

    # Employee belongs to the team -> Success
    detail = await service.get_detail(10, employee_user)
    assert detail.id == 10

    # Employee does not belong to the team -> 403 Forbidden
    with pytest.raises(ApiError) as exc_info:
        await service.get_detail(10, other_employee)
    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_farmer_service_manager_scoping():
    from unittest.mock import AsyncMock
    from app.services.farmer_service import FarmerService
    from app.models.user import User
    from app.models.crm import Farmer
    from app.models.enums import UserRole
    from app.core.exceptions import ApiError

    manager = User(id=2, name="Manager", role=UserRole.MANAGER)
    mock_db = AsyncMock()
    service = FarmerService(mock_db)

    class MockResult:
        def __init__(self, data):
            self.data = data
        def scalars(self):
            class MockScalars:
                def __init__(self, data):
                    self.data = data
                def all(self):
                    return self.data
            return MockScalars(self.data)

    mock_db.execute = AsyncMock(return_value=MockResult([10, 11]))

    scope = await service._scope_for(manager)
    assert scope == {"team_ids": [10, 11], "created_by": 2}

    farmer_in_team = Farmer(id=1, team_id=10, created_by=99)
    farmer_out_team = Farmer(id=2, team_id=12, created_by=99)

    mock_db.execute = AsyncMock(return_value=MockResult([10, 11]))
    await service._assert_can_view(farmer_in_team, manager)

    mock_db.execute = AsyncMock(return_value=MockResult([10, 11]))
    with pytest.raises(ApiError) as exc_info:
        await service._assert_can_view(farmer_out_team, manager)
    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_lead_service_manager_scoping():
    from unittest.mock import AsyncMock
    from app.services.lead_service import LeadService
    from app.models.user import User
    from app.models.enums import UserRole

    manager = User(id=2, name="Manager", role=UserRole.MANAGER)
    mock_db = AsyncMock()
    service = LeadService(mock_db)

    service.repo.managed_team_ids = AsyncMock(return_value=[10, 11])
    service.repo.latest_lead_rows = AsyncMock(return_value=[])

    leads = await service.get_my_leads(manager, status=None)
    service.repo.managed_team_ids.assert_awaited_once_with(2)
    service.repo.latest_lead_rows.assert_awaited_once_with(status=None, team_ids=[10, 11])
    assert leads == []

