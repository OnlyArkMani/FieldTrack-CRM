"""Seed an admin, a manager, and an employee for local testing.

Run from the project root with the venv activated:
    python scripts/seed_users.py

Safe to re-run — skips any user whose email already exists.
"""
import asyncio

from sqlalchemy import select

from app.core.database import async_session_factory
from app.core.security import hash_password
from app.models.enums import UserRole
from app.models.user import Team, User

USERS = [
    dict(name="Admin User", email="admin@fieldtrack.com", phone="9000000001",
         password="Admin@123", role=UserRole.ADMIN),
    dict(name="Manager One", email="manager@fieldtrack.com", phone="9000000002",
         password="Manager@123", role=UserRole.MANAGER),
    dict(name="Employee One", email="employee@fieldtrack.com", phone="9000000003",
         password="Employee@123", role=UserRole.EMPLOYEE),
]


async def main() -> None:
    async with async_session_factory() as session:
        # Ensure a team exists so the employee/manager can be linked.
        team = (await session.execute(select(Team).where(Team.name == "Field Team A"))).scalar_one_or_none()
        if team is None:
            team = Team(name="Field Team A", description="Default seed team")
            session.add(team)
            await session.flush()

        created = {}
        for u in USERS:
            existing = (await session.execute(select(User).where(User.email == u["email"]))).scalar_one_or_none()
            if existing:
                print(f"skip (exists): {u['email']}")
                created[u["role"]] = existing
                continue
            user = User(
                name=u["name"],
                email=u["email"],
                phone=u["phone"],
                password_hash=hash_password(u["password"]),
                role=u["role"],
                team_id=team.id if u["role"] != UserRole.ADMIN else None,
                is_active=True,
            )
            session.add(user)
            await session.flush()
            created[u["role"]] = user
            print(f"created: {u['email']} / {u['password']} ({u['role'].value})")

        # Assign manager to the team.
        mgr = created.get(UserRole.MANAGER)
        if mgr and team.manager_id != mgr.id:
            team.manager_id = mgr.id

        await session.commit()

    print("\nDone. Test credentials:")
    for u in USERS:
        print(f"  {u['role'].value:<10} {u['email']:<28} {u['password']}")


if __name__ == "__main__":
    asyncio.run(main())
